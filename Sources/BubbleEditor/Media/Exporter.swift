// Owner: E2 (media). docs/editor-architecture.md §4: render the edited video (cuts + speed ranges) to a
// new .mp4. Source never written. Sound first (AudioJoiner: pitch kept, joins crossfaded), then the video:
// plain AVAssetReaders on the source track (VideoRun), frames placed on the output timeline and resampled
// to 30 fps CFR (FrameSlots) → AVAssetWriter
// H.264 High + AAC 128 kb/s, moov first. AVAssetExportSession is not used: it fails (-16364) with
// H.264 as soon as a range is sped up (architect's spike, spikes/export).
import AVFoundation
import BubbleCore
import CoreMedia
import CoreVideo
import Foundation

/// A kept stretch of the source, in source seconds, played at `rate` (> 0). What EditPlan's pieces map to.
public struct MediaPiece: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    public var rate: Double
    public init(start: Double, end: Double, rate: Double) {
        self.start = start; self.end = end; self.rate = rate
    }
}

public struct ExportResult: Sendable, Equatable {
    /// Container duration of the file written (seconds).
    public var duration: Double
    public var bytes: Int64
    /// Video frames written (CFR: duration × 30, ± 1).
    public var frames: Int
}

public enum Exporter {
    public static let fps: Int32 = 30
    /// Sound crossfade at every join, seconds (AudioJoiner). 40 ms: hides the splice, doesn't smear a word.
    public static let crossfade = 0.040
    static let timescale: CMTimeScale = 600_000

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case sourceMissing
        case noVideo
        case nothingKept
        case readFailed(String)
        case writeFailed(String)
        case notEnoughSpace(needed: Int64)
        case stalled

        public var description: String {
            switch self {
            case .sourceMissing: "The recording is missing: it was moved or deleted."
            case .noVideo: "The recording has no video track."
            case .nothingKept: "Everything is cut: there is nothing to export."
            case .readFailed(let m): "Could not read the recording: \(m)"
            case .writeFailed(let m): "Could not write the video: \(m)"
            case .stalled: "The export stopped making progress. Try again."
            case .notEnoughSpace(let n): "Not enough space to export (needs ~\(formatGB(n)))."
            }
        }
    }

    /// Σ (end − start) / rate over pieces with rate > 0: the edited duration (docs/editor-api.md §3).
    public static func outputDuration(_ pieces: [MediaPiece]) -> Double {
        pieces.filter { $0.rate > 0 && $0.end > $0.start }.reduce(0) { $0 + ($1.end - $1.start) / $1.rate }
    }

    /// Frames of the 30 fps output for that duration (at least 1).
    public static func frameCount(duration: Double) -> Int {
        max(1, Int((duration * Double(fps)).rounded()))
    }

    /// Renders `pieces` of `source` into `destination` (replaced if it exists). The file appears only when
    /// complete (written in `partialFolder(for:)`, then moved). `progress` gets 0...1 from any thread.
    /// Cancel the Task to stop: the partial file is deleted and `CancellationError` is thrown.
    @discardableResult
    public static func render(source: URL, pieces: [MediaPiece], to destination: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in },
                              bytesFree: (URL) -> Int64? = DiskPolicy.bytesFree(at:),
                              stallTimeout: Duration = .seconds(60),
                              crossfade: Double = Exporter.crossfade) async throws -> ExportResult {
        guard FileManager.default.fileExists(atPath: source.path) else { throw Failure.sourceMissing }
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        // The sound comes from its own AVURLAsset: AudioJoiner opens and cancels a reader per piece, and
        // doing that on the asset the video reader uses stalled the video read under load (stall report:
        // video stuck in copyNextSampleBuffer, video input ready, audio input waiting on it).
        let audioAsset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let srcAudio = try await audioAsset.loadTracks(withMediaType: .audio).first
        let sourceDuration = try await asset.load(.duration)
        let audioRange = try await srcAudio?.load(.timeRange)
        let transform = try await srcVideo.load(.preferredTransform)
        let size = try await srcVideo.load(.naturalSize)
        try Task.checkCancellation()

        // 1. The output timeline: kept pieces back to back, each lasting (end − start) / rate.
        // No AVMutableComposition: reading one crashed (SIGSEGV in FigVisualContext when cancelled from
        // another thread) and, after a failed render, hung the next render's reads in the same process
        // (copyNextSampleBuffer never returned; a plain reader on the source read fine at the same time).
        // The video is read from the source track with plain readers (VideoRun) and placed on the
        // output timeline here; the sound by AudioJoiner.
        let kept = clamp(pieces, to: sourceDuration.seconds)
        var outputStarts: [Double] = []
        var cursor = CMTime.zero
        for p in kept {
            outputStarts.append(cursor.seconds)
            cursor = cursor + CMTime(seconds: (p.end - p.start) / p.rate, preferredTimescale: timescale)
        }
        guard cursor > .zero else { throw Failure.nothingKept }
        let runs = VideoRun.make(pieces: kept, outputStarts: outputStarts)
        let total = frameCount(duration: cursor.seconds)
        let end = CMTime(value: CMTimeValue(total), timescale: fps)
        let width = evenPixels(size.width), height = evenPixels(size.height)

        // Fail early rather than mid-render when the disk can't take the file.
        let needed = estimatedBytes(width: width, height: height, duration: cursor.seconds, sound: srcAudio != nil)
        if let free = bytesFree(destination.deletingLastPathComponent()), free < needed {
            throw Failure.notEnoughSpace(needed: needed)
        }

        // Everything is written in a hidden work folder (the writer puts its own temp files next to its
        // output), moved into place when complete; the folder goes away whatever happens.
        let fm = FileManager.default
        let work = partialFolder(for: destination)
        let partial = work.appendingPathComponent(destination.lastPathComponent)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // 2. The sound first, alone: AudioJoiner (one reader per piece, pitch kept, joins crossfaded) renders
        // it to a 16-bit file in the work folder. Then the video pass reads that file with plain reads.
        // No two AVAssetReaders ever run at once: with the joiner's reader open next to the video's, the
        // video read stalled under load (1 run in 4 with 4 exports at once; every MediaToolbox thread
        // waiting, video input ready, audio input waiting for video).
        var sound: PCMFileSource?
        let soundShare = srcAudio == nil ? 0.0 : 0.1
        if let srcAudio, let audioRange {
            let plan = AudioJoinPlan.make(pieces: kept, outputStarts: outputStarts, end: cursor.seconds,
                                          sourceDuration: sourceDuration.seconds, crossfade: crossfade,
                                          sampleRate: AudioJoiner.sampleRate)
            let joiner: AudioJoiner
            do { joiner = try AudioJoiner(track: srcAudio, available: audioRange, plan: plan) } catch {
                throw Failure.readFailed("\(error)")
            }
            let file = work.appendingPathComponent("sound.pcm")
            do {
                _ = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Int, Error>) in
                        DispatchQueue(label: "bubble.export.sound").async {
                            do { done.resume(returning: try joiner.render(to: file) { progress($0 * soundShare) }) }
                            catch { done.resume(throwing: error) }
                        }
                    }
                } onCancel: { joiner.cancel() }
            } catch { throw Failure.readFailed("\(error)") }
            try Task.checkCancellation()
            do { sound = try PCMFileSource(url: file) } catch { throw Failure.readFailed("\(error)") }
        }

        // 3. The video source: decoded frames (420v), one plain reader per run of pieces, one at a time.
        let videoSource = VideoSource(asset: asset, track: srcVideo, runs: runs)

        // 4. Writer: H.264 High at the source's size, AAC 128 kb/s, moov first.
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: partial, fileType: .mp4) } catch { throw Failure.writeFailed(error.localizedDescription) }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoSettings.bitRate(width: width, height: height, fps: Int(fps)),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            ] as [String: Any],
        ])
        // The source track's rotation, set on the output (frames are read unrotated from the source track;
        // without this an imported phone video would come out sideways).
        vIn.transform = transform
        // Frames are copied into the adaptor's own pool (VideoPump.own): the reader's buffers go back to the
        // decoder at once, so frames held by the encoder or repeated for slow-downs never starve it.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(abs(size.width)), kCVPixelBufferHeightKey as String: Int(abs(size.height)),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if sound != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
            writer.add(i); aIn = i
        }
        writer.shouldOptimizeForNetworkUse = true

        do { try videoSource.open() } catch { throw Failure.readFailed("\(error)") }   // the first run's reader
        guard writer.startWriting() else {
            videoSource.close()
            throw Failure.writeFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        // 4. Pump both inputs on their own queues (offline interleaving); cancel stops both.
        let job = RenderJob(writer: writer)
        let videoPump = VideoPump(input: vIn, adaptor: adaptor, source: videoSource, total: total, job: job,
                                  progress: { progress(soundShare + (1 - soundShare) * $0) })
        let audioPump = aIn.flatMap { i in sound.map { AudioPump(input: i, source: $0, end: end, job: job) } }
        let inputs = WriterState(writer: writer, video: vIn, audio: aIn)
        // Watchdog: no sample written for `stallTimeout` = a stuck reader or writer; fail instead of hanging.
        // A pump stuck inside a read never sees the flag: 5 s later the render stops waiting for it.
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if job.idle > stallTimeout {
                    if ProcessInfo.processInfo.environment["BUBBLE_EXPORT_DEBUG"] != nil {
                        FileHandle.standardError.write(Data("export stalled: \(job.report); \(inputs.description)\n".utf8))
                    }
                    job.fail(.stalled)
                    try? await Task.sleep(for: .seconds(5))
                    videoPump.abandon(); audioPump?.abandon()
                    return
                }
            }
        }
        await withTaskCancellationHandler {
            async let v: Void = videoPump.run()
            async let a: Void = audioPump?.run() ?? ()
            _ = await (v, a)
        } onCancel: {
            job.cancel()
        }
        watchdog.cancel()
        videoPump.release()

        if job.isCanceled || Task.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if let failure = job.failure {
            writer.cancelWriting()
            throw failure
        }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writeFailed(writer.error?.localizedDescription ?? "finishWriting (\(writer.status.rawValue))")
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
        progress(1)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        let bytes = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ExportResult(duration: duration, bytes: bytes, frames: videoPump.written)
    }

    /// Size of the export: (video bitrate + 128 kb/s audio) × duration, + 10 % (container, bitrate overshoot).
    /// With `sound`, plus the sound rendered first to a 16-bit file (96 kB/s, deleted at the end).
    public static func estimatedBytes(width: Int, height: Int, duration: Double, sound: Bool = true) -> Int64 {
        let bitsPerSecond = Double(VideoSettings.bitRate(width: width, height: height, fps: Int(fps)) + 128_000)
        let pcm = sound ? Double(AudioJoiner.sampleRate * 2) * max(0, duration) : 0
        return Int64((bitsPerSecond / 8 * max(0, duration) * 1.1 + pcm).rounded(.up))
    }

    /// "1.2 GB", "0.3 GB" (decimal, like Finder).
    static func formatGB(_ bytes: Int64) -> String {
        String(format: "%.1f GB", max(0.1, Double(bytes) / 1e9))
    }

    /// `<folder>/.<name>.partial/`: where a render in progress lives.
    public static func partialFolder(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).partial", isDirectory: true)
    }

    /// Pieces inside [0, duration], rate > 0, non-empty, in order.
    static func clamp(_ pieces: [MediaPiece], to duration: Double) -> [MediaPiece] {
        pieces.compactMap { p in
            let s = max(0, p.start), e = min(duration, p.end)
            guard p.rate > 0, p.rate.isFinite, e - s > 1e-6 else { return nil }
            return MediaPiece(start: s, end: e, rate: p.rate)
        }
    }

    private static func evenPixels(_ v: CGFloat) -> Int { max(2, Int(abs(v).rounded()) / 2 * 2) }
}

/// Pure: places decoded frames on the 30 fps grid. A frame at output time t goes to slot round(t × 30);
/// a frame whose slot is taken is dropped (speed-ups), empty slots repeat the previous frame
/// (slow-downs, static stretches of a variable-frame-rate recording).
struct FrameSlots: Sendable, Equatable {
    let total: Int
    let fps: Double
    private(set) var next = 0

    init(total: Int, fps: Double = Double(Exporter.fps)) {
        self.total = total; self.fps = fps
    }

    struct Placement: Equatable {
        /// Slots that get the previous frame again (or this one when there is none yet).
        var repeats: Range<Int>
        /// The slot of this frame, or nil when dropped.
        var slot: Int?
    }

    mutating func place(time: Double) -> Placement {
        let s = min(Int((time * fps).rounded()), total)
        guard s >= next else { return Placement(repeats: next..<next, slot: nil) }
        let repeats = next..<s
        next = s
        guard s < total else { return Placement(repeats: repeats, slot: nil) }
        next = s + 1
        return Placement(repeats: repeats, slot: s)
    }

    /// Slots left to fill with the last frame at the end.
    mutating func finish() -> Range<Int> {
        defer { next = total }
        return next..<max(next, total)
    }
}

/// Pure: kept pieces read by one plain reader, in source order and less than `maxGap` apart (a gap that
/// short is decoded and skipped; a longer one, or a piece out of order, starts a new run and a new reader).
struct VideoRun: Sendable, Equatable {
    struct Part: Sendable, Equatable {
        var start: Double, end: Double, rate: Double
        /// Where the part starts on the output timeline.
        var outputStart: Double
    }
    var parts: [Part]
    var start: Double { parts.first?.start ?? 0 }
    var end: Double { parts.last?.end ?? 0 }

    static let maxGap = 1.0

    static func make(pieces: [MediaPiece], outputStarts: [Double], maxGap: Double = maxGap) -> [VideoRun] {
        var runs: [VideoRun] = []
        for (p, out) in zip(pieces, outputStarts) {
            let part = Part(start: p.start, end: p.end, rate: p.rate, outputStart: out)
            if let last = runs.last, p.start >= last.end - 1e-6, p.start - last.end <= maxGap {
                runs[runs.count - 1].parts.append(part)
            } else {
                runs.append(VideoRun(parts: [part]))
            }
        }
        return runs
    }

    /// Output times where a frame shown on [from, to) in the source appears: one per part it overlaps,
    /// at the part's start when it began showing before it.
    func outputTimes(shownFrom from: Double, to: Double) -> [Double] {
        parts.compactMap { p in
            guard from < p.end, to > p.start else { return nil }
            return p.outputStart + (max(from, p.start) - p.start) / p.rate
        }
    }
}

/// The source's video track decoded (420v), run after run: one plain AVAssetReader at a time, limited to
/// its run's source range. `open()` once before the pumps start; then only the video pump's queue uses it.
final class VideoSource: @unchecked Sendable {
    enum Read {
        case frame(CVPixelBuffer, time: Double)
        /// The run's reader is drained (the next run's reader is open, if any).
        case runEnded(VideoRun)
        case done
    }
    struct ReadError: Error, CustomStringConvertible { var description: String }

    let asset: AVAsset
    let track: AVAssetTrack
    let runs: [VideoRun]
    private var index = 0
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var closed = false

    init(asset: AVAsset, track: AVAssetTrack, runs: [VideoRun]) {
        self.asset = asset; self.track = track; self.runs = runs
    }

    /// The run being read.
    var run: VideoRun { runs[min(index, max(0, runs.count - 1))] }

    /// Opens the reader of the current run.
    func open() throws {
        guard !closed, index < runs.count else { return }
        let r: AVAssetReader
        do { r = try AVAssetReader(asset: asset) } catch { throw ReadError(description: error.localizedDescription) }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        o.alwaysCopiesSampleData = false   // frames that are kept get copied into the writer's pool
        r.add(o)
        let run = runs[index]
        r.timeRange = CMTimeRange(start: CMTime(seconds: run.start, preferredTimescale: Exporter.timescale),
                                  end: CMTime(seconds: run.end, preferredTimescale: Exporter.timescale))
        guard r.startReading() else { throw ReadError(description: r.error?.localizedDescription ?? "startReading") }
        reader = r; output = o
    }

    func next() throws -> Read {
        guard !closed, let reader, let output else { return .done }
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }   // e.g. a marker buffer
            return .frame(image, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        if reader.status == .failed { throw ReadError(description: reader.error?.localizedDescription ?? "video read") }
        let ended = runs[index]
        reader.cancelReading()
        self.reader = nil; self.output = nil
        index += 1
        try open()
        return .runEnded(ended)
    }

    /// Stops reading (idempotent). On the pump's queue, or before the pumps start.
    func close() {
        closed = true
        reader?.cancelReading()
        reader = nil; output = nil
    }
}

/// Shared by the pumps: cancel flag and first failure.
final class RenderJob: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private var firstFailure: Exporter.Failure?
    let writer: AVAssetWriter

    init(writer: AVAssetWriter) {
        self.writer = writer
    }

    private var lastActivity = ContinuousClock.now

    /// A pump wrote something.
    func touch() { lock.withLock { lastActivity = .now } }
    var idle: Duration { lock.withLock { ContinuousClock.now - lastActivity } }

    var isCanceled: Bool { lock.withLock { canceled } }
    var failure: Exporter.Failure? { lock.withLock { firstFailure } }

    /// Flags only. A reader is cancelled by its own pump, on its own queue: `cancelReading()` from another
    /// thread while that pump is inside `copyNextSampleBuffer()` crashes in MediaToolbox (seen in the
    /// gate: SIGSEGV in FigVisualContextGetEarliestSequentialImageTime).
    func cancel() { lock.withLock { canceled = true } }

    func fail(_ f: Exporter.Failure) { lock.withLock { if firstFailure == nil { firstFailure = f } } }

    var shouldStop: Bool { lock.withLock { canceled || firstFailure != nil } }

    // Where each pump is (for a stall report; BUBBLE_EXPORT_DEBUG=1 prints it).
    private var phases: [String: String] = [:]
    func note(_ pump: String, _ phase: String) { lock.withLock { phases[pump] = phase } }
    var report: String { lock.withLock { phases.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ") } }
}

/// Video: frames re-stamped on the 30 fps grid. Runs on its own serial queue.
final class VideoPump: @unchecked Sendable {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let source: VideoSource
    let job: RenderJob
    let progress: @Sendable (Double) -> Void
    private var slots: FrameSlots
    private var pending: [(CVPixelBuffer, Int)] = []
    private var pendingIndex = 0
    private var last: CVPixelBuffer?
    /// The frame read last, not placed yet: where it stops showing is the next frame's time.
    private var held: (frame: CVPixelBuffer, time: Double)?
    private var drained = false
    private var lastReported = -1.0
    private let queue = DispatchQueue(label: "bubble.export.video")
    private(set) var written = 0

    init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, source: VideoSource,
         total: Int, job: RenderJob, progress: @escaping @Sendable (Double) -> Void) {
        self.input = input; self.adaptor = adaptor; self.source = source; self.job = job; self.progress = progress
        self.slots = FrameSlots(total: total)
    }

    private let end = PumpEnd()

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            end.set(done)
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !end.isOver else { return }
                if step() {
                    source.close()   // its own queue: safe
                    if end.finish() { input.markAsFinished() }
                }
            }
        }
    }

    /// The render stops waiting (a stall): the queue may still be stuck in a read; it touches nothing after.
    func abandon() { end.abandon() }

    /// Cancels the reader on the pump's queue (after any read in progress), whatever ended the render:
    /// a failed or cancelled render whose pump was waiting for the writer never gets its callback again.
    func release() { queue.async { [source] in source.close() } }

    /// Appends while the input is ready. True when the video is complete (or stopped).
    private func step() -> Bool {
        while input.isReadyForMoreMediaData {
            if job.shouldStop { return true }
            if pendingIndex < pending.count {
                let (buffer, slot) = pending[pendingIndex]
                pendingIndex += 1
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(slot), timescale: Exporter.fps)) else {
                    job.fail(.writeFailed(job.writer.error?.localizedDescription ?? "video append"))
                    return true
                }
                written += 1
                job.touch()
                report(Double(slot + 1) / Double(slots.total))
                continue
            }
            pending.removeAll(keepingCapacity: true); pendingIndex = 0
            if drained { return true }
            job.note("video", "reading after \(written) frames (\(uncopied) not copied)")
            let next: VideoSource.Read
            do { next = try source.next() } catch {
                job.fail(.readFailed("\(error)"))
                return true
            }
            job.note("video", "read, \(written) frames written")
            switch next {
            case .frame(let frame, let time):
                if let held { place(held.frame, shownFrom: held.time, to: time, in: source.run) }
                held = (frame, time)
            case .runEnded(let run):
                if let held { place(held.frame, shownFrom: held.time, to: .infinity, in: run) }
                held = nil
            case .done:
                drained = true
                if let last { for s in slots.finish() { pending.append((last, s)) } }
            }
        }
        job.note("video", "waiting for the writer, \(written) frames written")
        return false
    }

    /// Places a frame shown on [from, to) in the source wherever the run's parts show it (none when it
    /// falls in a cut: it is not copied then).
    private func place(_ frame: CVPixelBuffer, shownFrom from: Double, to: Double, in run: VideoRun) {
        let times = run.outputTimes(shownFrom: from, to: to)
        guard !times.isEmpty else { return }
        let image = own(frame)
        for t in times {
            let placement = slots.place(time: t)
            if let previous = last ?? (placement.slot != nil ? image : nil) {
                for s in placement.repeats { pending.append((previous, s)) }
            }
            if let slot = placement.slot { pending.append((image, slot)) }
            last = image
        }
    }

    /// A copy of a decoded frame in the adaptor's pool (the decoder gets its buffer back now). Falls back
    /// to the frame itself when there is no pool or the formats differ.
    private var uncopied = 0
    private func own(_ frame: CVPixelBuffer) -> CVPixelBuffer {
        let copy = copied(frame)
        if copy === frame { uncopied += 1 }
        return copy
    }

    private func copied(_ frame: CVPixelBuffer) -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { return frame }
        var copy: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &copy) == kCVReturnSuccess, let copy,
              CVPixelBufferGetPixelFormatType(copy) == CVPixelBufferGetPixelFormatType(frame),
              CVPixelBufferGetPlaneCount(copy) == CVPixelBufferGetPlaneCount(frame) else { return frame }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        for plane in 0..<CVPixelBufferGetPlaneCount(frame) {
            guard let src = CVPixelBufferGetBaseAddressOfPlane(frame, plane),
                  let dst = CVPixelBufferGetBaseAddressOfPlane(copy, plane) else { return frame }
            let srcRow = CVPixelBufferGetBytesPerRowOfPlane(frame, plane), dstRow = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)
            let rows = min(CVPixelBufferGetHeightOfPlane(frame, plane), CVPixelBufferGetHeightOfPlane(copy, plane))
            let bytes = min(srcRow, dstRow)
            for r in 0..<rows { memcpy(dst + r * dstRow, src + r * srcRow, bytes) }
        }
        CVBufferPropagateAttachments(frame, copy)
        return copy
    }

    private func report(_ p: Double) {
        if p - lastReported >= 0.005 || p >= 1 { lastReported = p; progress(min(1, p)) }
    }
}

/// Audio: the rendered sound's buffers (already on the output timeline, joins crossfaded), up to `end`.
final class AudioPump: @unchecked Sendable {
    let input: AVAssetWriterInput
    let source: PCMFileSource
    let end: CMTime
    let job: RenderJob
    private let queue = DispatchQueue(label: "bubble.export.audio")

    init(input: AVAssetWriterInput, source: PCMFileSource, end: CMTime, job: RenderJob) {
        self.input = input; self.source = source; self.end = end; self.job = job
    }

    private let ended = PumpEnd()

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            ended.set(done)
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !ended.isOver else { return }
                if step() { if ended.finish() { input.markAsFinished() } }
            }
        }
    }

    func abandon() { ended.abandon() }

    private func step() -> Bool {
        while input.isReadyForMoreMediaData {
            if job.shouldStop { return true }
            let next: CMSampleBuffer?
            do { next = try source.next() } catch {
                job.fail(.readFailed("\(error)"))
                return true
            }
            guard let sample = next else { return true }
            if CMSampleBufferGetPresentationTimeStamp(sample) >= end { return true }
            guard input.append(sample) else {
                job.fail(.writeFailed(job.writer.error?.localizedDescription ?? "audio append"))
                return true
            }
            job.touch()
        }
        return false
    }
}

/// How a pump's wait ends, once: it finished (resume, then mark its input finished) or the render
/// abandoned it (resume only; the pump's queue touches nothing after).
final class PumpEnd: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var over = false

    func set(_ c: CheckedContinuation<Void, Never>) { lock.withLock { continuation = c } }
    var isOver: Bool { lock.withLock { over } }

    /// True when this call ended the wait (the caller may still touch the writer input).
    func finish() -> Bool {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !over else { return nil }
            over = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
        return c != nil
    }

    func abandon() { _ = finish() }
}

/// The writer side of a stall report (read from the watchdog's task).
final class WriterState: @unchecked Sendable, CustomStringConvertible {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
    init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput?) {
        self.writer = writer; self.video = video; self.audio = audio
    }
    var description: String {
        "video input ready \(video.isReadyForMoreMediaData), audio input ready \(audio?.isReadyForMoreMediaData ?? false), writer status \(writer.status.rawValue)"
    }
}
