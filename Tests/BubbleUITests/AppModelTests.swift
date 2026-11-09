// Owner: QA track. AppModel's state machine with fakes (docs/architecture.md §8.1, design.md §4, §5, §7).
// No AppKit, no hardware: FakeRecorder, FakeCameraFeed, FakeDeviceCatalog, FakePermissions, a recording
// AppEffects, a manual clock for the countdown and an injected `now` for the ⌥⇧C window.
import BubbleCore
import BubbleTesting
import BubbleUI
import CoreGraphics
import Foundation
import Testing

@MainActor
final class RecordedEffects: AppEffects {
    var alerts: [AppAlert] = []
    /// Index returned by present(); per title, else `defaultAnswer`.
    var answers: [String: Int] = [:]
    var defaultAnswer = 0
    var toasts: [Toast] = []
    var afterStops: [(URL, Bool)] = []
    var revealed: [URL] = []
    var openedFolders: [URL] = []
    var ticks = 0
    var settingsShown = 0
    var openAtLoginAccepts = true

    func present(_ alert: AppAlert) async -> Int { alerts.append(alert); return answers[alert.title] ?? defaultAnswer }
    func showToast(_ toast: Toast) { toasts.append(toast) }
    func afterStop(_ url: URL, open: Bool) { afterStops.append((url, open)) }
    func reveal(_ url: URL) { revealed.append(url) }
    func openFolder(_ url: URL) { openedFolders.append(url) }
    var edited: [URL] = []
    func editRecording(_ url: URL) { edited.append(url) }
    func playTick() { ticks += 1 }
    func showSettings() { settingsShown += 1 }
    func setOpenAtLogin(_ on: Bool) -> Bool { openAtLoginAccepts }
}

/// The countdown's sleep: suspended until the test calls `advance()`.
@MainActor
final class ManualClock {
    private var pending: [CheckedContinuation<Void, Error>] = []
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func sleep(_ d: Duration) async throws { try await withCheckedThrowingContinuation { pending.append($0) } }
    var waiting: Int { pending.count }
    /// Ends the current 1 s step of the countdown.
    func advance() { let p = pending; pending = []; p.forEach { $0.resume() } }
}

@MainActor
struct Rig {
    let recorder = FakeRecorder()
    let camera = FakeCameraFeed()
    let devices: FakeDeviceCatalog
    let permissions: FakePermissions
    let effects = RecordedEffects()
    let clock = ManualClock()
    let settings: Settings
    let model: AppModel

    init(displays: [DisplayInfo] = [FakeDeviceCatalog.builtIn], mouseOn: CGDirectDisplayID? = nil,
         permissions: FakePermissions = .allGranted(), countdown: Bool = true, welcomeDone: Bool = true,
         cameras: [DeviceInfo] = [FakeDeviceCatalog.faceTime]) {
        devices = FakeDeviceCatalog(displays: displays, cameras: cameras, mouseDisplayID: mouseOn)
        self.permissions = permissions
        let defaults = UserDefaults(suiteName: "bubble-tests-\(UUID().uuidString)")!
        settings = Settings(defaults: defaults, defaultFolder: URL(fileURLWithPath: "/tmp/bubble-tests", isDirectory: true))
        settings.countdownEnabled = countdown
        settings.welcomeDone = welcomeDone
        let clock = self.clock
        model = AppModel(recorder: recorder, camera: camera, devices: devices, permissions: permissions,
                         settings: settings, effects: effects,
                         sleep: { try await clock.sleep($0) }, now: { clock.now })
        model.bubbleWindowID = 4242
    }

    /// Lets pending tasks run until `cond` holds (fails the test after ~2000 turns).
    func until(_ what: String = "", _ cond: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<2000 { if cond() { return }; await Task.yield() }
        Issue.record("timed out waiting for \(what); phase \(model.phase)", sourceLocation: sourceLocation)
    }

    /// Runs the 3-2-1 to the end.
    func finishCountdown() async {
        for _ in 0..<3 {
            await until("countdown step") { clock.waiting > 0 }
            clock.advance()
        }
    }

    /// Idle → recording through the panel and the countdown.
    func record() async {
        model.statusItemClicked()
        model.startFromPanel()
        await finishCountdown()
        await until("recording") { model.phase == .recording }
    }
}

@MainActor @Suite struct AppModelTests {
    // MARK: Launch and permissions

    @Test func firstLaunchOpensWelcome() {
        let rig = Rig(welcomeDone: false)
        rig.model.launched()
        #expect(rig.model.welcomeOpen)
    }
    @Test func laterLaunchWithScreenGrantedStaysQuiet() {
        let rig = Rig()
        rig.model.launched()
        #expect(!rig.model.welcomeOpen)
    }
    @Test func screenMissingOpensWelcomeAtLaunch() {
        let rig = Rig(permissions: FakePermissions([.screen: .denied, .camera: .granted, .microphone: .granted]))
        rig.model.launched()
        #expect(rig.model.welcomeOpen)
    }
    @Test func startWithoutScreenPermissionOpensWelcomeAndRecordsNothing() async {
        let rig = Rig(permissions: FakePermissions([.screen: .notDetermined]))
        rig.model.hotkey(.startStop)
        await rig.until { rig.model.welcomeOpen }
        #expect(rig.model.phase == .idle)
        #expect(rig.recorder.lastOptions == nil)
    }
    @Test func welcomeStatesFollowPermissions() {
        let rig = Rig(permissions: FakePermissions([.screen: .needsRelaunch, .camera: .granted, .microphone: .denied]))
        let w = rig.model.welcome
        #expect(w.screen == .needsRelaunch && w.camera == .granted && w.microphone == .denied)
        #expect(w.mainButton == .relaunch)
        rig.model.welcomeFinish()
        #expect(rig.permissions.relaunchCount == 1)
    }
    @Test func welcomeDeniedRowOpensSettings() {
        let rig = Rig(permissions: FakePermissions([.screen: .granted, .camera: .denied, .microphone: .granted]))
        rig.model.welcomeAction(.camera)
        #expect(rig.permissions.openedSettings == [.camera])
    }
    @Test func welcomeAskRowRequests() async {
        let rig = Rig(permissions: FakePermissions([.screen: .granted, .camera: .notDetermined, .microphone: .granted]))
        rig.model.welcomeAction(.camera)
        await rig.until { rig.permissions.requested == [.camera] }
        #expect(rig.model.welcome.camera == .granted)
    }

    // MARK: Idle → Ready → Countdown → Recording

    @Test func clickOpensReadyWithBubblePreview() async {
        let rig = Rig()
        rig.model.statusItemClicked()
        #expect(rig.model.phase == .ready)
        #expect(rig.model.bubble != nil)
        #expect(rig.model.bubble?.place.size == .medium && rig.model.bubble?.place.corner == .bottomLeft)
        #expect(rig.model.bubble?.mirrored == true)
        await rig.until("camera started") { rig.camera.isRunning }
        rig.model.closePanel()
        #expect(rig.model.phase == .idle && rig.model.bubble == nil && !rig.camera.isRunning)
    }

    @Test func countdownThenRecording() async throws {
        let rig = Rig()
        rig.model.statusItemClicked()
        rig.model.startFromPanel()
        await rig.until { rig.model.phase == .countdown(3) }
        #expect(rig.model.menuBarLabel == .countdown)
        rig.clock.advance(); await rig.until { rig.model.phase == .countdown(2) }
        rig.clock.advance(); await rig.until { rig.model.phase == .countdown(1) }
        #expect(rig.recorder.lastOptions == nil, "nothing recorded during the countdown")
        rig.clock.advance(); await rig.until { rig.model.phase == .recording }
        #expect(rig.effects.ticks == 3)
        let o = try #require(rig.recorder.lastOptions)
        #expect(o.displayID == FakeDeviceCatalog.builtIn.id)
        #expect(o.bubbleWindowID == 4242)
        #expect(o.microphoneID == FakeDeviceCatalog.builtInMic.id)
        #expect(o.captureComputerSound == false, "computer sound is off by default")
        #expect(o.showClicks == true)
        #expect(o.folder.path == "/tmp/bubble-tests")
    }

    @Test func clickOnCountdownStartsNow() async {
        let rig = Rig()
        rig.model.hotkey(.startStop)
        await rig.until { rig.model.phase == .countdown(3) }
        rig.model.skipCountdown()
        await rig.until { rig.model.phase == .recording }
    }

    @Test func escInCountdownGoesBackToIdle() async {
        let rig = Rig()
        rig.model.hotkey(.startStop)
        await rig.until { rig.model.phase == .countdown(3) }
        rig.model.cancelCountdown()
        #expect(rig.model.phase == .idle)
        #expect(rig.model.bubble == nil)
        #expect(rig.recorder.lastOptions == nil)
    }

    @Test func countdownOffStartsAtOnce() async {
        let rig = Rig(countdown: false)
        rig.model.hotkey(.startStop)
        await rig.until { rig.model.phase == .recording }
        #expect(rig.effects.ticks == 0)
    }

    /// ⌥⇧L from Idle: no panel, the display with the mouse; ⌥⇧L again: stop, clipboard + Finder + player.
    @Test func fastPathTwoKeystrokes() async throws {
        let rig = Rig(displays: [FakeDeviceCatalog.builtIn, FakeDeviceCatalog.studioDisplay], mouseOn: 2)
        rig.model.hotkey(.startStop)
        await rig.finishCountdown()
        await rig.until { rig.model.phase == .recording }
        #expect(rig.recorder.lastOptions?.displayID == 2)
        rig.recorder.elapsed = 7
        rig.model.refreshElapsed()
        #expect(rig.model.menuBarLabel == .recording(time: "00:07", lowDisk: false))
        rig.model.hotkey(.startStop)
        await rig.until { rig.model.phase == .idle }
        #expect(rig.effects.afterStops.count == 1)
        #expect(rig.effects.afterStops.first?.1 == true, "the file opens in the player")
        #expect(rig.settings.lastRecording == rig.recorder.fileURL)
        #expect(rig.model.bubble == nil)
        #expect(rig.model.menu.contains { $0.title == "Show Last Recording in Finder" })
    }

    @Test func panelPicksTheDisplay() async {
        let rig = Rig(displays: [FakeDeviceCatalog.builtIn, FakeDeviceCatalog.studioDisplay], mouseOn: 1)
        rig.model.statusItemClicked()
        #expect(rig.model.panel.displays.count == 2)
        rig.model.selectDisplay(2)
        #expect(rig.model.bubble?.display.id == 2, "the bubble preview moves to the picked display")
        rig.model.startFromPanel()
        await rig.finishCountdown()
        await rig.until { rig.model.phase == .recording }
        #expect(rig.recorder.lastOptions?.displayID == 2)
    }

    @Test func oneDisplayHidesTheDisplayMenu() {
        let rig = Rig()
        rig.model.statusItemClicked()
        #expect(rig.model.panel.displays.isEmpty)
    }

    // MARK: Pause / resume

    @Test func pauseDimsAndResumeCountsDown() async {
        let rig = Rig()
        await rig.record()
        rig.recorder.elapsed = 192
        rig.model.hotkey(.pauseResume)
        #expect(rig.model.phase == .paused)
        #expect(rig.recorder.state == .paused)
        #expect(rig.model.bubble?.dimmed == true)
        #expect(rig.model.menuBarLabel == .paused(time: "03:12"))
        #expect(rig.model.menu.contains { $0.title == "Resume" })
        rig.model.hotkey(.pauseResume)
        await rig.until { rig.model.phase == .resumeCountdown(3) }
        #expect(rig.recorder.state == .paused, "still paused during the resume countdown")
        await rig.finishCountdown()
        await rig.until { rig.model.phase == .recording }
        #expect(rig.recorder.state == .recording)
        #expect(rig.model.bubble?.dimmed == false)
    }

    @Test func escDuringResumeCountdownStaysPaused() async {
        let rig = Rig()
        await rig.record()
        rig.model.pause(); rig.model.resume()
        await rig.until { rig.model.phase == .resumeCountdown(3) }
        rig.model.cancelCountdown()
        #expect(rig.model.phase == .paused && rig.recorder.state == .paused)
    }

    @Test func engineAutoPauseIsFollowed() async {
        let rig = Rig()
        await rig.record()
        rig.recorder.pause()   // screen lock: the engine pauses on its own
        await rig.until { rig.model.phase == .paused }
        #expect(rig.model.bubble?.dimmed == true)
    }

    // MARK: Discard

    @Test func discardTwiceWithin3sSkipsTheAlert() async {
        let rig = Rig()
        await rig.record()
        rig.model.hotkey(.discard)
        #expect(rig.effects.toasts.last?.text == "Press ⌥⇧C again to discard")
        #expect(rig.model.phase == .recording)
        rig.clock.now += 2.5
        rig.model.hotkey(.discard)
        await rig.until { rig.model.phase == .idle }
        #expect(rig.effects.alerts.isEmpty)
        #expect(rig.effects.afterStops.isEmpty, "discard opens nothing")
        #expect(rig.settings.lastRecording == nil)
    }

    @Test func discardPressesTooFarApartDoNothing() async {
        let rig = Rig()
        await rig.record()
        rig.model.hotkey(.discard)
        rig.clock.now += 3.5
        rig.model.hotkey(.discard)
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.model.phase == .recording)
        #expect(rig.effects.toasts.count == 2)
    }

    @Test func discardMenuAsksFirst() async {
        let rig = Rig()
        await rig.record()
        rig.effects.answers["Discard this recording?"] = 1   // Keep Recording
        await rig.model.discardWithConfirmation()
        #expect(rig.model.phase == .recording)
        #expect(rig.effects.alerts.map { $0.title } == ["Discard this recording?"])
        #expect(rig.effects.alerts.first?.buttons == ["Discard", "Keep Recording"])
        rig.effects.answers["Discard this recording?"] = 0
        await rig.model.discardWithConfirmation()
        await rig.until { rig.model.phase == .idle }
        #expect(rig.effects.afterStops.isEmpty)
    }

    // MARK: Camera

    @Test func hideAndShowCameraDuringATake() async {
        let rig = Rig()
        await rig.record()
        #expect(rig.model.menu.contains { $0.title == "Hide Camera" })
        rig.model.perform(.hideCamera)
        #expect(rig.model.bubble?.hidden == true)
        #expect(!rig.camera.isRunning)
        #expect(rig.model.menu.contains { $0.title == "Show Camera" })
        rig.model.perform(.showCamera)
        #expect(rig.model.bubble?.hidden == false)
        await rig.until("camera back") { rig.camera.isRunning }
        #expect(rig.model.phase == .recording)
    }

    @Test func cameraUnpluggedMidTakeHidesTheBubble() async {
        let rig = Rig()
        await rig.record()
        await rig.until("camera running") { rig.camera.isRunning }
        rig.camera.simulateDisconnect()
        #expect(rig.effects.toasts.last?.text == "Camera disconnected")
        #expect(rig.model.bubble?.hidden == true)
        #expect(rig.model.phase == .recording)
    }

    /// Frames stop mid-take (camera taken, interrupted): after a 2 s grace, "Camera unavailable" and
    /// one toast; the take goes on, the bubble stays (same window, still in the video); the first
    /// frame back: the face again, at once.
    @Test func cameraFramesStopAndComeBackMidTake() async {
        let rig = Rig()
        await rig.record()
        await rig.until("camera live") { rig.model.bubble?.cameraLive == true }
        rig.camera.simulateLive(false)
        await rig.until("grace sleep") { rig.clock.waiting > 0 }
        #expect(rig.model.bubble?.cameraUnavailable != true, "nothing during the 2 s grace")
        rig.clock.advance()
        await rig.until("unavailable") { rig.model.bubble?.cameraUnavailable == true }
        #expect(rig.effects.toasts.last?.text == "No video from FaceTime HD Camera")
        #expect(rig.model.bubble?.cameraLive == false)
        #expect(rig.model.bubble?.hidden == false, "the bubble stays on screen")
        #expect(rig.model.phase == .recording)
        rig.camera.simulateLive(true)
        #expect(rig.model.bubble?.cameraUnavailable == false)
        #expect(rig.model.bubble?.cameraLive == true)
        #expect(rig.model.phase == .recording)
    }

    /// A hiccup (frames stop and come back within the grace) shows nothing.
    @Test func cameraHiccupShowsNothing() async {
        let rig = Rig()
        await rig.record()
        await rig.until("camera live") { rig.model.bubble?.cameraLive == true }
        let toasts = rig.effects.toasts.count
        rig.camera.simulateLive(false)
        await rig.until("grace sleep") { rig.clock.waiting > 0 }
        rig.camera.simulateLive(true)
        rig.clock.advance()
        for _ in 0..<50 { await Task.yield() }
        #expect(rig.model.bubble?.cameraUnavailable != true)
        #expect(rig.effects.toasts.count == toasts)
    }

    @Test func hiddenCameraIgnoresLiveChanges() async {
        let rig = Rig()
        await rig.record()
        rig.model.perform(.hideCamera)
        rig.camera.simulateLive(false)
        #expect(rig.model.bubble?.cameraUnavailable != true)
        #expect(rig.model.bubble?.hidden == true)
        rig.model.perform(.showCamera)
        await rig.until("camera back") { rig.model.bubble?.cameraLive == true }
        #expect(rig.model.bubble?.cameraUnavailable == false)
    }

    @Test func cameraStartFailureMidTakeShowsUnavailable() async {
        let rig = Rig()
        rig.camera.startError = FakeError("camera busy")
        await rig.record()
        await rig.until("unavailable") { rig.model.bubble?.cameraUnavailable == true }
        #expect(rig.model.phase == .recording)
        #expect(rig.recorder.lastOptions?.bubbleWindowID == 4242, "the bubble window is still recorded")
    }

    @Test func cameraDeniedRecordsWithoutBubble() async {
        let rig = Rig(permissions: FakePermissions([.screen: .granted, .camera: .denied, .microphone: .granted]))
        rig.model.statusItemClicked()
        #expect(rig.model.bubble == nil)
        #expect(rig.model.panel.cameraAccess == .blocked)
        rig.model.startFromPanel()
        await rig.finishCountdown()
        await rig.until { rig.model.phase == .recording }
        #expect(rig.recorder.lastOptions?.bubbleWindowID == nil)
    }

    @Test func micDeniedRecordsSilent() async {
        let rig = Rig(permissions: FakePermissions([.screen: .granted, .camera: .granted, .microphone: .denied]))
        rig.model.statusItemClicked()
        #expect(rig.model.panel.microphoneAccess == .blocked)
        rig.model.startFromPanel()
        await rig.finishCountdown()
        await rig.until { rig.model.phase == .recording }
        #expect(rig.recorder.lastOptions?.microphoneID == nil)
    }

    @Test func noCameraAtAllMeansNoBubble() {
        let rig = Rig(cameras: [])
        rig.model.statusItemClicked()
        #expect(rig.model.bubble == nil)
        #expect(rig.model.panel.cameras.isEmpty)
    }

    @Test func bubbleSizeAndPlaceAreRememberedPerDisplay() async {
        let rig = Rig(displays: [FakeDeviceCatalog.builtIn, FakeDeviceCatalog.studioDisplay], mouseOn: 1)
        rig.model.statusItemClicked()
        rig.model.setBubbleSize(.large)
        let area = FakeDeviceCatalog.builtIn.frame
        rig.model.bubbleDropped(frame: CGRect(x: area.maxX - 300, y: area.maxY - 300, width: 260, height: 260), area: area)
        #expect(rig.model.bubble?.place.corner == .topRight)
        rig.model.selectDisplay(2)
        #expect(rig.model.bubble?.place == .default, "the other display keeps its own place")
        rig.model.selectDisplay(1)
        #expect(rig.model.bubble?.place.size == .large && rig.model.bubble?.place.corner == .topRight)
    }

    // MARK: Stops on its own, errors

    @Test func displayUnpluggedStopsAndSays() async {
        let rig = Rig()
        await rig.record()
        rig.recorder.simulateStopOnItsOwn(.displayDisconnected)
        await rig.until { rig.model.phase == .idle }
        await rig.until("alert") { !rig.effects.alerts.isEmpty }
        #expect(rig.effects.alerts.first?.title == "Display disconnected, recording saved")
        #expect(rig.effects.afterStops.first?.1 == false, "no player thrown at the user")
        #expect(rig.model.menuBarLabel == .idle(attention: true))
        rig.model.menuOpened()
        #expect(rig.model.menuBarLabel == .idle(attention: false))
    }

    @Test func diskFullStopsAndSays() async {
        let rig = Rig()
        await rig.record()
        rig.recorder.simulateStopOnItsOwn(.diskAlmostFull)
        await rig.until("alert") { !rig.effects.alerts.isEmpty }
        #expect(rig.effects.alerts.first?.title == "Disk almost full, recording stopped and saved")
    }

    @Test func notEnoughSpaceAtStart() async {
        let rig = Rig(countdown: false)
        rig.recorder.startError = .notEnoughDiskSpace(bytesFree: 600_000_000)
        rig.model.hotkey(.startStop)
        await rig.until("alert") { !rig.effects.alerts.isEmpty }
        #expect(rig.model.phase == .idle)
        #expect(rig.effects.alerts.first?.title == "Not enough space")
        #expect(rig.effects.alerts.first?.message.hasPrefix("0.6 GB free on") == true)
    }

    @Test func lowDiskWarnsOnceAndTintsTheTimer() async {
        let rig = Rig()
        await rig.record()
        rig.recorder.onEvent?(.lowDisk(bytesLeft: 1_900_000_000, minutesLeft: 38))
        rig.recorder.onEvent?(.lowDisk(bytesLeft: 1_800_000_000, minutesLeft: 35))
        #expect(rig.effects.toasts.map { $0.text } == ["2 GB left, about 38 min"])
        if case .recording(_, let low) = rig.model.menuBarLabel { #expect(low) } else { Issue.record("not recording") }
    }

    @Test func micSwitchedToast() async {
        let rig = Rig()
        await rig.record()
        rig.recorder.onEvent?(.microphoneSwitched(name: "MacBook Pro Microphone"))
        #expect(rig.effects.toasts.last?.text == "Now using MacBook Pro Microphone")
    }

    // MARK: Quit

    @Test func quitWhileRecordingAsks() async {
        let rig = Rig()
        await rig.record()
        rig.effects.answers["Stop and save the recording?"] = 1
        #expect(await rig.model.shouldQuit(.user) == false)
        #expect(rig.model.phase == .recording)
        rig.effects.answers["Stop and save the recording?"] = 0
        #expect(await rig.model.shouldQuit(.user) == true)
        #expect(rig.model.phase == .idle)
        #expect(rig.effects.afterStops.first?.1 == false)
    }

    @Test func logoutSavesWithoutAsking() async {
        let rig = Rig()
        await rig.record()
        #expect(await rig.model.shouldQuit(.logoutOrShutdown) == true)
        #expect(rig.effects.alerts.isEmpty)
        #expect(rig.settings.lastRecording != nil)
    }

    @Test func quitWhenIdleDoesNotAsk() async {
        let rig = Rig()
        #expect(await rig.model.shouldQuit(.user) == true)
        #expect(rig.effects.alerts.isEmpty)
    }

    // MARK: Menus and timer as data

    @Test func recordingMenu() async {
        let rig = Rig()
        await rig.record()
        let items = rig.model.menu.compactMap { e -> String? in
            if case .item(let t, let s, _, _) = e { return s.map { "\(t) \($0)" } ?? t }; return nil
        }
        #expect(items == ["Stop Recording ⌥⇧L", "Pause ⌥⇧P", "Hide Camera", "Discard… ⌥⇧C"])
    }

    @Test func idleMenu() {
        let rig = Rig()
        #expect(rig.model.menu.compactMap { $0.title } == ["Start Recording", "Show Recorder", "Recordings", "Show Last Recording in Finder",
                                                           "Edit Last Recording", "Open Video…", "Open Recordings Folder", "Settings…", "Quit Bubble"])
        for title in ["Show Last Recording in Finder", "Edit Last Recording"] {
            let item = rig.model.menu.first { $0.title == title }
            if case .item(_, _, _, let enabled) = item { #expect(!enabled, "\(title): no last recording yet") }
        }
    }

    @Test func editLastRecordingOpensTheEditor() async {
        let rig = Rig()
        await rig.record()
        rig.model.hotkey(.startStop)
        await rig.until { rig.model.phase == .idle }
        let item = rig.model.menu.first { $0.title == "Edit Last Recording" }
        if case .item(_, _, _, let enabled) = item { #expect(enabled) } else { Issue.record("no Edit Last Recording item") }
        rig.model.perform(.editLastRecording)
        #expect(rig.effects.edited == [rig.recorder.fileURL])
    }

    @Test(arguments: [(0.0, "00:00"), (7.9, "00:07"), (192, "03:12"), (3599, "59:59"), (3723, "1:02:03"), (36_000, "10:00:00")])
    func timerFormat(t: Double, s: String) {
        #expect(AppModel.format(t) == s)
    }

    @Test func hotkeysDoNothingWhereTheyMeanNothing() {
        let rig = Rig()
        rig.model.hotkey(.pauseResume)
        rig.model.hotkey(.discard)
        #expect(rig.model.phase == .idle)
        #expect(rig.effects.toasts.isEmpty)
    }
}
