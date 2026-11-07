// The camera behind the bubble. Owner: capture track. Spec: docs/architecture.md §3.1.
//
// Main actor for its API. AVCaptureSession.startRunning()/stopRunning() block, so they run on a
// private serial queue; the session object is handed to the bubble window's preview layer.
//
// Frames are watched, not assumed: a video data output counts them. start() returns only once a
// frame has arrived (else it throws, so the app never shows a "live" bubble that stays black),
// and while running a watchdog restarts a session that stops delivering (interrupted, runtime
// error, camera taken by another app, wake from sleep); if that fails it reports the camera gone.
// Every step goes to ~/Library/Logs/Bubble/bubble.log (CaptureLog), with a "camera" prefix.

@preconcurrency import AVFoundation
import Foundation

@MainActor
public final class LiveCameraFeed: CameraFeed {
    public let session = AVCaptureSession()
    /// The app wants the camera on (between a successful start() and stop()).
    public private(set) var isRunning = false
    public var onDisconnected: (@MainActor () -> Void)?
    /// Frames are flowing (true) or stopped (false) while the camera is on. Not in the CameraFeed
    /// contract yet: the app can show "Camera unavailable" in the bubble with it.
    public var onLiveChange: (@MainActor (Bool) -> Void)?
    public private(set) var isLive = false

    /// uniqueID of the camera in use.
    public private(set) var cameraID: String?

    /// How long start() waits for the first frame.
    public var firstFrameTimeout: Duration = .seconds(3)

    private let sessionQueue = DispatchQueue(label: "local.bubble.Bubble.camera")
    private let frameQueue = DispatchQueue(label: "local.bubble.Bubble.camera.frames")
    private let frames = FrameCounter()
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    /// Bumped by stop(): a start() still in flight sees it and backs out.
    private var generation = 0
    private var watchdog: Timer?
    private var restartAttempts = 0
    private var lastRestart = Date.distantPast
    private var interrupted = false
    private var interruptedSince: Date?
    private var deviceToken: NSObjectProtocol?
    private var sessionTokens: [NSObjectProtocol] = []
    private let lastCameraKey = "BubbleLastCameraID"

    public enum CameraError: Error, Sendable, Equatable {
        case notAuthorized
        case noCamera
        case cannotUse(String)
        case noFrames
    }

    public init() {
        session.sessionPreset = .hd1280x720
        output.alwaysDiscardsLateVideoFrames = true
        // The output only counts frames. NEVER ask it for a smaller size: a scaled data output makes
        // the session feed the preview layer from that small stream (measured: a 160x90 output
        // dropped the bubble's sharpness from 8.4 to 1.5, the user's blurry bubble). The camera's own
        // pixel format, unscaled, costs no conversion (the buffers are shared IOSurfaces).
        if let native = output.availableVideoPixelFormatTypes.first {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: native]
        }
        output.setSampleBufferDelegate(frames, queue: frameQueue)
        observeSession()
    }

    // MARK: Start / stop

    /// nil = the last used camera, else the system default.
    public func start(cameraID: String?) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            CaptureLog.info("camera start refused: access \(status.rawValue)")
            throw CameraError.notAuthorized
        }
        let wanted = cameraID ?? UserDefaults.standard.string(forKey: lastCameraKey)
        guard let device = wanted.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video) else {
            CaptureLog.info("camera start: no camera (asked \(cameraID ?? "default"), last \(wanted ?? "none"))")
            throw CameraError.noCamera
        }
        CaptureLog.info("camera start: \(device.localizedName) (\(device.uniqueID)), asked \(cameraID ?? "default"); session running \(session.isRunning), on \(isRunning), live \(isLive), connected \(device.isConnected), in use by another app \(device.isInUseByAnotherApplication), suspended \(device.isSuspended)")
        if isRunning, device.uniqueID == self.cameraID, session.isRunning, isLive {
            CaptureLog.info("camera start: already live, nothing to do")
            return
        }

        try await configure(for: device)
        generation += 1
        let myGeneration = generation
        frames.reset()
        isRunning = true
        restartAttempts = 0
        await runOnSessionQueue { session in
            if !session.isRunning { session.startRunning() }
        }
        guard generation == myGeneration else {
            CaptureLog.info("camera start: stopped while starting")
            throw CancellationError()
        }
        CaptureLog.info("camera start: session running \(session.isRunning) after startRunning")

        // Wait for a real frame: a running session can still deliver nothing (camera taken,
        // interrupted, a stalled device). Black is never shown as "live".
        let deadline = ContinuousClock.now + firstFrameTimeout
        while frames.count == 0, ContinuousClock.now < deadline, generation == myGeneration {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard generation == myGeneration else { throw CancellationError() }
        guard frames.count > 0 else {
            CaptureLog.info("camera start: no frame after \(firstFrameTimeout) (session running \(session.isRunning), interrupted \(interrupted), in use by another app \(device.isInUseByAnotherApplication)): giving up")
            stopSession()
            throw CameraError.noFrames
        }
        setLive(true)
        startWatchdog()
    }

    public func stop() {
        CaptureLog.info("camera stop (on \(isRunning), session running \(session.isRunning))")
        generation += 1
        isRunning = false
        interrupted = false
        interruptedSince = nil
        stopSession()
    }

    private func stopSession() {
        isRunning = false
        watchdog?.invalidate()
        watchdog = nil
        setLive(false)
        runOnSessionQueue { session in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Session changes run on sessionQueue, like startRunning/stopRunning (and the watchdog's
    /// restarts): one serial queue for every session mutation, so a configuration never races a start.
    /// The main-actor bookkeeping (input, cameraID, defaults, the unplug observer) follows.
    private func configure(for device: AVCaptureDevice) async throws {
        let job = ConfigureJob(session: session, output: output, device: device, current: input)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                job.run()
                done.resume()
            }
        }
        if let error = job.error { throw error }
        input = job.input
        cameraID = device.uniqueID
        UserDefaults.standard.set(device.uniqueID, forKey: lastCameraKey)
        watch(device)
    }

    // MARK: Watchdog and recovery

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFrames() }
        }
    }

    /// Once a second while on: frames stopped for 2 s → not live, restart the session (at most
    /// every 3 s, 3 times); frames back → live again. After 3 failed restarts: camera gone.
    private func checkFrames() {
        guard isRunning else { return }
        let age = frames.secondsSinceLastFrame
        if age < 2 {
            if !isLive {
                CaptureLog.info("camera: frames back")
                restartAttempts = 0
                setLive(true)
            }
            return
        }
        if isLive {
            CaptureLog.info(String(format: "camera: no frame for %.1f s (session running %@, interrupted %@)",
                                   age, "\(session.isRunning)", "\(interrupted)"))
            setLive(false)
        }
        // Camera taken by another app and not given back: after 10 s, same as unplugged (design 7.3).
        if interrupted, let since = interruptedSince, Date().timeIntervalSince(since) > 10 {
            CaptureLog.info("camera: interrupted for over 10 s: camera unavailable")
            stop()
            onDisconnected?()
            return
        }
        guard !interrupted, Date().timeIntervalSince(lastRestart) >= 3 else { return }
        guard restartAttempts < 3 else {
            CaptureLog.info("camera: still no frame after \(restartAttempts) restarts: camera unavailable")
            stop()
            onDisconnected?()
            return
        }
        restartAttempts += 1
        lastRestart = Date()
        CaptureLog.info("camera: restarting the session (attempt \(restartAttempts))")
        runOnSessionQueue { session in
            if session.isRunning { session.stopRunning() }
            session.startRunning()
        }
    }

    /// Seen on the user's Mac: after the first start in a process, each restart of the session
    /// posted AVFoundation -11800 right as the bubble attached its new preview layer, and the
    /// session stayed dead (black bubble). Restart it at once (counts as a watchdog attempt).
    private func recoverFromRuntimeError() {
        guard isRunning, !interrupted else { return }
        guard restartAttempts < 3 else {
            CaptureLog.info("camera: runtime errors keep coming after \(restartAttempts) restarts: camera unavailable")
            stop()
            onDisconnected?()
            return
        }
        restartAttempts += 1
        lastRestart = Date()
        setLive(false)
        CaptureLog.info("camera: restarting the session after the runtime error (attempt \(restartAttempts))")
        runOnSessionQueue { session in
            if session.isRunning { session.stopRunning() }
            session.startRunning()
        }
    }

    private func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        onLiveChange?(live)
    }

    // MARK: Observers

    private func observeSession() {
        let center = NotificationCenter.default
        /// `action` gets the notification's details as text (read before hopping to the main actor).
        func on(_ name: Notification.Name, _ action: @escaping @MainActor (LiveCameraFeed, String) -> Void) {
            sessionTokens.append(center.addObserver(forName: name, object: session, queue: .main) { [weak self] note in
                let details: String
                if let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error {
                    details = Self.describe(error)
                } else {
                    details = Self.describe(note.userInfo)
                }
                MainActor.assumeIsolated { if let self { action(self, details) } }
            })
        }
        on(AVCaptureSession.didStartRunningNotification) { _, _ in CaptureLog.info("camera: session started running") }
        on(AVCaptureSession.didStopRunningNotification) { feed, _ in
            CaptureLog.info("camera: session stopped running (camera on \(feed.isRunning))")
        }
        on(AVCaptureSession.wasInterruptedNotification) { feed, details in
            feed.interrupted = true
            feed.interruptedSince = Date()
            CaptureLog.info("camera: session interrupted \(details)")
        }
        on(AVCaptureSession.interruptionEndedNotification) { feed, _ in
            feed.interrupted = false
            feed.interruptedSince = nil
            feed.restartAttempts = 0
            CaptureLog.info("camera: interruption ended")
        }
        on(AVCaptureSession.runtimeErrorNotification) { feed, details in
            CaptureLog.info("camera: session runtime error \(details) (camera on \(feed.isRunning), session running \(feed.session.isRunning))")
            feed.recoverFromRuntimeError()
        }
    }

    private func watch(_ device: AVCaptureDevice) {
        if let deviceToken { NotificationCenter.default.removeObserver(deviceToken) }
        let id = device.uniqueID
        deviceToken = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.cameraID == id else { return }
                CaptureLog.info("camera: \(device.localizedName) disconnected")
                self.stop()
                self.onDisconnected?()
            }
        }
    }

    // MARK: Helpers

    private func runOnSessionQueue(_ work: @escaping @Sendable (AVCaptureSession) -> Void) {
        let box = SessionBox(session)
        sessionQueue.async { work(box.session) }
    }

    private func runOnSessionQueue(_ work: @escaping @Sendable (AVCaptureSession) -> Void) async {
        let box = SessionBox(session)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                work(box.session)
                done.resume()
            }
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code): \(e.localizedDescription)"
    }

    nonisolated private static func describe(_ info: [AnyHashable: Any]?) -> String {
        guard let info, !info.isEmpty else { return "(no reason given)" }
        return info.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
    }
}

/// AVCaptureSession is documented thread-safe for start/stopRunning; this hands it to sessionQueue.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

/// Counts camera frames (on the frame queue) for the first-frame wait and the watchdog.
/// Lock-protected: written on the frame queue, read on the main actor.
private final class FrameCounter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var last = Date.distantPast

    var count: Int { lock.withLock { frames } }
    var secondsSinceLastFrame: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }

    func reset() { lock.withLock { frames = 0; last = Date() } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let first = lock.withLock { () -> Bool in
            frames += 1
            last = Date()
            return frames == 1
        }
        if first {
            if let format = sampleBuffer.formatDescription {
                let size = CMVideoFormatDescriptionGetDimensions(format)
                CaptureLog.info("camera: first frame \(size.width)x\(size.height)")
            } else {
                CaptureLog.info("camera: first frame")
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.withLock { last = Date() } // a dropped frame still means the camera delivers
    }
}

/// One session configuration, run on sessionQueue. Holds AVFoundation objects across the queue hop;
/// only that queue touches it between creation and the main actor reading the result after.
private final class ConfigureJob: @unchecked Sendable {
    let session: AVCaptureSession
    let output: AVCaptureVideoDataOutput
    let device: AVCaptureDevice
    private(set) var input: AVCaptureDeviceInput?
    private(set) var error: LiveCameraFeed.CameraError?

    init(session: AVCaptureSession, output: AVCaptureVideoDataOutput, device: AVCaptureDevice, current: AVCaptureDeviceInput?) {
        self.session = session; self.output = output; self.device = device; self.input = current
    }

    func run() {
        let current = input
        let sameDevice = current?.device.uniqueID == device.uniqueID && session.inputs.contains { $0 === current }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if !sameDevice {
            if let current { session.removeInput(current) }
            input = nil
            let newInput: AVCaptureDeviceInput
            do { newInput = try AVCaptureDeviceInput(device: device) } catch {
                let e = error as NSError
                CaptureLog.info("camera: cannot open \(device.localizedName): \(e.domain) \(e.code): \(e.localizedDescription)")
                self.error = .cannotUse(error.localizedDescription)
                return
            }
            guard session.canAddInput(newInput) else {
                CaptureLog.info("camera: session refuses \(device.localizedName) as input")
                self.error = .cannotUse("\(device.localizedName) can't be used right now.")
                return
            }
            session.addInput(newInput)
            input = newInput
            CaptureLog.info("camera: input set to \(device.localizedName)")
        }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        if !session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .high }
    }
}
