// The real Recorder: ScreenCaptureKit → RecordingSession → ~/Movies/Bubble. Owner: capture track.
// Spec: docs/architecture.md §3 (Start, Stop, Pause, Discard, Writer failure), §3.3.
//
// Threads: this class is on the main actor. The take itself (RecordingSession, the SCK sample
// handlers, the 30 Hz tick) lives on `writerQueue`; this class reaches it with writerQueue.sync for
// pause/resume (short) and hops back to the main actor for events. A mirror of the session's
// Timeline on the main actor answers `elapsed` without touching the queue.

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

@MainActor
public final class LiveRecorder: Recorder {
    public private(set) var state: RecorderState = .idle {
        didSet { if state != oldValue { onEvent?(.stateChanged(state)) } }
    }
    public var onEvent: (@MainActor (RecorderEvent) -> Void)?

    /// The file of the current take, else of the last one.
    public private(set) var currentURL: URL?
    public private(set) var lastResult: RecordingResult?

    private let writerQueue = DispatchQueue(label: "local.bubble.Bubble.writer", qos: .userInteractive)
    private var take: Take?
    private var mirror = Timeline()
    private let events = SystemEvents()
    private var diskTimer: Timer?
    private var warnedLowDisk = false
    /// stop() or discard() came while start() was still waiting for the first frame.
    private var pendingStop: StopReason?
    private var pendingStopWaiters: [CheckedContinuation<RecordingResult, Never>] = []
    private let log = Logger(subsystem: "local.bubble.Bubble", category: "LiveRecorder")

    /// How long start() waits for the first frame before giving up.
    public var firstFrameTimeout: Duration = .seconds(5)

    /// One take: what stop() needs to finish it.
    private struct Take {
        var options: RecordingOptions
        var plan: ScreenCapture.Plan
        var capture: ScreenCapture
        var session: RecordingSession
        var url: URL
        var microphoneID: String?
        var finishing = false
    }

    public init() {}

    public var elapsed: TimeInterval {
        switch state {
        case .recording, .paused, .finishing: mirror.elapsed(atHost: hostNow())
        case .idle, .starting: 0
        }
    }

    // MARK: Start

    public func start(_ options: RecordingOptions) async throws -> URL {
        guard state == .idle, take == nil else { throw RecorderError.alreadyRecording }
        guard CGPreflightScreenCaptureAccess() else { throw RecorderError.screenPermissionMissing }
        if let free = DiskPolicy.bytesFree(at: options.folder),
           DiskPolicy.decide(bytesFree: free, recording: false) == .refuseStart {
            throw RecorderError.notEnoughDiskSpace(bytesFree: free)
        }
        state = .starting
        pendingStop = nil
        do {
            let url = try await begin(options)
            state = .recording
            startWatching()
            if let reason = pendingStop {
                // Stop was pressed while starting: finish now and hand the real file to the waiters.
                let result = await finish(reason) ?? failedResult(url: url, "The recording could not be finished.")
                resolvePendingStop(result)
            }
            return url
        } catch {
            state = .idle
            let recorderError = (error as? RecorderError) ?? RecorderError.captureFailed(error.localizedDescription)
            if pendingStop != nil {
                resolvePendingStop(failedResult(url: currentURL ?? options.folder, "The recording did not start: \(recorderError)"))
            }
            throw recorderError
        }
    }

    private func failedResult(url: URL, _ message: String) -> RecordingResult {
        RecordingResult(url: url, duration: 0, bytes: 0, reason: .failed(message))
    }

    private func resolvePendingStop(_ result: RecordingResult) {
        pendingStop = nil
        let waiters = pendingStopWaiters
        pendingStopWaiters = []
        for waiter in waiters { waiter.resume(returning: result) }
    }

    /// While .starting: remember the stop and wait for start() to finish the take.
    private func stopWhenStarted(_ reason: StopReason) async -> RecordingResult {
        if pendingStop == nil || reason == .discarded { pendingStop = reason }
        return await withCheckedContinuation { pendingStopWaiters.append($0) }
    }

    private func begin(_ options: RecordingOptions) async throws -> URL {
        let plan = try await ScreenCapture.plan(for: options)
        var sources: Set<AudioSource> = []
        if options.microphoneID != nil { sources.insert(.microphone) }
        if options.captureComputerSound { sources.insert(.computer) }

        let url: URL
        do { url = try RecordingFiles.newURL(in: options.folder) } catch {
            throw RecorderError.captureFailed("Could not create the folder \(options.folder.path): \(error.localizedDescription)")
        }
        let writer = try RecordingWriter(url: url, video: plan.video, audio: sources.isEmpty ? nil : AudioSettings())
        let session = RecordingSession(writer: writer, audioSources: sources)
        let capture = ScreenCapture(session: session, queue: writerQueue)
        let firstFrame = FirstFrame()
        session.onFirstFrame = { host in Task { @MainActor in firstFrame.arrived(host) } }
        session.onFailure = { [weak self] message in
            Task { @MainActor in await self?.endOnItsOwn(.failed(message)) }
        }
        capture.onStreamError = { [weak self] error in
            Task { @MainActor in await self?.streamStopped(error) }
        }
        take = Take(options: options, plan: plan, capture: capture, session: session, url: url, microphoneID: options.microphoneID)
        currentURL = url
        mirror = Timeline()

        do {
            try await capture.start(plan, microphone: options.microphoneID != nil, computerSound: options.captureComputerSound)
            let host = try await firstFrame.wait(timeout: firstFrameTimeout)
            mirror.start(at: host)
            log.info("recording \(url.lastPathComponent, privacy: .public) \(plan.video.width)x\(plan.video.height)")
            return url
        } catch {
            // Nothing worth keeping: stop, and remove the empty file.
            _ = await capture.stop()
            let end = writerQueue.sync { session.prepareFinish(at: hostNow()) }
            try? await writer.finish(at: end)
            try? FileManager.default.removeItem(at: url)
            take = nil
            throw error
        }
    }

    // MARK: Pause / resume

    public func pause() {
        guard state == .recording, let session = take?.session else { return }
        let host = writerQueue.sync { () -> CMTime in
            let now = hostNow()
            session.pause(at: now)
            return now
        }
        mirror.pause(at: host)
        state = .paused
    }

    public func resume() {
        guard state == .paused, let session = take?.session else { return }
        let host = writerQueue.sync { () -> CMTime in
            let now = hostNow()
            session.resume(at: now)
            return now
        }
        mirror.resume(at: host)
        state = .recording
    }

    // MARK: Stop / discard

    /// While starting: waits for the first frame, then stops (a start that fails gives reason
    /// .failed, so the app runs no after-stop actions). With no take: the last result, or .failed.
    public func stop() async -> RecordingResult {
        if state == .starting { return await stopWhenStarted(.user) }
        if let result = await finish(.user) { return result }
        return lastResult ?? failedResult(url: currentURL ?? RecordingFiles.defaultFolder, "No recording to stop.")
    }

    public func discard() async {
        let finished: RecordingResult? = state == .starting ? await stopWhenStarted(.discarded) : await finish(.discarded)
        guard let result = finished, result.reason == .discarded else { return }
        do {
            try await NSWorkspace.shared.recycle([result.url])
        } catch {
            log.error("could not move \(result.url.lastPathComponent, privacy: .public) to the Trash: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.trashItem(at: result.url, resultingItemURL: nil)
        }
    }

    /// Stops capture and finalizes the file. nil if there is no take (or it is already finishing).
    private func finish(_ reason: StopReason) async -> RecordingResult? {
        guard var current = take, !current.finishing, state == .recording || state == .paused else { return nil }
        current.finishing = true
        take = current
        stopWatching()
        state = .finishing
        let session = current.session
        let stopHost = await current.capture.stop()
        if state == .finishing, mirror.isPaused == false { mirror.pause(at: stopHost) }
        let end = writerQueue.sync { session.prepareFinish(at: stopHost) }
        var finalReason = reason
        do {
            try await session.writer.finish(at: end)
        } catch {
            log.error("finish: \(String(describing: error), privacy: .public)")
            if reason == .user || reason == .discarded, let failure = session.failure { finalReason = .failed(failure) }
        }
        let result = RecordingResult(url: current.url, duration: end.seconds, bytes: session.writer.bytesWritten, reason: finalReason)
        take = nil
        lastResult = result
        state = .idle
        log.info("stopped (\(String(describing: finalReason), privacy: .public)): \(result.duration, privacy: .public) s, \(result.bytes, privacy: .public) bytes")
        return result
    }

    /// The take ends without the app asking: keep the file, tell the app.
    private func endOnItsOwn(_ reason: StopReason) async {
        guard let result = await finish(reason) else { return }
        onEvent?(.stoppedOnItsOwn(result))
    }

    private func streamStopped(_ error: Error) async {
        guard let take else { return }
        let ns = error as NSError
        let display = take.options.displayID
        // Unverified on real hardware (docs/qa.md): log what SCK says, so the manual tests tell us.
        log.error("stream stopped by the system: \(ns.domain, privacy: .public) \(ns.code, privacy: .public), display online \(SystemEvents.isDisplayOnline(display), privacy: .public) active \(SystemEvents.isDisplayActive(display), privacy: .public)")
        let reason: StopReason
        if !SystemEvents.isDisplayOnline(display) {
            reason = .displayDisconnected
        } else if !CGPreflightScreenCaptureAccess() || Self.isUserStop(error) {
            reason = .screenPermissionRevoked
        } else if !SystemEvents.isDisplayActive(display) {
            // The display went to sleep and SCK gave up on it: the take can't survive that; save
            // it as a normal stop.
            reason = .user
        } else {
            reason = .failed(error.localizedDescription)
        }
        await endOnItsOwn(reason)
    }

    /// The user declined or stopped the capture (macOS's own "Stop sharing", or the grant was removed).
    private static func isUserStop(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain else { return false }
        let codes: [SCStreamError.Code] = [.userDeclined, .userStopped]
        return codes.map(\.rawValue).contains(error.code)
    }

    // MARK: Watching the system during a take

    private func startWatching() {
        warnedLowDisk = false
        events.onLockOrSleep = { [weak self] in self?.pause() }
        events.onPowerOff = { [weak self] in Task { await self?.endOnItsOwn(.appQuitting) } }
        events.onDisplaysChanged = { [weak self] in
            guard let self, let take = self.take, !SystemEvents.isDisplayOnline(take.options.displayID) else { return }
            Task { await self.endOnItsOwn(.displayDisconnected) }
        }
        events.onMicrophoneGone = { [weak self] id in
            guard let self, let take = self.take, take.microphoneID == id else { return }
            Task { await self.switchMicrophone() }
        }
        events.start()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisk() }
        }
    }

    private func stopWatching() {
        events.stop()
        diskTimer?.invalidate()
        diskTimer = nil
    }

    private func checkDisk() {
        guard let take, let free = DiskPolicy.bytesFree(at: take.url) else { return }
        switch DiskPolicy.decide(bytesFree: free, recording: true) {
        case .stopAndSave:
            Task { await endOnItsOwn(.diskAlmostFull) }
        case .warn where !warnedLowDisk:
            warnedLowDisk = true
            let seconds = max(1, elapsed)
            let rate = Double(take.session.writer.bytesWritten) / seconds
            let minutes = DiskPolicy.minutesLeft(bytesFree: free, bytesPerSecond: rate)
            onEvent?(.lowDisk(bytesLeft: free, minutesLeft: minutes))
        default:
            break
        }
    }

    /// The mic in use was unplugged: go on with the system default mic, or with no mic.
    private func switchMicrophone() async {
        guard var current = take else { return }
        let next = AVCaptureDevice.default(for: .audio)
        do {
            try await current.capture.updateMicrophone(next?.uniqueID, plan: current.plan)
        } catch {
            log.error("mic switch: \(error.localizedDescription, privacy: .public)")
            current.microphoneID = nil
            take = current
            onEvent?(.microphoneLost)
            return
        }
        current.microphoneID = next?.uniqueID
        take = current
        if let next { onEvent?(.microphoneSwitched(name: next.localizedName)) } else { onEvent?(.microphoneLost) }
    }
}

/// Waits for the first written frame, with a timeout. Main actor.
@MainActor
private final class FirstFrame {
    private var host: CMTime?
    private var continuation: CheckedContinuation<CMTime, Error>?

    func arrived(_ host: CMTime) {
        guard self.host == nil else { return }
        self.host = host
        continuation?.resume(returning: host)
        continuation = nil
    }

    func wait(timeout: Duration) async throws -> CMTime {
        if let host { return host }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(throwing: RecorderError.captureFailed("No picture came from the screen capture."))
            }
        }
    }
}
