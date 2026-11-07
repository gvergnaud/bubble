// Owner: E2 (media). docs/editor-architecture.md §4: render the edited video (cuts + speed ranges) to a
// new .mp4. Source never written. AVAssetReader on an AVMutableComposition (cuts by insertion, speed by
// scaleTimeRange; sound by AudioJoiner, pitch kept, joins crossfaded) → video resampled to 30 fps CFR → AVAssetWriter
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
        let srcAudio = try await asset.loadTracks(withMediaType: .audio).first
        let sourceDuration = try await asset.load(.duration)
        let videoRange = try await srcVideo.load(.timeRange)
        let audioRange = try await srcAudio?.load(.timeRange)
        let transform = try await srcVideo.load(.preferredTransform)
        let size = try await srcVideo.load(.naturalSize)
        try Task.checkCancellation()

        // 1. The composition: kept pieces back to back, sped-up / slowed-down ones scaled.
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.readFailed("composition")
        }
        video.preferredTransform = transform
        // The sound is not in the composition: AudioJoiner reads it piece by piece, to crossfade the joins.
        let kept = clamp(pieces, to: sourceDuration.seconds)
        var outputStarts: [Double] = []
        var cursor = CMTime.zero
        for p in kept {
            outputStarts.append(cursor.seconds)
            let range = CMTimeRange(start: CMTime(seconds: p.start, preferredTimescale: timescale),
                                    end: CMTime(seconds: p.end, preferredTimescale: timescale))
            try insert(range, of: srcVideo, available: videoRange, into: video, at: cursor)
            var length = range.duration
            if p.rate != 1 {
                let scaled = CMTime(seconds: range.duration.seconds / p.rate, preferredTimescale: timescale)
                comp.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
                length = scaled
            }
            cursor = cursor + length
        }
        guard cursor > .zero else { throw Failure.nothingKept }
        let total = frameCount(duration: cursor.seconds)
        let end = CMTime(value: CMTimeValue(total), timescale: fps)
        let width = evenPixels(size.width), height = evenPixels(size.height)

        // Fail early rather than mid-render when the disk can't take the file.
        let needed = estimatedBytes(width: width, height: height, duration: cursor.seconds)
        if let free = bytesFree(destination.deletingLastPathComponent()), free < needed {
            throw Failure.notEnoughSpace(needed: needed)
        }

        // 2. Readers: decoded video (420v) from the composition; the sound from AudioJoiner (its own readers,
        // one piece at a time, mono 48 kHz Float32, pitch kept, joins crossfaded). Never one reader for both
        // tracks: an output nobody pulls stalls the other one's copyNextSampleBuffer forever.
        let videoReader: AVAssetReader
        do { videoReader = try AVAssetReader(asset: comp) } catch { throw Failure.readFailed(error.localizedDescription) }
        let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoReader.add(vOut)
        var joiner: AudioJoiner?
        if let srcAudio, let audioRange {
            let plan = AudioJoinPlan.make(pieces: kept, outputStarts: outputStarts, end: cursor.seconds,
                                          sourceDuration: sourceDuration.seconds, crossfade: crossfade,
                                          sampleRate: AudioJoiner.sampleRate)
            do { joiner = try AudioJoiner(track: srcAudio, available: audioRange, plan: plan) } catch {
                throw Failure.readFailed("\(error)")
            }
        }
        let readers = [videoReader]

        // 3. Writer: H.264 High at the source's size, AAC 128 kb/s, moov first.
        let fm = FileManager.default
        // Written in a hidden work folder (the writer puts its own temp files next to its output), moved
        // into place when complete; the folder goes away whatever happens.
        let work = partialFolder(for: destination)
        let partial = work.appendingPathComponent(destination.lastPathComponent)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
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
        vIn.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: nil)
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if joiner != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
            writer.add(i); aIn = i
        }
        writer.shouldOptimizeForNetworkUse = true

        for r in readers where !r.startReading() {
            readers.forEach { $0.cancelReading() }
            throw Failure.readFailed(r.error?.localizedDescription ?? "startReading")
        }
        guard writer.startWriting() else {
            readers.forEach { $0.cancelReading() }
            throw Failure.writeFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        // 4. Pump both inputs on their own queues (offline interleaving); cancel stops both.
        let job = RenderJob(readers: readers, writer: writer, joiner: joiner)
        let videoPump = VideoPump(input: vIn, adaptor: adaptor, output: vOut, reader: videoReader, total: total, job: job, progress: progress)
        let audioPump = aIn.flatMap { i in joiner.map { AudioPump(input: i, joiner: $0, end: end, job: job) } }
        // Watchdog: no sample written for `stallTimeout` = a stuck reader or writer; fail instead of hanging.
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if job.idle > stallTimeout { job.fail(.stalled); return }
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

        if job.isCanceled || Task.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        let readFailure = readers.first { $0.status == .failed }.map { Failure.readFailed($0.error?.localizedDescription ?? "read") }
        readers.forEach { if $0.status == .reading { $0.cancelReading() } }   // audio stopped at `end` may still have samples
        if let failure = job.failure ?? readFailure {
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
    public static func estimatedBytes(width: Int, height: Int, duration: Double) -> Int64 {
        let bitsPerSecond = Double(VideoSettings.bitRate(width: width, height: height, fps: Int(fps)) + 128_000)
        return Int64((bitsPerSecond / 8 * max(0, duration) * 1.1).rounded(.up))
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

    /// Inserts the part of `range` the track has; a missing part stays an empty edit (keeps A/V aligned).
    private static func insert(_ range: CMTimeRange, of track: AVAssetTrack, available: CMTimeRange,
                               into dest: AVMutableCompositionTrack, at cursor: CMTime) throws {
        let have = range.intersection(available)
        guard !have.isEmpty, have.duration.seconds > 1e-6 else { return }
        do { try dest.insertTimeRange(have, of: track, at: cursor + (have.start - range.start)) } catch {
            throw Failure.readFailed(error.localizedDescription)
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

/// Shared by the pumps: cancel flag and first failure.
final class RenderJob: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false
    private var firstFailure: Exporter.Failure?
    let readers: [AVAssetReader]
    let writer: AVAssetWriter
    let joiner: AudioJoiner?

    init(readers: [AVAssetReader], writer: AVAssetWriter, joiner: AudioJoiner?) {
        self.readers = readers; self.writer = writer; self.joiner = joiner
    }

    private var lastActivity = ContinuousClock.now

    /// A pump wrote something.
    func touch() { lock.withLock { lastActivity = .now } }
    var idle: Duration { lock.withLock { ContinuousClock.now - lastActivity } }

    var isCanceled: Bool { lock.withLock { canceled } }
    var failure: Exporter.Failure? { lock.withLock { firstFailure } }

    func cancel() {
        lock.withLock { canceled = true }
        readers.forEach { $0.cancelReading() }
        joiner?.cancel()
    }

    func fail(_ f: Exporter.Failure) {
        lock.withLock { if firstFailure == nil { firstFailure = f } }
        readers.forEach { $0.cancelReading() }
        joiner?.cancel()
    }

    var shouldStop: Bool { lock.withLock { canceled || firstFailure != nil } }
}

/// Video: frames re-stamped on the 30 fps grid. Runs on its own serial queue.
final class VideoPump: @unchecked Sendable {
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let output: AVAssetReaderOutput
    let reader: AVAssetReader
    let job: RenderJob
    let progress: @Sendable (Double) -> Void
    private var slots: FrameSlots
    private var pending: [(CVPixelBuffer, Int)] = []
    private var pendingIndex = 0
    private var last: CVPixelBuffer?
    private var drained = false
    private var lastReported = -1.0
    private let queue = DispatchQueue(label: "bubble.export.video")
    private(set) var written = 0

    init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, output: AVAssetReaderOutput, reader: AVAssetReader,
         total: Int, job: RenderJob, progress: @escaping @Sendable (Double) -> Void) {
        self.input = input; self.adaptor = adaptor; self.output = output; self.reader = reader; self.job = job; self.progress = progress
        self.slots = FrameSlots(total: total)
    }

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                if step() { finished = true; input.markAsFinished(); done.resume() }
            }
        }
    }

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
            guard let sample = output.copyNextSampleBuffer() else {
                drained = true
                if let last { for s in slots.finish() { pending.append((last, s)) } }
                if reader.status == .failed { job.fail(.readFailed(reader.error?.localizedDescription ?? "video read")) }
                continue
            }
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }   // e.g. a marker buffer
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let placement = slots.place(time: t)
            if let previous = last ?? (placement.slot != nil ? image : nil) {
                for s in placement.repeats { pending.append((previous, s)) }
            }
            if let slot = placement.slot { pending.append((image, slot)) }
            last = image
        }
        return false
    }

    private func report(_ p: Double) {
        if p - lastReported >= 0.005 || p >= 1 { lastReported = p; progress(min(1, p)) }
    }
}

/// Audio: AudioJoiner's buffers (already on the output timeline, joins crossfaded), up to `end`.
final class AudioPump: @unchecked Sendable {
    let input: AVAssetWriterInput
    let joiner: AudioJoiner
    let end: CMTime
    let job: RenderJob
    private let queue = DispatchQueue(label: "bubble.export.audio")

    init(input: AVAssetWriterInput, joiner: AudioJoiner, end: CMTime, job: RenderJob) {
        self.input = input; self.joiner = joiner; self.end = end; self.job = job
    }

    func run() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                if step() { finished = true; input.markAsFinished(); done.resume() }
            }
        }
    }

    private func step() -> Bool {
        while input.isReadyForMoreMediaData {
            if job.shouldStop { return true }
            let next: CMSampleBuffer?
            do { next = try joiner.next() } catch {
                job.fail(.readFailed("\(error)"))
                return true
            }
            guard let sample = next else { return true }
            if CMSampleBufferGetPresentationTimeStamp(sample) >= end { joiner.cancel(); return true }
            guard input.append(sample) else {
                job.fail(.writeFailed(job.writer.error?.localizedDescription ?? "audio append"))
                return true
            }
            job.touch()
        }
        return false
    }
}
