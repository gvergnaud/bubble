// AVAssetWriter wrapper. Owner: capture track. Spec: docs/architecture.md §3 (Writer settings), §6.
//
// Confinement: not thread-safe. Every call comes from one serial queue (LiveRecorder's writerQueue,
// or the test's own thread). `@unchecked Sendable` only so it can be captured by that queue's blocks.

import AVFoundation
import CoreMedia
import Foundation
import os

public enum WriterError: Error, Sendable, Equatable {
    case notWriting
    case appendFailed(String)
    case nonIncreasingTime
}

/// AVAssetWriter wrapper: H.264 + AAC in .mp4, movie fragments every 2 s (crash-safe), streams to disk.
/// Not thread-safe: call it from one serial queue. Times are FILE times (Timeline.fileTime), strictly
/// increasing per track, video at a constant frame rate (FramePump guarantees it).
public final class RecordingWriter: @unchecked Sendable {
    public let url: URL
    public let video: VideoSettings
    public let audio: AudioSettings?
    public let realTime: Bool

    /// Frames handed to the encoder / dropped because the encoder was busy (real-time mode only).
    public private(set) var videoFramesWritten = 0
    public private(set) var videoFramesDropped = 0
    public private(set) var audioFramesWritten: Int64 = 0
    /// Audio frames dropped because the encoder was busy (real-time mode) / cut because they
    /// overlapped the previous chunk.
    public private(set) var audioFramesDropped: Int64 = 0
    public private(set) var audioFramesTrimmed: Int64 = 0

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private var lastVideoTime: CMTime?
    private var lastPixelBuffer: CVPixelBuffer?
    /// End of the last audio sample written, in samples at `audio.sampleRate`.
    private var audioEnd: Int64?
    private var audioFormat: CMAudioFormatDescription?
    private var finished = false
    private let log = Logger(subsystem: "local.bubble.Bubble", category: "RecordingWriter")

    /// `realTime: false` lets tests and bubble-diag write faster than real time: appends then wait
    /// for the encoder instead of dropping. The inputs are in real-time mode either way
    /// (`expectsMediaDataInRealTime = true`): in offline mode AVAssetWriter interleaves in ~0.5 s
    /// chunks and stops taking video until the audio reaches the next chunk boundary, which
    /// deadlocks a single-threaded producer that writes audio and video in turn.
    /// Throws if the file exists (names are unique: RecordingFiles) or the writer cannot start.
    public init(url: URL, video: VideoSettings, audio: AudioSettings?, realTime: Bool = true) throws {
        self.url = url; self.video = video; self.audio = audio; self.realTime = realTime
        if FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: video.fragmentIntervalSeconds, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: video.width,
            AVVideoHeightKey: video.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: video.averageBitRate,
                AVVideoExpectedSourceFrameRateKey: video.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: video.keyFrameIntervalSeconds,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw WriterError.appendFailed("cannot add the video input") }
        writer.add(videoInput)
        // Must exist before startWriting() (it throws otherwise).
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: audio.channels,
                AVEncoderBitRateKey: audio.bitRate,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw WriterError.appendFailed("cannot add the audio input") }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw WriterError.appendFailed(Self.describe(writer.error) ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// The writer failed (disk full, encoder error...). The file stays playable up to the last fragment.
    public var failure: String? {
        writer.status == .failed ? (Self.describe(writer.error) ?? "the writer failed") : nil
    }

    public func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws {
        try checkWriting()
        guard time.isNumeric, time >= .zero else { throw WriterError.nonIncreasingTime }
        if let lastVideoTime, time <= lastVideoTime { throw WriterError.nonIncreasingTime }
        lastPixelBuffer = pixelBuffer
        guard waitUntilReady(videoInput) else {
            videoFramesDropped += 1
            return
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw WriterError.appendFailed(failure ?? "video append failed at \(time.seconds) s")
        }
        lastVideoTime = time
        videoFramesWritten += 1
    }

    /// 48 kHz mono Float32, contiguous (AudioMixer output). A chunk that starts before the end of
    /// the previous one (e.g. right after a resume) loses its overlapping frames (counted in
    /// `audioFramesTrimmed`); one less than 1 ms early is snapped. Throws only for a non-numeric time.
    public func appendAudio(_ buffer: AVAudioPCMBuffer, at time: CMTime) throws {
        guard let audioInput, let audio else { return }
        try checkWriting()
        var frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        guard time.isNumeric else { throw WriterError.nonIncreasingTime }
        let rate = audio.sampleRate
        var start = Int64((time.seconds * rate).rounded())
        var skip = 0
        let floor = audioEnd ?? 0
        if start < floor {
            let early = Int(floor - start)
            if Double(early) / rate >= 0.001 {
                skip = min(frames, early)
                audioFramesTrimmed += Int64(skip)
            }
            start = floor
            frames -= skip
        }
        guard frames > 0 else { return }
        let sample = try makeAudioSample(buffer, skip: skip, frames: frames, start: start, rate: rate)
        guard waitUntilReady(audioInput) else {
            audioFramesDropped += Int64(frames)
            return
        }
        guard audioInput.append(sample) else {
            throw WriterError.appendFailed(failure ?? "audio append failed at \(time.seconds) s")
        }
        audioEnd = start + Int64(frames)
        audioFramesWritten += Int64(frames)
    }

    /// Ends the file at `time` (so a static last screen still lasts until Stop) and finalizes it.
    /// Throws if the writer had failed: the file is still there, playable to the last fragment.
    public func finish(at time: CMTime) async throws {
        guard !finished else { return }
        finished = true
        if writer.status == .writing {
            // A static screen at the end: hold the last frame until `time`. With the pump the last
            // frame is at most one tick old and lasts until the session end by itself.
            let frame = CMTime(value: 1, timescale: CMTimeScale(video.fps))
            if let last = lastVideoTime, let pb = lastPixelBuffer,
               time.isNumeric, time - last > CMTimeMultiplyByFloat64(frame, multiplier: 1.5) {
                try? appendVideo(pb, at: time - frame)
            }
        }
        lastPixelBuffer = nil
        guard writer.status == .writing else {
            if writer.status == .failed { throw WriterError.appendFailed(failure ?? "the writer failed") }
            throw WriterError.notWriting
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let end = CMTimeMaximum(time.isNumeric ? time : .zero, lastVideoTime ?? .zero)
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw WriterError.appendFailed(failure ?? "finishWriting ended with status \(writer.status.rawValue)")
        }
        log.info("finished \(self.url.lastPathComponent, privacy: .public): video \(self.videoFramesWritten) frames, \(self.videoFramesDropped) dropped; audio \(self.audioFramesWritten) frames, \(self.audioFramesDropped) dropped, \(self.audioFramesTrimmed) trimmed")
    }

    /// Bytes on disk so far (fragments are flushed as they are written).
    public var bytesWritten: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Private

    private func checkWriting() throws {
        switch writer.status {
        case .writing where !finished: return
        case .failed: throw WriterError.appendFailed(failure ?? "the writer failed")
        default: throw WriterError.notWriting
        }
    }

    /// Real time: never block the capture queue, drop instead (the pump re-sends a frame 33 ms later).
    /// Offline: wait for the encoder, up to 30 s. Dropping there would leave a video gap, and a gap
    /// fails the fragment writer (-16341, §6): seen on a machine at load 120 with a 1 s wait.
    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        if input.isReadyForMoreMediaData { return true }
        guard !realTime else { return false }
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            if writer.status != .writing || Date() > deadline { return false }
            usleep(500)
        }
        return true
    }

    private func makeAudioSample(_ buffer: AVAudioPCMBuffer, skip: Int, frames: Int, start: Int64, rate: Double) throws -> CMSampleBuffer {
        guard let channel = buffer.floatChannelData?[0] else { throw WriterError.appendFailed("audio is not Float32") }
        if audioFormat == nil {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            var format: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                                        magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                        formatDescriptionOut: &format)
            guard status == noErr, let format else { throw WriterError.appendFailed("audio format: \(status)") }
            audioFormat = format
        }
        let length = frames * 4
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw WriterError.appendFailed("audio block: \(status)") }
        status = CMBlockBufferReplaceDataBytes(with: channel + skip, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        guard status == noErr else { throw WriterError.appendFailed("audio copy: \(status)") }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat!, sampleCount: frames,
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw WriterError.appendFailed("audio sample: \(status)") }
        return sample
    }

    private static func describe(_ error: Error?) -> String? {
        guard let error = error as NSError? else { return nil }
        var text = "\(error.domain) \(error.code): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (underlying \(underlying.domain) \(underlying.code))"
        }
        return text
    }
}
