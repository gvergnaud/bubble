// ScreenCaptureKit side of a take: filter, configuration, the SCStream and its outputs, the 30 Hz tick.
// Owner: capture track. Spec: docs/architecture.md §3 (SCStreamConfiguration, Frames, Start), §3.3, §3.4.
//
// Confinement: SCK delivers samples on `queue` (LiveRecorder's writerQueue), and the tick timer runs
// on it too, so RecordingSession only ever runs there. Window mode follows the window on its own
// utility queue (`followQueue`), so the window-server poll never delays the 30 Hz tick. Every change
// to the running stream (crop, mic, filter) goes through one serial path (`updates`, StreamUpdates.swift).

import AppKit
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
        var settings: StreamSettings
        /// Window mode: the window to follow during the take.
        var window: FollowedWindow?
    }

    /// The recorded window: its id, its app, the display it is on and its crop there.
    struct FollowedWindow: Sendable {
        var id: CGWindowID
        var appPID: pid_t
        var displayID: CGDirectDisplayID
        /// SCStreamConfiguration.sourceRect: the window on that display, in the display's points.
        var crop: CGRect
        var bubbleID: CGWindowID?
    }

    let session: RecordingSession
    let queue: DispatchQueue
    /// SCK stopped the stream on its own (display gone, permission revoked, user stopped it). Any thread.
    var onStreamError: (@Sendable (Error) -> Void)?

    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    /// The one path for changes to the running stream; set in start(), before following begins.
    private var updates: LatestOnly<StreamState>?

    /// Window mode: what happened to the recorded window. Called on the follow queue.
    enum WindowEvent: Sendable, Equatable {
        /// Moved or resized: its frame now, AppKit global points.
        case moved(CGRect)
        case hidden(WindowHiddenReason)
        /// Back, at this frame (AppKit global points).
        case shown(CGRect)
        case gone
    }
    var onWindowEvent: (@Sendable (WindowEvent) -> Void)?

    // Following state, confined to `followQueue`.
    private let followQueue = DispatchQueue(label: "local.bubble.capture.follow", qos: .utility)
    private var followed: FollowedWindow?
    private var followHidden = false
    private var lastFrameChange = Date.distantPast
    private var followTicks = 0
    private var cropSequence = 0
    private var filterVersion = 0
    /// Apps with a window on screen when the filter was last built: a new one means a new app
    /// whose windows the filter does not exclude yet.
    private var knownAppPIDs: Set<pid_t> = []
    private var slowPolls = 0
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
            switch options.source {
            case .display:
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: kept)
                return makePlan(filter: filter, crop: nil, window: nil, options: options)

            case .area(let rect):
                let displayBounds = CGDisplayBounds(display.displayID)
                let cg = CaptureGeometry.cgGlobal(fromAppKit: rect, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
                guard let crop = CaptureGeometry.crop(cg, onDisplay: displayBounds) else {
                    throw RecorderError.captureFailed("The area is not on that display.")
                }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: kept)
                return makePlan(filter: filter, crop: crop, window: nil, options: options)

            case .window(let id):
                guard let target = content.windows.first(where: { $0.windowID == id }), target.isOnScreen,
                      let app = target.owningApplication,
                      let crop = CaptureGeometry.crop(target.frame, onDisplay: CGDisplayBounds(display.displayID)) else {
                    throw RecorderError.windowNotFound
                }
                let filter = windowModeFilter(content, display: display, appPID: app.processID, bubble: kept)
                let followed = FollowedWindow(id: id, appPID: app.processID, displayID: display.displayID,
                                              crop: crop, bubbleID: options.bubbleWindowID)
                return makePlan(filter: filter, crop: crop, window: followed, options: options)
            }
        }
    }

    /// Window mode: the display minus every app but the target's (Bubble included), plus the bubble.
    /// The target keeps its menus, sheets, popovers and tooltips (separate windows); a Bubble window
    /// opened mid-take (a toast, the hover controls) can never be in the video; other apps never
    /// cover the window.
    private static func windowModeFilter(_ content: SCShareableContent, display: SCDisplay, appPID: pid_t,
                                         bubble: [SCWindow]) -> SCContentFilter {
        let others = content.applications.filter { $0.processID != appPID }
        return SCContentFilter(display: display, excludingApplications: others, exceptingWindows: bubble)
    }

    /// The window-mode filter for `window`, from fresh shareable content (an app launched mid-take).
    static func windowFilter(for window: FollowedWindow) async throws -> SCContentFilter {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == window.displayID }),
              content.applications.contains(where: { $0.processID == window.appPID }) else {
            throw RecorderError.windowNotFound
        }
        let bubble = content.windows.filter { $0.windowID == window.bubbleID }
        return windowModeFilter(content, display: display, appPID: window.appPID, bubble: bubble)
    }

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

    /// `crop`: window/area mode, the part of the display to record (display points); the video is
    /// that size in native pixels, fixed for the take (a resized window is letterboxed).
    private static func makePlan(filter: SCContentFilter, crop: CGRect?, window: FollowedWindow?,
                                 options: RecordingOptions) -> Plan {
        let scale = CGFloat(filter.pointPixelScale)
        let video = crop.map { CaptureGeometry.videoSettings(cropSize: $0.size, scale: scale) }
            ?? VideoSettings.forDisplay(pointSize: filter.contentRect.size, scale: scale)
        let settings = StreamSettings(width: video.width, height: video.height, fps: video.fps,
                                      showClicks: options.showClicks, microphoneID: options.microphoneID,
                                      computerSound: options.captureComputerSound, crop: crop)
        return Plan(filter: filter, video: video, settings: settings, window: window)
    }

    // MARK: Start / stop

    func start(_ plan: Plan, microphone: Bool, computerSound: Bool) async throws {
        let stream = SCStream(filter: plan.filter, configuration: plan.settings.makeConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        if computerSound { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream
        let job = StreamJob(stream: stream)
        updates = LatestOnly(initial: StreamState(settings: plan.settings, filter: plan.filter)) { applied, wanted in
            if applied.filterVersion != wanted.filterVersion {
                try await job.stream.updateContentFilter(wanted.filter)
            }
            if applied.settings != wanted.settings {
                try await job.stream.updateConfiguration(wanted.settings.makeConfiguration())
            }
        }
        try await stream.startCapture()
        queue.async { self.startTicking() }
        if let window = plan.window { followQueue.async { self.startFollowing(window) } }
    }

    /// Stops the tick first (nothing is written after `host`), then the capture.
    /// Returns the host time the take ends at.
    func stop() async -> CMTime {
        followQueue.sync { stopFollowing() }
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
    func updateMicrophone(_ id: String?) async throws {
        guard let updates else { return }
        if let error = await updates.update({ $0.settings.microphoneID = id }) { throw error }
    }

    // MARK: Following the recorded window (window mode, on `followQueue`)

    /// Polls the window server for the window: 10 Hz while it moved in the last second, else 4 Hz.
    /// Never on the main actor or the writer queue.
    private func startFollowing(_ window: FollowedWindow) {
        followed = window
        followHidden = false
        knownAppPIDs = Self.onScreenAppPIDs()
        let timer = DispatchSource.makeTimerSource(queue: followQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.followTick() }
        timer.resume()
        followTimer = timer
    }
    private var followTimer: DispatchSourceTimer?

    private func stopFollowing() {
        followTimer?.cancel()
        followTimer = nil
        followed = nil
    }

    private func followTick() {
        followTicks += 1
        let fast = Date().timeIntervalSince(lastFrameChange) < 1
        if followTicks % (fast ? 2 : 5) == 0 { pollWindow() }
        if followTicks % 40 == 0 { refreshFilterIfNewApps() }
    }

    private func pollWindow() {
        guard var window = followed else { return }
        let began = DispatchTime.now().uptimeNanoseconds
        let sample = Self.sample(window)
        let took = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        if took > 2, slowPolls < 5 {
            slowPolls += 1
            CaptureLog.info("capture: window poll took \(String(format: "%.1f", took)) ms")
        }
        let change = CaptureGeometry.follow(lastCrop: window.crop, wasHidden: followHidden, sample: sample,
                                            displayBounds: CGDisplayBounds(window.displayID),
                                            otherDisplays: Self.otherDisplayBounds(than: window.displayID))
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        func appKit(_ s: CaptureGeometry.WindowSample?) -> CGRect {
            CaptureGeometry.appKitGlobal(fromCG: s?.bounds ?? .zero, mainDisplayHeight: mainHeight)
        }
        switch change {
        case .unchanged:
            break
        case .moved(let crop):
            window.crop = crop
            followed = window
            lastFrameChange = Date()
            applyCrop(crop)
            onWindowEvent?(.moved(appKit(sample)))
        case .hidden(let reason):
            followHidden = true
            log.info("recorded window hidden: \(String(describing: reason), privacy: .public)")
            onWindowEvent?(.hidden(reason))
        case .visibleAgain(let crop):
            followHidden = false
            window.crop = crop
            followed = window
            applyCrop(crop)
            onWindowEvent?(.shown(appKit(sample)))
        case .gone:
            log.info("recorded window gone")
            stopFollowing()
            onWindowEvent?(.gone)
        }
    }

    /// Sends the crop down the serial path; a crop that reaches it after a newer one is dropped.
    private func applyCrop(_ crop: CGRect) {
        guard let updates else { return }
        cropSequence += 1
        let sequence = cropSequence
        Task {
            if let error = await updates.update({ $0.setCrop(crop, sequence: sequence) }) {
                CaptureLog.info("capture: crop update failed: \(error.localizedDescription)")
            }
        }
    }

    /// An app launched mid-take is not in the filter's excluded apps: rebuild the filter so its
    /// windows stay out of the crop.
    private func refreshFilterIfNewApps() {
        guard let window = followed, let updates else { return }
        let now = Self.onScreenAppPIDs()
        guard !now.isSubset(of: knownAppPIDs) else { return }
        knownAppPIDs.formUnion(now)
        filterVersion += 1
        let version = filterVersion
        Task {
            do {
                let filter = try await ScreenCapture.windowFilter(for: window)
                let box = FilterBox(filter: filter)
                if let error = await updates.update({ $0.setFilter(box.filter, version: version) }) { throw error }
            } catch {
                CaptureLog.info("capture: filter refresh failed: \(error.localizedDescription)")
            }
        }
    }

    /// The window as the window server sees it now; nil if it or its app is gone.
    static func sample(_ window: FollowedWindow) -> CaptureGeometry.WindowSample? {
        guard let app = NSRunningApplication(processIdentifier: window.appPID), !app.isTerminated,
              let info = RecordedWindow.info(window.id), info.ownerPID == window.appPID else { return nil }
        return CaptureGeometry.WindowSample(bounds: info.bounds, isOnScreen: info.isOnScreen, appHidden: app.isHidden)
    }

    private static func otherDisplayBounds(than displayID: CGDirectDisplayID) -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 1 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { $0 != displayID }.map { CGDisplayBounds($0) }
    }

    private static func onScreenAppPIDs() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
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

/// Hands the SCStream (thread-safe in SCK) to the update path.
private struct StreamJob: @unchecked Sendable {
    let stream: SCStream
}

/// Hands a content filter (immutable once made) across tasks.
private struct FilterBox: @unchecked Sendable {
    let filter: SCContentFilter
}
