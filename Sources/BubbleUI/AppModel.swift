// Owner: app/UI track. The app's state machine (design.md §4, v1 scope note) and every user intent.
// No AppKit here: windows read this state (AppController), one-shot side effects go through
// AppEffects, time through an injected sleep and clock. So AppModelTests drive it with fakes.
import BubbleCore
import CoreGraphics
import Foundation
import Observation

// MARK: - State

public enum Phase: Sendable, Equatable {
    case idle
    /// Recorder panel open, bubble preview on screen.
    case ready
    /// 3-2-1 before a take. Nothing is recorded yet.
    case countdown(Int)
    /// Countdown over, waiting for the recorder's first frame.
    case starting
    case recording
    case paused
    /// 3-2-1 before resuming a paused take. The recorder is still paused.
    case resumeCountdown(Int)
    /// Finalizing the file (usually < 1 s).
    case saving

    /// A take exists (a file is being written or paused).
    public var isInTake: Bool {
        switch self {
        case .recording, .paused, .resumeCountdown: true
        default: false
        }
    }

    public var countdownDigit: Int? {
        switch self {
        case .countdown(let n), .resumeCountdown(let n): n
        default: nil
        }
    }
}

public enum HotkeyAction: String, Sendable, CaseIterable {
    case startStop, pauseResume, discard

    /// The fixed v1 shortcuts (design.md §8).
    public var shortcut: String {
        switch self {
        case .startStop: "⌥⇧L"
        case .pauseResume: "⌥⇧P"
        case .discard: "⌥⇧C"
        }
    }

    public var title: String {
        switch self {
        case .startStop: "Start / stop recording"
        case .pauseResume: "Pause / resume"
        case .discard: "Discard"
        }
    }
}

/// Where the bubble is and how it looks. nil in AppModel.bubble = the panel is ordered out.
public struct BubbleState: Sendable, Equatable {
    public var display: DisplayInfo
    public var place: BubblePlace
    /// Camera off during a take (or in Ready): transparent and click-through, still ordered in.
    public var hidden: Bool
    /// Paused: 50% on screen.
    public var dimmed: Bool
    public var mirrored: Bool
    /// Before the camera's first frame: dark circle + spinner.
    public var cameraLive: Bool
    /// The camera is on but its frames stopped: "Camera unavailable" in the bubble until they come back.
    public var cameraUnavailable: Bool = false
}

public enum Access: Sendable, Equatable {
    case granted
    /// Not asked yet: the menu offers to ask.
    case notAsked
    case blocked
}

/// What the Recorder panel shows. Plain values (snapshot-friendly).
public struct RecorderPanelState: Sendable, Equatable {
    public var cameras: [DeviceInfo]
    /// nil = No Camera.
    public var selectedCameraID: String?
    public var cameraAccess: Access
    public var microphones: [DeviceInfo]
    /// nil = No Microphone.
    public var selectedMicrophoneID: String?
    public var microphoneAccess: Access
    public var computerSound: Bool
    /// Empty with a single display: the Display menu is hidden.
    public var displays: [DisplayInfo]
    public var selectedDisplayID: CGDirectDisplayID?
    public var shortcut: String

    public init(cameras: [DeviceInfo], selectedCameraID: String?, cameraAccess: Access,
                microphones: [DeviceInfo], selectedMicrophoneID: String?, microphoneAccess: Access,
                computerSound: Bool, displays: [DisplayInfo], selectedDisplayID: CGDirectDisplayID?,
                shortcut: String = HotkeyAction.startStop.shortcut) {
        self.cameras = cameras; self.selectedCameraID = selectedCameraID; self.cameraAccess = cameraAccess
        self.microphones = microphones; self.selectedMicrophoneID = selectedMicrophoneID
        self.microphoneAccess = microphoneAccess; self.computerSound = computerSound
        self.displays = displays; self.selectedDisplayID = selectedDisplayID; self.shortcut = shortcut
    }
}

/// The menu bar item's look (design.md §4, §6.1).
public enum MenuBarLabel: Sendable, Equatable {
    case idle(attention: Bool)
    case countdown
    case recording(time: String, lowDisk: Bool)
    case paused(time: String)
    case saving
}

/// A modal question or message. `buttons[0]` is the default (Return).
public struct AppAlert: Sendable, Equatable {
    public enum Style: Sendable { case informational, warning, critical }
    public var title: String
    public var message: String
    public var buttons: [String]
    public var style: Style
    public init(title: String, message: String, buttons: [String], style: Style = .warning) {
        self.title = title; self.message = message; self.buttons = buttons; self.style = style
    }
}

/// A short message near the top-right corner, never recorded, gone after a few seconds.
public struct Toast: Sendable, Equatable {
    public enum Icon: String, Sendable { case info, mic, camera, disk, discard, speaker }
    public var icon: Icon
    public var text: String
    public init(_ icon: Icon, _ text: String) { self.icon = icon; self.text = text }
}

// MARK: - Effects

/// One-shot side effects. The live version is AppKit (SystemEffects); tests record them.
@MainActor
public protocol AppEffects: AnyObject {
    /// Shows `alert` and returns the index of the button pressed.
    func present(_ alert: AppAlert) async -> Int
    func showToast(_ toast: Toast)
    /// After a take: file URL on the clipboard, Finder on the file, then (if `open`) the default player in front.
    func afterStop(_ url: URL, open: Bool)
    func reveal(_ url: URL)
    func openFolder(_ url: URL)
    func playTick()
    func showSettings()
    /// Returns whether the change took (SMAppService can refuse).
    func setOpenAtLogin(_ on: Bool) -> Bool
    /// The Recordings window, in front (design.md §10).
    func showRecordings()
    /// Opens the editor on `url` in the user's browser (docs/editor-architecture.md §2, design.md §10).
    func editRecording(_ url: URL)
}

public extension AppEffects {
    func showRecordings() {}
    func editRecording(_ url: URL) {}
}

// MARK: - Model

@MainActor
@Observable
public final class AppModel {
    // Collaborators
    @ObservationIgnored public let recorder: Recorder
    @ObservationIgnored public let camera: CameraFeed
    @ObservationIgnored public let devices: DeviceCatalog
    @ObservationIgnored public let permissions: PermissionsProviding
    @ObservationIgnored public let effects: AppEffects
    public let settings: Settings
    @ObservationIgnored let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored let now: @MainActor () -> Date

    // State read by the windows
    public private(set) var phase: Phase = .idle
    public private(set) var bubble: BubbleState?
    /// The display the countdown and the take are on.
    public private(set) var recordingDisplay: DisplayInfo?
    /// Seconds of video (refreshed by `refreshElapsed`, 4 Hz from the status item).
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var lowDisk = false
    /// Something stopped on its own: the menu bar icon shows a yellow ! until the menu is opened.
    public private(set) var needsAttention = false
    /// The file of the take in progress (not listed in Recordings until it is saved).
    public private(set) var takeURL: URL?
    /// The Welcome window is open.
    public private(set) var welcomeOpen = false
    /// Shortcuts macOS refused (another app has them).
    public var hotkeysInUse: Set<HotkeyAction> = []
    /// Set by the window layer once the bubble panel exists (it is never recreated).
    @ObservationIgnored public var bubbleWindowID: CGWindowID?
    /// Bumped when devices or permissions change, so the panel re-reads them.
    public private(set) var devicesVersion = 0

    // Private state
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var cameraTask: Task<Void, Never>?
    @ObservationIgnored private var unavailableTask: Task<Void, Never>?
    @ObservationIgnored private var discardArmedAt: Date?
    /// Hide Camera lasts until the end of the take; the next one starts with the camera on.
    private var cameraHidden = false
    private var cameraLive = false
    private var selectedDisplayID: CGDirectDisplayID?

    public static let discardWindow: TimeInterval = 3

    public init(recorder: Recorder, camera: CameraFeed, devices: DeviceCatalog, permissions: PermissionsProviding,
                settings: Settings, effects: AppEffects,
                sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.recorder = recorder; self.camera = camera; self.devices = devices; self.permissions = permissions
        self.settings = settings; self.effects = effects; self.sleep = sleep; self.now = now
        recorder.onEvent = { [weak self] in self?.handle($0) }
        camera.onDisconnected = { [weak self] in self?.cameraDisconnected() }
        camera.onLiveChange = { [weak self] live in self?.cameraLiveChanged(live) }
        devices.onChange = { [weak self] in self?.devicesChanged() }
    }

    // MARK: Launch

    /// First launch, or Screen Recording missing: the Welcome window (design.md §5.1).
    public func launched() {
        if !settings.welcomeDone || permissions.status(.screen) != .granted {
            welcomeOpen = true
        }
    }

    // MARK: Menu bar item

    public var menuBarLabel: MenuBarLabel {
        switch phase {
        case .idle, .ready: .idle(attention: needsAttention)
        case .countdown, .starting: .countdown
        case .recording: .recording(time: Self.format(elapsed), lowDisk: lowDisk)
        case .paused, .resumeCountdown: .paused(time: Self.format(elapsed))
        case .saving: .saving
        }
    }

    /// The menu bar item was clicked (left click). Idle: open the panel. In a take: the caller shows the menu.
    public func statusItemClicked() {
        needsAttention = false
        switch phase {
        case .idle: openPanel()
        case .ready: closePanel()
        default: break
        }
    }

    /// The right-click / take menu was opened.
    public func menuOpened() { needsAttention = false }

    public var menu: [MenuEntry] {
        MenuBuilder.menu(phase: phase, cameraAvailable: bubble != nil, cameraHidden: cameraHidden,
                         hasLastRecording: settings.lastRecording != nil)
    }

    public func perform(_ action: MenuAction) {
        switch action {
        case .stop: stop()
        case .pause: pause()
        case .resume: resume()
        case .hideCamera: setCameraHidden(true)
        case .showCamera: setCameraHidden(false)
        case .discard: Task { await discardWithConfirmation() }
        case .startNow: skipCountdown()
        case .startRecording: hotkey(.startStop)
        case .showRecorder: openPanel()
        case .cancelCountdown: cancelCountdown()
        case .showLastRecording: if let url = settings.lastRecording { effects.reveal(url) }
        case .editLastRecording: if let url = settings.lastRecording { effects.editRecording(url) }
        case .openFolder: effects.openFolder(settings.folder)
        case .settings: effects.showSettings()
        case .recordings: effects.showRecordings()
        case .quit: break // AppKit handles it (terminate → shouldTerminate)
        }
    }

    public static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    public func refreshElapsed() {
        if elapsed != recorder.elapsed { elapsed = recorder.elapsed }
    }

    // MARK: Ready (panel)

    public func openPanel() {
        guard phase == .idle else { return }
        selectedDisplayID = devices.displayWithMouse()?.id ?? devices.displays().first?.id
        phase = .ready
        showBubbleIfCamera(on: currentDisplay)
    }

    /// Esc or a click away while the panel is open.
    public func closePanel() {
        guard phase == .ready else { return }
        phase = .idle
        endBubble()
    }

    public var panel: RecorderPanelState {
        _ = devicesVersion
        let displays = devices.displays()
        return RecorderPanelState(
            cameras: devices.cameras(), selectedCameraID: resolvedCameraID, cameraAccess: access(.camera),
            microphones: devices.microphones(), selectedMicrophoneID: resolvedMicrophoneID,
            microphoneAccess: access(.microphone), computerSound: settings.computerSound,
            displays: displays.count > 1 ? displays : [], selectedDisplayID: currentDisplay?.id)
    }

    public func selectCamera(_ id: String?) {
        settings.camera = id.map { .device($0) } ?? .none
        cameraLive = false
        if phase == .ready || phase.isInTake { restartBubble() }
    }

    public func selectMicrophone(_ id: String?) {
        settings.microphone = id.map { .device($0) } ?? .none
    }

    public func setComputerSound(_ on: Bool) { settings.computerSound = on }

    public func selectDisplay(_ id: CGDirectDisplayID) {
        guard phase == .ready, devices.displays().contains(where: { $0.id == id }) else { return }
        selectedDisplayID = id
        if let display = currentDisplay, bubble != nil {
            bubble?.display = display
            bubble?.place = place(for: display)
        }
    }

    /// The panel's "Allow" item for a permission not asked yet.
    public func requestAccess(_ permission: Permission) {
        Task {
            _ = await permissions.request(permission)
            devicesVersion += 1
            if permission == .camera, phase == .ready { restartBubble() }
        }
    }

    public func openSystemSettings(_ permission: Permission) { permissions.openSystemSettings(permission) }

    // MARK: Start (panel button, Return, ⌥⇧L)

    /// Start Recording in the panel (or Return there).
    public func startFromPanel() {
        guard phase == .ready else { return }
        beginTake()
    }

    public func hotkey(_ action: HotkeyAction) {
        switch action {
        case .startStop:
            switch phase {
            case .idle:
                selectedDisplayID = devices.displayWithMouse()?.id ?? devices.displays().first?.id
                beginTake()
            case .ready: beginTake()
            case .countdown: cancelCountdown()
            case .recording, .paused, .resumeCountdown: stop()
            case .starting, .saving: break
            }
        case .pauseResume:
            switch phase {
            case .recording: pause()
            case .paused: resume()
            case .resumeCountdown: skipCountdown()
            default: break
            }
        case .discard:
            guard phase.isInTake else { return }
            let t = now()
            if let armed = discardArmedAt, t.timeIntervalSince(armed) <= Self.discardWindow {
                discardArmedAt = nil
                Task { await discard() }
            } else {
                discardArmedAt = t
                effects.showToast(Toast(.discard, "Press \(HotkeyAction.discard.shortcut) again to discard"))
            }
        }
    }

    private func beginTake() {
        guard permissions.status(.screen) == .granted else {
            if phase == .ready { phase = .idle; endBubble() }
            welcomeOpen = true
            return
        }
        guard let display = currentDisplay else { return }
        recordingDisplay = display
        // Hide Camera in Ready carries into the take (design.md add-ons); endBubble() resets it after.
        // The bubble must be on screen before start(): capture finds it in the on-screen window list.
        showBubbleIfCamera(on: display)
        if settings.countdownEnabled {
            runCountdown(resume: false) { [weak self] in self?.startRecorder() }
        } else {
            startRecorder()
        }
    }

    private func startRecorder() {
        guard let display = recordingDisplay else { return }
        phase = .starting
        elapsed = 0
        lowDisk = false
        Task {
            // Let the window layer order the bubble in first (it reacts to `bubble` on the next turn).
            await Task.yield()
            guard phase == .starting else { return }
            let options = RecordingOptions(
                displayID: display.id,
                bubbleWindowID: bubble != nil ? bubbleWindowID : nil,
                microphoneID: access(.microphone) == .granted ? resolvedMicrophoneID : nil,
                captureComputerSound: settings.computerSound,
                showClicks: settings.highlightClicks,
                folder: settings.folder)
            do {
                let url = try await recorder.start(options)
                takeURL = url
                if phase == .starting { phase = .recording }
            } catch {
                phase = .idle
                endBubble()
                await reportStartFailure(error)
            }
        }
    }

    private func reportStartFailure(_ error: Error) async {
        switch error as? RecorderError {
        case .screenPermissionMissing:
            welcomeOpen = true
        case .notEnoughDiskSpace(let free):
            _ = await effects.present(Messages.notEnoughSpace(bytesFree: free, folder: settings.folder))
        case .displayNotFound:
            _ = await effects.present(AppAlert(title: "That display is gone",
                                               message: "Bubble could not find the display to record. Try again.",
                                               buttons: ["OK"]))
        case .alreadyRecording:
            break
        case .captureFailed(let why):
            _ = await effects.present(AppAlert(title: "Bubble could not start recording", message: why, buttons: ["OK"]))
        case nil:
            _ = await effects.present(AppAlert(title: "Bubble could not start recording",
                                               message: error.localizedDescription, buttons: ["OK"]))
        }
    }

    // MARK: Countdown

    private func runCountdown(resume: Bool, then done: @escaping @MainActor () -> Void) {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for n in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                self.phase = resume ? .resumeCountdown(n) : .countdown(n)
                self.effects.playTick()
                do { try await self.sleep(.seconds(1)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.countdownTask = nil
            done()
        }
    }

    /// Click on the countdown, or Return: start now.
    public func skipCountdown() {
        switch phase {
        case .countdown:
            countdownTask?.cancel(); countdownTask = nil
            startRecorder()
        case .resumeCountdown:
            countdownTask?.cancel(); countdownTask = nil
            doResume()
        default: break
        }
    }

    /// Esc and Return are taken from every app only while this is true (the countdown is up).
    /// Derived from the phase, so every way out of a countdown (skip, cancel, stop, discard, a start
    /// failure, a stop on its own) turns them off.
    public var countdownKeysActive: Bool { phase.countdownDigit != nil }

    /// Esc: back to Idle (or back to Paused when resuming).
    public func cancelCountdown() {
        switch phase {
        case .countdown:
            countdownTask?.cancel(); countdownTask = nil
            phase = .idle
            endBubble()
        case .resumeCountdown:
            countdownTask?.cancel(); countdownTask = nil
            phase = .paused
            bubble?.dimmed = true
        default: break
        }
    }

    // MARK: Pause / resume

    public func pause() {
        guard phase == .recording else { return }
        recorder.pause()
        phase = .paused
        bubble?.dimmed = true
        refreshElapsed()
    }

    public func resume() {
        guard phase == .paused else { return }
        if settings.countdownEnabled {
            // The bubble is in the video again right after the countdown: undim it now.
            bubble?.dimmed = false
            runCountdown(resume: true) { [weak self] in self?.doResume() }
        } else {
            doResume()
        }
    }

    private func doResume() {
        recorder.resume()
        phase = .recording
        bubble?.dimmed = false
    }

    // MARK: Stop / discard

    public func stop() {
        guard phase.isInTake else { return }
        countdownTask?.cancel(); countdownTask = nil
        phase = .saving
        endBubble()
        Task {
            let result = await recorder.stop()
            finished(result)
        }
    }

    /// The menu's "Discard…": asks first.
    public func discardWithConfirmation() async {
        guard phase.isInTake else { return }
        let answer = await effects.present(Messages.discardConfirm)
        guard answer == 0, phase.isInTake else { return }
        await discard()
    }

    private func discard() async {
        guard phase.isInTake else { return }
        countdownTask?.cancel(); countdownTask = nil
        phase = .saving
        endBubble()
        await recorder.discard()
        phase = .idle
        recordingDisplay = nil
    }

    private func finished(_ result: RecordingResult) {
        phase = .idle
        takeURL = nil
        recordingDisplay = nil
        lowDisk = false
        settings.lastRecording = result.url
        switch result.reason {
        case .user:
            effects.afterStop(result.url, open: true)
        case .discarded:
            break
        case .appQuitting:
            effects.afterStop(result.url, open: false)
        default:
            // It stopped on its own: keep the file handy (clipboard + Finder), don't throw a player
            // at the user, and say why.
            needsAttention = true
            effects.afterStop(result.url, open: false)
            if let alert = Messages.stoppedOnItsOwn(result) {
                Task { _ = await effects.present(alert) }
            }
        }
    }

    // MARK: Quit

    public enum QuitKind: Sendable { case user, logoutOrShutdown }

    /// ⌘Q / Quit while recording asks first (design.md §7.5); logout and shutdown save without asking.
    public func shouldQuit(_ kind: QuitKind) async -> Bool {
        guard phase.isInTake || phase == .starting || phase.countdownDigit != nil else {
            if phase == .saving { await waitUntilSaved() }
            return true
        }
        if phase.countdownDigit != nil && !phase.isInTake { cancelCountdown(); return true }
        while phase == .starting { try? await Task.sleep(for: .milliseconds(50)) }
        if kind == .user {
            let answer = await effects.present(Messages.quitWhileRecording)
            guard answer == 0 else { return false }
        }
        guard phase.isInTake else { return true }
        countdownTask?.cancel(); countdownTask = nil
        phase = .saving
        endBubble()
        let result = await recorder.stop()
        phase = .idle
        settings.lastRecording = result.url
        effects.afterStop(result.url, open: false)
        return true
    }

    private func waitUntilSaved() async {
        while phase == .saving { try? await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: Recorder events

    private func handle(_ event: RecorderEvent) {
        switch event {
        case .stateChanged(let s):
            // The engine pauses on its own on screen lock / sleep (design.md §7.5): follow it.
            if s == .paused, phase == .recording { phase = .paused; bubble?.dimmed = true; refreshElapsed() }
        case .lowDisk(_, let minutes):
            if !lowDisk { effects.showToast(Toast(.disk, "2 GB left, about \(minutes) min")) }
            lowDisk = true
        case .microphoneSwitched(let name):
            effects.showToast(Toast(.mic, "Now using \(name)"))
        case .microphoneLost:
            effects.showToast(Toast(.mic, "Microphone disconnected. Recording goes on without sound."))
        case .computerSoundLost:
            effects.showToast(Toast(.speaker, "Computer sound stopped. Recording goes on with the mic."))
        case .stoppedOnItsOwn(let result):
            // During .saving our own stop()/discard() finishes the take.
            guard phase.isInTake || phase == .starting else { return }
            countdownTask?.cancel(); countdownTask = nil
            endBubble()
            finished(result)
        }
    }

    // MARK: Bubble

    public func setBubbleSize(_ size: BubbleSize) {
        guard var b = bubble else { return }
        b.place = BubblePlacement.resized(b.place, to: size)
        bubble = b
        remember(b.place, for: b.display)
    }

    /// The user dropped the bubble at `frame`; `area` is the recorded display's usable area.
    public func bubbleDropped(frame: CGRect, area: CGRect) {
        guard var b = bubble else { return }
        b.place = BubblePlacement.place(afterDropping: frame, size: b.place.size, in: area)
        bubble = b
        remember(b.place, for: b.display)
    }

    /// Hide Camera / Show Camera (menu) and ⦸ (hover controls).
    public func setCameraHidden(_ hidden: Bool) {
        guard bubble != nil, cameraHidden != hidden else { return }
        cameraHidden = hidden
        bubble?.hidden = hidden
        if hidden {
            cameraTask?.cancel()
            camera.stop()
            cameraLive = false
            bubble?.cameraLive = false
        } else {
            startCamera()
        }
    }

    public var isCameraHidden: Bool { cameraHidden }

    private var currentDisplay: DisplayInfo? {
        let all = devices.displays()
        if let id = selectedDisplayID, let d = all.first(where: { $0.id == id }) { return d }
        return devices.displayWithMouse() ?? all.first
    }

    private func place(for display: DisplayInfo) -> BubblePlace {
        settings.bubblePlaces[BubblePlacement.displayKey(display.id)] ?? .default
    }

    private func remember(_ place: BubblePlace, for display: DisplayInfo) {
        settings.bubblePlaces[BubblePlacement.displayKey(display.id)] = place
    }

    private var wantsCamera: Bool {
        resolvedCameraID != nil && access(.camera) == .granted
    }

    private func showBubbleIfCamera(on display: DisplayInfo?) {
        guard let display, wantsCamera else { bubble = nil; return }
        if bubble == nil {
            bubble = BubbleState(display: display, place: place(for: display), hidden: cameraHidden, dimmed: false,
                                 mirrored: settings.mirrorCamera, cameraLive: cameraLive)
            if !cameraHidden { startCamera() }
        } else {
            bubble?.display = display
            bubble?.place = place(for: display)
            bubble?.mirrored = settings.mirrorCamera
        }
    }

    private func restartBubble() {
        cameraTask?.cancel()
        camera.stop()
        cameraLive = false
        if phase.isInTake || phase == .starting {
            // Never order the panel out during a take: a camera change only restarts the feed.
            if wantsCamera, bubble != nil {
                bubble?.cameraLive = false
                if !cameraHidden { startCamera() }
            } else if bubble != nil {
                cameraHidden = true
                bubble?.hidden = true
            }
        } else {
            bubble = nil
            showBubbleIfCamera(on: currentDisplay)
        }
    }

    private func startCamera() {
        cameraTask?.cancel()
        let id = resolvedCameraID
        bubble?.cameraLive = false
        bubble?.cameraUnavailable = false
        cameraTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.camera.start(cameraID: id)
                guard !Task.isCancelled else { return }
                self.cameraLive = true
                self.bubble?.cameraLive = true
                self.bubble?.cameraUnavailable = false
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.info("camera start failed: \(error)")
                // The camera exists but gives no picture (busy, no frames for 4 s): say so rather
                // than a black circle or a spinner forever.
                self.enterCameraUnavailable()
            }
        }
    }

    /// Outside a take: order the bubble out and stop the camera.
    private func endBubble() {
        cameraTask?.cancel(); cameraTask = nil
        if camera.isRunning || bubble != nil { camera.stop() }
        cameraLive = false
        cameraHidden = false
        bubble = nil
    }

    /// Frames stopped (false) or came back (true) while the camera is on.
    /// Frames stopping enters "unavailable" only after 2 s (no flicker on a hiccup); the first frame
    /// leaves it at once. The user gets the words in a toast (not recorded), once per episode.
    private func cameraLiveChanged(_ live: Bool) {
        guard bubble != nil, !cameraHidden else { return }
        unavailableTask?.cancel(); unavailableTask = nil
        if live {
            cameraLive = true
            bubble?.cameraLive = true
            bubble?.cameraUnavailable = false
            return
        }
        unavailableTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.sleep(.seconds(2)) } catch { return }
            guard !Task.isCancelled, self.bubble != nil, !self.cameraHidden else { return }
            self.enterCameraUnavailable()
        }
    }

    private func enterCameraUnavailable() {
        cameraLive = false
        bubble?.cameraLive = false
        guard bubble?.cameraUnavailable == false else { return }
        bubble?.cameraUnavailable = true
        let name = devices.cameras().first { $0.id == resolvedCameraID }?.name ?? "the camera"
        effects.showToast(Toast(.camera, "No video from \(name)"))
    }

    private func cameraDisconnected() {
        effects.showToast(Toast(.camera, "Camera disconnected"))
        cameraUnavailable()
        devicesVersion += 1
    }

    private func cameraUnavailable() {
        cameraLive = false
        if phase.isInTake || phase == .starting || phase.countdownDigit != nil {
            cameraHidden = true
            bubble?.hidden = true
            bubble?.cameraLive = false
        } else {
            bubble = nil
        }
    }

    private func devicesChanged() {
        devicesVersion += 1
        if phase == .ready {
            if let id = selectedDisplayID, !devices.displays().contains(where: { $0.id == id }) {
                selectedDisplayID = devices.displayWithMouse()?.id
            }
            showBubbleIfCamera(on: currentDisplay)
        }
    }

    // MARK: Devices and access

    private func access(_ p: Permission) -> Access {
        switch permissions.status(p) {
        case .granted, .needsRelaunch: .granted
        case .notDetermined: .notAsked
        case .denied: .blocked
        }
    }

    var resolvedCameraID: String? {
        let cams = devices.cameras()
        switch settings.camera {
        case .none: return nil
        case .device(let id) where cams.contains(where: { $0.id == id }): return id
        default:
            return (cams.first { $0.name.localizedCaseInsensitiveContains("FaceTime") || $0.name.localizedCaseInsensitiveContains("Built-in") }
                ?? cams.first)?.id
        }
    }

    var resolvedMicrophoneID: String? {
        let mics = devices.microphones()
        switch settings.microphone {
        case .none: return nil
        case .device(let id) where mics.contains(where: { $0.id == id }): return id
        default: return mics.first?.id // the catalog lists the system default input first
        }
    }

    // MARK: Welcome

    public var welcome: WelcomeState {
        WelcomeState(screen: permissions.status(.screen), camera: permissions.status(.camera),
                     microphone: permissions.status(.microphone), shortcut: HotkeyAction.startStop.shortcut)
    }

    /// Re-read the permission states (the Welcome window polls; macOS sends no notification).
    public func permissionsMayHaveChanged() { devicesVersion += 1 }

    public func welcomeAction(_ permission: Permission) {
        let s = permissions.status(permission)
        switch (permission, s) {
        case (.screen, .notDetermined):
            Task { _ = await permissions.request(.screen); devicesVersion += 1 }
        case (_, .notDetermined):
            Task { _ = await permissions.request(permission); devicesVersion += 1 }
        case (_, .denied):
            permissions.openSystemSettings(permission)
        default: break
        }
    }

    public func welcomeFinish() {
        switch permissions.status(.screen) {
        case .needsRelaunch, .denied:
            // .denied = the user went to System Settings; macOS may only apply the switch after a
            // relaunch, so relaunch either way. Without the grant the next launch asks again.
            permissions.relaunch()
        case .granted:
            settings.welcomeDone = true
            welcomeOpen = false
            effects.showRecordings()
        default: break
        }
    }

    /// Closed with the red button: it comes back at the next launch until Screen Recording works.
    public func welcomeClosed() { welcomeOpen = false }

    public func showWelcome() { welcomeOpen = true }

    // MARK: Settings

    public func setOpenAtLogin(_ on: Bool) {
        if effects.setOpenAtLogin(on) { settings.openAtLogin = on }
    }

    public func setMirror(_ on: Bool) {
        settings.mirrorCamera = on
        bubble?.mirrored = on
    }
}

// MARK: - Copy (design.md §9 words)

public enum Messages {
    public static let discardConfirm = AppAlert(
        title: "Discard this recording?", message: "It goes to the Trash.",
        buttons: ["Discard", "Keep Recording"], style: .warning)

    public static let quitWhileRecording = AppAlert(
        title: "Stop and save the recording?", message: "Bubble is recording. Quitting stops the recording and saves it.",
        buttons: ["Stop and Save", "Keep Recording"], style: .warning)

    public static func notEnoughSpace(bytesFree: Int64, folder: URL) -> AppAlert {
        let gb = String(format: "%.1f", Double(bytesFree) / 1_000_000_000)
        let volume = (try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "this disk"
        return AppAlert(title: "Not enough space",
                        message: "\(gb) GB free on \(volume). Free some space or pick another folder.",
                        buttons: ["OK"], style: .warning)
    }

    public static func stoppedOnItsOwn(_ result: RecordingResult) -> AppAlert? {
        let file = result.url.lastPathComponent
        let saved = "It was saved as “\(file)” and is on the clipboard."
        switch result.reason {
        case .user, .discarded, .appQuitting: return nil
        case .displayDisconnected:
            return AppAlert(title: "Display disconnected, recording saved", message: saved, buttons: ["OK"], style: .informational)
        case .diskAlmostFull:
            return AppAlert(title: "Disk almost full, recording stopped and saved", message: saved, buttons: ["OK"])
        case .screenPermissionRevoked:
            return AppAlert(title: "Screen Recording was turned off, recording saved",
                            message: saved + " Turn Screen Recording back on in System Settings to record again.",
                            buttons: ["OK"])
        case .failed(let why):
            return AppAlert(title: "Recording stopped, what was recorded is saved",
                            message: saved + "\n\n" + why, buttons: ["OK"], style: .critical)
        }
    }
}
