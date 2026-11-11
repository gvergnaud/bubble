// Owner: QA track. Window mode in the app model (design.md §11.4), on FakeRecorder + FakeWindowPicker:
// what app-ui's SourceTests leaves out: the window gone at start, each hidden reason's toast with
// the app's name, "back" keeps the take paused until Resume, a closed window saves the take with a
// toast (no alert), and a second pick while the picker is up.
import AppKit
import BubbleCore
import BubbleTesting
import BubbleUI
import Testing

@MainActor @Suite struct WindowSourceTests {
    final class Effects: AppEffects {
        var toasts: [Toast] = []
        var alerts: [AppAlert] = []
        func present(_ alert: AppAlert) async -> Int { alerts.append(alert); return 0 }
        func showToast(_ toast: Toast) { toasts.append(toast) }
        func afterStop(_ url: URL, open: Bool) {}
        func reveal(_ url: URL) {}
        func openFolder(_ url: URL) {}
        func playTick() {}
        func showSettings() {}
        func setOpenAtLogin(_ on: Bool) -> Bool { true }
    }

    @MainActor struct Rig {
        let model: AppModel
        let recorder = FakeRecorder()
        let picker: FakeWindowPicker
        let effects = Effects()
        let settings: BubbleUI.Settings

        init(picker: FakeWindowPicker = FakeWindowPicker()) {
            self.picker = picker
            settings = BubbleUI.Settings(defaults: UserDefaults(suiteName: "WindowSourceTests-\(UUID().uuidString)")!)
            settings.countdownEnabled = false
            model = AppModel(recorder: recorder, camera: FakeCameraFeed(), devices: FakeDeviceCatalog(),
                             permissions: FakePermissions.allGranted(), settings: settings, effects: effects,
                             windowPicker: picker)
            model.bubbleWindowID = 4242
        }

        func settle() async { for _ in 0..<20 { await Task.yield() } }

        /// Panel → Window → the picker answers → Start: a window take is running.
        func startWindowTake() async {
            model.openPanel()
            model.selectSource(.window)
            await settle()
            model.startFromPanel()
            await settle()
        }
    }

    @Test func aWindowGoneAtStartSaysSoAndRecordsNothing() async {
        let rig = Rig()
        rig.recorder.goneWindows = [FakeWindowPicker.sampleWindow.id]
        await rig.startWindowTake()
        #expect(rig.effects.alerts == [Messages.windowGone], "\(rig.effects.alerts)")
        #expect(rig.recorder.state == .idle && rig.model.phase != .recording)
        #expect(rig.model.pickedWindow == nil, "the gone window is forgotten: the next take picks again")
    }

    @Test(arguments: [WindowHiddenReason.appHidden, .notOnScreen, .otherDisplay])
    func eachHiddenReasonPausesWithItsOwnToast(_ reason: WindowHiddenReason) async {
        let rig = Rig()
        await rig.startWindowTake()
        #expect(rig.model.phase == .recording)
        rig.recorder.simulateWindowHidden(reason)
        await rig.settle()
        #expect(rig.model.phase == .paused)
        #expect(rig.effects.toasts.last == Messages.windowHidden(reason, appName: "Safari"), "\(rig.effects.toasts)")
        #expect(rig.effects.toasts.last?.text.contains("⌥⇧P") == true, "every hidden toast says how to resume")
        if reason == .appHidden { #expect(rig.effects.toasts.last?.text.contains("Safari") == true, "it names the app") }
        #expect(rig.effects.alerts.isEmpty)
    }

    @Test func theWindowBackKeepsTheTakePausedUntilResume() async {
        let rig = Rig()
        await rig.startWindowTake()
        rig.recorder.simulateWindowHidden(.notOnScreen)
        await rig.settle()
        rig.recorder.simulateWindowShown()
        await rig.settle()
        #expect(rig.effects.toasts.last == Messages.windowBack)
        #expect(rig.model.phase == .paused && rig.recorder.state == .paused, "never resumes on its own")
        rig.model.resume()
        await rig.settle()
        #expect(rig.model.phase == .recording && rig.recorder.state == .recording)
    }

    @Test func aClosedWindowSavesTheTakeWithAToastNotAnAlert() async {
        let rig = Rig()
        await rig.startWindowTake()
        rig.recorder.simulateWindowClosed()
        await rig.settle()
        #expect(rig.model.phase == .idle)
        #expect(rig.effects.toasts.last == Messages.windowClosed)
        #expect(rig.effects.alerts.isEmpty, "\(rig.effects.alerts)")
        #expect(rig.settings.lastRecording == rig.recorder.fileURL, "the file is kept: Show/Edit Last Recording find it")
    }

    @Test func theBubbleFollowsEveryMoveAndTheMenuNamesTheApp() async {
        let rig = Rig()
        await rig.startWindowTake()
        #expect(rig.model.menu.first?.title == "Recording Safari")
        for frame in [CGRect(x: 0, y: 0, width: 900, height: 600), CGRect(x: 640, y: 120, width: 1400, height: 900)] {
            rig.recorder.simulateWindowMoved(to: frame)
            await rig.settle()
            #expect(rig.model.bubble?.frame == frame, "\(String(describing: rig.model.bubble?.frame))")
        }
    }

    @Test func aSecondPickWhileThePickerIsUpDoesNotOpenAnother() async {
        let picker = FakeWindowPicker()
        picker.holds = true
        let rig = Rig(picker: picker)
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        rig.model.selectSource(.window)
        rig.model.changeSource()
        await rig.settle()
        #expect(picker.pickCount == 1, "one picker at a time: \(picker.pickCount)")
        picker.answer(FakeWindowPicker.sampleWindow)
        await rig.settle()
        #expect(rig.model.pickedWindow == FakeWindowPicker.sampleWindow)
    }
}
