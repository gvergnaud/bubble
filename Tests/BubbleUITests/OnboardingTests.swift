// Owner: app/UI track. First launch (design.md §5.1): the Screen Recording state and the Welcome
// window's buttons. Regression: a fresh install with no grant showed "Relaunch to finish" and the
// Relaunch button looped (LivePermissions guessed the grant from other apps' window names).
import AppKit
import BubbleCore
import BubbleTesting
import BubbleUI
import Testing

@Suite struct ScreenStatusTests {
    @Test func noGrantIsNotRelaunch() {
        #expect(LivePermissions.screenStatus(preflight: false, grantedAtLaunch: false, requested: false) == .notDetermined)
        #expect(LivePermissions.screenStatus(preflight: false, grantedAtLaunch: false, requested: true) == .denied)
    }

    @Test func grantAfterLaunchNeedsRelaunch() {
        #expect(LivePermissions.screenStatus(preflight: true, grantedAtLaunch: false, requested: true) == .needsRelaunch)
    }

    @Test func grantAtLaunchIsGranted() {
        #expect(LivePermissions.screenStatus(preflight: true, grantedAtLaunch: true, requested: false) == .granted)
    }
}

@MainActor @Suite struct WelcomeFlowTests {
    final class NoEffects: AppEffects {
        var toasts: [Toast] = []
        func present(_ alert: AppAlert) async -> Int { 0 }
        func showToast(_ toast: Toast) { toasts.append(toast) }
        func afterStop(_ url: URL, open: Bool) {}
        func reveal(_ url: URL) {}
        func openFolder(_ url: URL) {}
        func playTick() {}
        func showSettings() {}
        func setOpenAtLogin(_ on: Bool) -> Bool { true }
    }

    func model(_ permissions: FakePermissions) -> AppModel {
        let defaults = UserDefaults(suiteName: "OnboardingTests-\(UUID().uuidString)")!
        return AppModel(recorder: FakeRecorder(), camera: FakeCameraFeed(), devices: FakeDeviceCatalog(),
                        permissions: permissions, settings: Settings(defaults: defaults), effects: NoEffects())
    }

    @Test func freshInstallOffersOpenSettingsNotRelaunch() {
        let state = WelcomeState(screen: .notDetermined, camera: .notDetermined, microphone: .notDetermined)
        #expect(state.mainButton == .waitingForScreen)
    }

    @Test func afterVisitingSettingsRelaunchIsOffered() {
        // macOS may keep saying "no" until the app relaunches, even with the switch on.
        #expect(WelcomeState(screen: .denied, camera: .granted, microphone: .granted).mainButton == .relaunch)
        #expect(WelcomeState(screen: .needsRelaunch, camera: .granted, microphone: .granted).mainButton == .relaunch)
    }

    @Test func screenRowOpensSystemSettings() async {
        let permissions = FakePermissions([.screen: .notDetermined], answers: [.screen: .denied])
        let m = model(permissions)
        m.welcomeAction(.screen)
        await Task.yield(); await Task.yield()
        #expect(permissions.requested == [.screen])
        #expect(m.welcome.mainButton == .relaunch)
        m.welcomeAction(.screen) // denied now: straight to the pane
        #expect(permissions.openedSettings == [.screen])
    }

    @Test func relaunchButtonRelaunchesWhenDeniedOrPending() {
        for status in [PermissionStatus.denied, .needsRelaunch] {
            let permissions = FakePermissions([.screen: status])
            model(permissions).welcomeFinish()
            #expect(permissions.relaunchCount == 1)
        }
    }

    @Test func doneClosesWhenGranted() {
        let m = model(FakePermissions.allGranted())
        m.launched()
        #expect(m.welcomeOpen)
        m.welcomeFinish()
        #expect(!m.welcomeOpen)
    }

    @Test func framesStoppingShowsCameraUnavailable() async {
        let camera = FakeCameraFeed()
        let effects = NoEffects()
        let defaults = UserDefaults(suiteName: "OnboardingTests-\(UUID().uuidString)")!
        // The 2 s grace is the injected sleep: instant here.
        let m = AppModel(recorder: FakeRecorder(), camera: camera, devices: FakeDeviceCatalog(),
                         permissions: FakePermissions.allGranted(), settings: Settings(defaults: defaults), effects: effects,
                         sleep: { _ in await Task.yield() })
        m.openPanel()
        for _ in 0..<5 { await Task.yield() }
        #expect(m.bubble?.cameraLive == true)
        camera.simulateLive(false)
        #expect(m.bubble?.cameraUnavailable == false, "not before the grace period")
        for _ in 0..<5 { await Task.yield() }
        #expect(m.bubble?.cameraUnavailable == true)
        #expect(m.bubble?.cameraLive == false)
        #expect(effects.toasts.map(\.text) == ["No video from FaceTime HD Camera"])
        camera.simulateLive(true)
        #expect(m.bubble?.cameraUnavailable == false)
        #expect(m.bubble?.cameraLive == true)
    }

    @Test func aHiccupShorterThanTheGraceShowsNothing() async {
        let camera = FakeCameraFeed()
        let effects = NoEffects()
        let defaults = UserDefaults(suiteName: "OnboardingTests-\(UUID().uuidString)")!
        let m = AppModel(recorder: FakeRecorder(), camera: camera, devices: FakeDeviceCatalog(),
                         permissions: FakePermissions.allGranted(), settings: Settings(defaults: defaults), effects: effects,
                         sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        m.openPanel()
        for _ in 0..<5 { await Task.yield() }
        camera.simulateLive(false)
        camera.simulateLive(true) // frames back before 2 s
        for _ in 0..<5 { await Task.yield() }
        #expect(m.bubble?.cameraUnavailable == false)
        #expect(effects.toasts.isEmpty)
    }

    @Test func cameraStartFailureShowsUnavailableNotBlack() async {
        let camera = FakeCameraFeed()
        camera.startError = FakeError("no frames")
        let defaults = UserDefaults(suiteName: "OnboardingTests-\(UUID().uuidString)")!
        let m = AppModel(recorder: FakeRecorder(), camera: camera, devices: FakeDeviceCatalog(),
                         permissions: FakePermissions.allGranted(), settings: Settings(defaults: defaults), effects: NoEffects())
        m.openPanel()
        for _ in 0..<5 { await Task.yield() }
        #expect(m.bubble != nil)
        #expect(m.bubble?.cameraUnavailable == true)
    }

    /// The editor hook (design.md §10): "Edit Last Recording" in the idle menu, greyed with no recording.
    @Test func editLastRecordingOpensTheEditor() {
        final class EditEffects: AppEffects {
            var edited: [URL] = []
            func present(_ alert: AppAlert) async -> Int { 0 }
            func showToast(_ toast: Toast) {}
            func afterStop(_ url: URL, open: Bool) {}
            func reveal(_ url: URL) {}
            func openFolder(_ url: URL) {}
            func playTick() {}
            func showSettings() {}
            func setOpenAtLogin(_ on: Bool) -> Bool { true }
            func editRecording(_ url: URL) { edited.append(url) }
        }
        let effects = EditEffects()
        let settings = Settings(defaults: UserDefaults(suiteName: "OnboardingTests-\(UUID().uuidString)")!)
        let m = AppModel(recorder: FakeRecorder(), camera: FakeCameraFeed(), devices: FakeDeviceCatalog(),
                         permissions: FakePermissions.allGranted(), settings: settings, effects: effects)
        func entry() -> MenuEntry? { m.menu.first { $0.title == "Edit Last Recording" } }
        #expect(entry() == .item(title: "Edit Last Recording", shortcut: nil, action: .editLastRecording, enabled: false))
        m.perform(.editLastRecording)
        #expect(effects.edited.isEmpty)

        let last = URL(fileURLWithPath: "/tmp/Bubble 2026-11-06 at 14.22.05.mp4")
        settings.lastRecording = last
        #expect(entry() == .item(title: "Edit Last Recording", shortcut: nil, action: .editLastRecording, enabled: true))
        m.perform(.editLastRecording)
        #expect(effects.edited == [last])
    }

    @Test func mainMenuHasQuitAndClose() {
        let menu = AppDelegate.mainMenu()
        let titles = menu.items.flatMap { $0.submenu?.items.map(\.title) ?? [] }
        #expect(titles.contains("Edit"), "File › Edit ⌘E opens the editor")
        #expect(titles.contains("Quit Bubble"))
        #expect(titles.contains("Close Window"))
        #expect(titles.contains("Recordings"))
        #expect(titles.contains("Settings…"))
    }
}
