// ScreenCaptureKit side of a take: filter, configuration, the SCStream and its outputs, the 30 Hz tick.
// Owner: capture track. Spec: docs/architecture.md §3 (SCStreamConfiguration, Frames, Start), §3.3.
//
// Confinement: SCK delivers samples on `queue` (LiveRecorder's writerQueue), and the tick timer runs
// on it too, so RecordingSession only ever runs there. start()/stop()/updateMicrophone() are called
// from the main actor; they touch the SCStream (thread-safe in SCK) and hop to `queue` for the rest.

import AVFoundation
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

public func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// What a take records: the filter (display minus our app, plus the bubble) and the sizes.
    struct Plan {
        var filter: SCContentFilter
        var video: VideoSettings
        var configuration: SCStreamConfiguration
    }

    let session: RecordingSession
    let queue: DispatchQueue
    /// SCK stopped the stream on its own (display gone, permission revoked, user stopped it). Any thread.
    var onStreamError: (@Sendable (Error) -> Void)?

    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private let log = Logger(subsystem: "local.bubble.Bubble", category: "ScreenCapture")

    init(session: RecordingSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    // MARK: Plan

    /// Finds the display and the bubble window and builds the filter and configuration.
    @MainActor
    static func plan(for options: RecordingOptions) async throws -> Plan {
        // A bubble panel ordered in just before start() (the ⌥⇧L fast path with no countdown) can
        // take a moment to be listed by the window server: look again every 100 ms, up to 1 s.
        var attempt = 0
        while true {
            let content = try await shareableContent()
            guard let display = content.displays.first(where: { $0.displayID == options.displayID }) else {
                throw RecorderError.displayNotFound
            }
            let me = content.applications.filter { $0.processID == getpid() }
            var kept: [SCWindow] = []
            if let bubbleID = options.bubbleWindowID {
                guard let bubble = content.windows.first(where: { $0.windowID == bubbleID }), bubble.isOnScreen else {
                    attempt += 1
                    if attempt > 10 { throw RecorderError.captureFailed("The camera bubble is not on screen.") }
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                kept = [bubble]
            }
            return makePlan(display: display, excluding: me, keeping: kept, options: options)
        }
    }

    @MainActor
    private static func shareableContent() async throws -> SCShareableContent {
        do {
            // All windows, not only on-screen ones: our app is then listed even with no window
            // visible yet, so windows it opens during the take (alerts...) are excluded too.
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if !CGPreflightScreenCaptureAccess() { throw RecorderError.screenPermissionMissing }
            throw RecorderError.captureFailed("Could not list what's on screen: \(error.localizedDescription)")
        }
    }

    private static func makePlan(display: SCDisplay, excluding me: [SCRunningApplication], keeping kept: [SCWindow],
                                 options: RecordingOptions) -> Plan {
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: kept)
        let video = VideoSettings.forDisplay(pointSize: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))

        let config = SCStreamConfiguration()
        config.width = video.width
        config.height = video.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(video.fps))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.showMouseClicks = options.showClicks
        config.captureMicrophone = options.microphoneID != nil
        config.microphoneCaptureDeviceID = options.microphoneID
        config.capturesAudio = options.captureComputerSound
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        return Plan(filter: filter, video: video, configuration: config)
    }

    // MARK: Start / stop

    func start(_ plan: Plan, microphone: Bool, computerSound: Bool) async throws {
        let stream = SCStream(filter: plan.filter, configuration: plan.configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        if computerSound { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
        queue.async { self.startTicking() }
    }

    /// Stops the tick first (nothing is written after `host`), then the capture.
    /// Returns the host time the take ends at.
    func stop() async -> CMTime {
        let host = queue.sync { () -> CMTime in
            timer?.cancel()
            timer = nil
            return hostNow()
        }
        if let stream {
            do { try await stream.stopCapture() } catch { log.info("stopCapture: \(error.localizedDescription, privacy: .public)") }
        }
        stream = nil
        return host
    }

    /// Switches the mic mid-take (the old one was unplugged). nil = no mic any more.
    func updateMicrophone(_ id: String?, plan: Plan) async throws {
        guard let stream else { return }
        let config = plan.configuration
        config.captureMicrophone = id != nil
        config.microphoneCaptureDeviceID = id
        try await stream.updateConfiguration(config)
    }

    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let interval = 1.0 / Double(session.writer.video.fps)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [session] in session.tick(at: hostNow()) }
        timer.resume()
        self.timer = timer
    }

    // MARK: SCStreamOutput (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen:
            // Only .complete frames carry a new image; the others say "idle" or "blank".
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
            session.screenFrame(pixelBuffer, at: buffer.presentationTimeStamp)
        case .microphone:
            session.audio(buffer, from: .microphone)
        case .audio:
            session.audio(buffer, from: .computer)
        @unknown default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        onStreamError?(error)
    }
}
