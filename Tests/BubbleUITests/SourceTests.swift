// Owner: app/UI track. Record a window or an area (design.md §11): the source in the model
// (panel row, ⌥⇧L, the bubble inside the frame, the overlay's geometry) and the snapshots the
// designer reviews (panel rows, Area overlay, corner brackets, the §11.4 toasts).
import AppKit
import BubbleCore
import BubbleTesting
import BubbleUI
import SwiftUI
import Testing

@MainActor @Suite struct SourceModelTests {
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

        init(picker: FakeWindowPicker = FakeWindowPicker(),
             lookup: (@MainActor (CGWindowID) -> (frame: CGRect, displayID: CGDirectDisplayID)?)? = nil) {
            self.picker = picker
            settings = BubbleUI.Settings(defaults: UserDefaults(suiteName: "SourceTests-\(UUID().uuidString)")!)
            settings.countdownEnabled = false
            model = AppModel(recorder: recorder, camera: FakeCameraFeed(), devices: FakeDeviceCatalog(),
                             permissions: FakePermissions.allGranted(), settings: settings, effects: effects,
                             windowPicker: picker, windowLookup: lookup)
            model.bubbleWindowID = 4242
        }

        func settle() async { for _ in 0..<20 { await Task.yield() } }

        /// ⌥⇧L during the take, then wait for the save to finish.
        func stopTake() async {
            model.hotkey(.startStop)
            for _ in 0..<200 where model.phase != .idle { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    @Test func pickingAWindowFillsTheRowAndPutsTheBubbleInside() async {
        let rig = Rig()
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        #expect(rig.picker.pickCount == 1)
        let row = rig.model.sourceRow
        #expect(row.kind == .window)
        #expect(row.window?.line == "Safari — \(FakeWindowPicker.sampleWindow.title)")
        let frame = FakeWindowPicker.sampleWindow.frame
        #expect(rig.model.bubble?.frame == frame, "the bubble lives inside the window")
        #expect(rig.model.panel.displays.isEmpty, "the Display menu is for Full screen only")
    }

    @Test func cancelingTheFirstPickGoesBack() async {
        let rig = Rig(picker: FakeWindowPicker(nextPick: nil))
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        #expect(rig.settings.source == .fullScreen)
        #expect(rig.model.bubble?.frame == nil)
    }

    @Test func noPickerNoWindowSegment() {
        let rig = Rig(picker: FakeWindowPicker(isAvailable: false))
        #expect(!rig.model.panel.windowSourceAvailable)
        rig.model.selectSource(.window)
        #expect(rig.settings.source == .fullScreen)
    }

    @Test func windowTakeRecordsTheWindow() async {
        let rig = Rig()
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        rig.model.startFromPanel()
        await rig.settle()
        let w = FakeWindowPicker.sampleWindow
        #expect(rig.recorder.lastOptions?.source == .window(w.id))
        #expect(rig.recorder.lastOptions?.displayID == w.displayID)
        #expect(rig.model.menu.first?.title == "Recording Safari")
    }

    @Test func areaFromThePanelThenTheTake() async {
        let rig = Rig()
        rig.model.openPanel()
        rig.model.selectSource(.area)
        let request = try! #require(rig.model.areaOverlay)
        #expect(!request.startsRecording)
        let area = CGRect(x: request.display.frame.minX + 100, y: request.display.frame.minY + 100, width: 1280, height: 720)
        rig.model.areaChosen(area)
        #expect(rig.model.areaOverlay == nil)
        #expect(rig.model.sourceRow.areaLine == "1280 × 720", "one display: the size alone")
        #expect(rig.model.bubble?.frame == area)
        rig.model.startFromPanel()
        await rig.settle()
        #expect(rig.recorder.lastOptions?.source == .area(area))
        #expect(rig.model.bracketsFrame == area)
    }

    @Test func hotkeyWithNoAreaOpensTheOverlayThatStarts() async {
        let rig = Rig()
        rig.settings.source = .area
        rig.model.hotkey(.startStop)
        let request = try! #require(rig.model.areaOverlay)
        #expect(request.startsRecording, "Return starts the take")
        #expect(rig.model.phase == .ready, "never a silent full-screen take")
        let f = request.display.frame
        rig.model.areaChosen(CGRect(x: f.minX, y: f.minY, width: 800, height: 600))
        await rig.settle()
        #expect(rig.recorder.lastOptions?.source == .area(CGRect(x: f.minX, y: f.minY, width: 800, height: 600)))
    }

    @Test func cancelingTheOverlayKeepsThePreviousSource() {
        let rig = Rig()
        rig.model.openPanel()
        rig.model.selectSource(.area)
        rig.model.areaCanceled()
        #expect(rig.settings.source == .fullScreen)
        #expect(rig.model.areaOverlay == nil)
    }

    // Just before the countdown the source is checked again (architect m_859).

    @Test func aWindowThatMovedSinceThePickIsRecordedWhereItIsNow() async {
        let now = CGRect(x: 900, y: 120, width: 1100, height: 760)
        let rig = Rig(lookup: { _ in (now, 2) })
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        rig.model.startFromPanel()
        await rig.settle()
        #expect(rig.recorder.lastOptions?.displayID == 2, "the display it is on now, not at pick time")
        #expect(rig.model.bubble?.frame == now, "the bubble sits in the window's frame now")
    }

    @Test func aGoneWindowFromTheHotkeyOpensThePicker() async {
        var gone = false
        let rig = Rig(lookup: { _ in gone ? nil : (FakeWindowPicker.sampleWindow.frame, FakeWindowPicker.sampleWindow.displayID) })
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        rig.model.closePanel()
        gone = true
        rig.model.hotkey(.startStop)
        await rig.settle()
        #expect(rig.recorder.lastOptions == nil, "no take, never full screen instead")
        #expect(rig.model.phase == .ready, "the panel, on Window")
        #expect(rig.settings.source == .window)
        #expect(rig.picker.pickCount == 2, "with the picker up")
        #expect(rig.effects.alerts.isEmpty)
    }

    @Test func aGoneWindowFromStartSaysSoThenPicks() async {
        var gone = false
        let rig = Rig(lookup: { _ in gone ? nil : (FakeWindowPicker.sampleWindow.frame, FakeWindowPicker.sampleWindow.displayID) })
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        gone = true
        rig.model.startFromPanel()
        await rig.settle()
        #expect(rig.recorder.lastOptions == nil)
        #expect(rig.effects.alerts.last == Messages.windowGone)
        #expect(rig.picker.pickCount == 2)
    }

    @Test func anAreaOffItsDisplayOpensTheOverlay() async {
        let rig = Rig()
        rig.model.openPanel()
        rig.model.selectSource(.area)
        let f = rig.model.areaOverlay!.display.frame
        // Saved on a bigger screen (or before a resolution change): it no longer fits.
        rig.model.areaChosen(CGRect(x: f.maxX - 200, y: f.minY, width: 800, height: 600))
        rig.model.closePanel()
        rig.model.hotkey(.startStop)
        await rig.settle()
        #expect(rig.recorder.lastOptions == nil)
        #expect(rig.model.areaOverlay?.startsRecording == true)
    }

    // §11.6: every start says what it records; Window… / Area… pick first.

    @Test func recordFullScreenStartsAtOnce() async {
        let rig = Rig()
        rig.settings.source = .area
        rig.model.record(.fullScreen)
        await rig.settle()
        #expect(rig.recorder.lastOptions?.source == .display)
        #expect(rig.settings.source == .fullScreen, "it becomes the last-used source")
    }

    @Test func recordWindowPicksFirstThenStarts() async {
        let rig = Rig()
        rig.model.record(.window)
        await rig.settle()
        #expect(rig.picker.pickCount == 1)
        #expect(rig.recorder.lastOptions?.source == .window(FakeWindowPicker.sampleWindow.id))
        #expect(rig.model.recordTitle == "Record Safari")
        await rig.stopTake()
        // Last-used and still there: the main part records it again without the picker.
        rig.model.record(nil)
        await rig.settle()
        #expect(rig.picker.pickCount == 1)
    }

    @Test func recordAreaOpensTheOverlayThatStarts() {
        let rig = Rig()
        rig.model.record(.area)
        #expect(rig.model.areaOverlay?.startsRecording == true)
        #expect(rig.recorder.lastOptions == nil)
    }

    @Test func menusOfferTheThreeWaysWithTheShortcutOnTheLastOne() {
        let rig = Rig()
        rig.settings.source = .area
        let items = rig.model.menu.prefix(3).map { entry -> (String?, String?) in
            if case .item(let t, let s, _, _) = entry { return (t, s) }
            return (nil, nil)
        }
        #expect(items.map(\.0) == ["Record Full Screen", "Record Window…", "Record Area…"])
        #expect(items.map(\.1) == [nil, nil, HotkeyAction.startStop.shortcut])
    }

    @Test func theEllipsisMeansThePickerComesFirst() async {
        let rig = Rig()
        rig.model.record(.window) // pick Safari, take, stop
        await rig.settle()
        await rig.stopTake()
        let titles = rig.model.menu.prefix(4).compactMap { entry -> String? in
            if case .item(let t, let s, _, _) = entry { return s.map { "\(t) \($0)" } ?? t }
            return nil
        }
        let key = HotkeyAction.startStop.shortcut
        #expect(titles == ["Record Full Screen", "Record Safari \(key)", "Record Window…", "Record Area…"])
        // Record Window… always opens the picker, even with Safari still open.
        rig.model.perform(.recordWindow)
        await rig.settle()
        #expect(rig.picker.pickCount == 2)
    }

    @Test func countdownSaysWhatItRecords() async {
        let rig = Rig()
        rig.settings.countdownEnabled = true
        rig.model.record(.fullScreen)
        await rig.settle()
        #expect(rig.model.countdownSourceLine == "Full screen")
        rig.model.cancelCountdown()
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        rig.model.startFromPanel()
        await rig.settle()
        #expect(rig.model.countdownSourceLine == "Safari — \(FakeWindowPicker.sampleWindow.title)")
        #expect(rig.model.countdownWindowFrame == FakeWindowPicker.sampleWindow.frame)
        // Let the canceled countdown (real 1 s sleeps) unwind before the model goes away: freeing
        // the model right after a cancel segfaulted the test process at teardown (bisected to the
        // dealloc). Under AddressSanitizer the same run passes and names nothing (architect m_926:
        // timeboxed look, keep the wait). The app's model lives as long as the app.
        rig.model.cancelCountdown()
        try? await Task.sleep(for: .milliseconds(1200))
        withExtendedLifetime(rig) {}
    }

    @Test func bubbleStepsDownOrLeavesInSmallFrames() {
        let big = CGRect(x: 0, y: 0, width: 1280, height: 800)
        #expect(AppModel.bubbleSize(fitting: big, preferred: .large) == .large)
        #expect(AppModel.bubbleSize(fitting: CGRect(x: 0, y: 0, width: 800, height: 400), preferred: .large) == .medium)
        #expect(AppModel.bubbleSize(fitting: CGRect(x: 0, y: 0, width: 800, height: 300), preferred: .large) == .small)
        #expect(AppModel.bubbleSize(fitting: CGRect(x: 0, y: 0, width: 800, height: 239), preferred: .small) == nil)
    }

    @Test func tooSmallAreaRecordsWithoutTheCamera() {
        let rig = Rig()
        rig.model.openPanel()
        rig.model.selectSource(.area)
        let f = rig.model.areaOverlay!.display.frame
        rig.model.areaChosen(CGRect(x: f.minX, y: f.minY, width: 400, height: 230))
        #expect(rig.model.sourceRow.tooSmallLine == "This area is too small for your bubble: recording without the camera.")
        #expect(rig.model.bubble?.hidden == true)
    }

    @Test func windowEventsMidTake() async {
        let rig = Rig()
        rig.model.openPanel()
        rig.model.selectSource(.window)
        await rig.settle()
        rig.model.startFromPanel()
        await rig.settle()
        let moved = CGRect(x: 400, y: 300, width: 1000, height: 700)
        rig.recorder.simulateWindowMoved(to: moved)
        #expect(rig.model.bubble?.frame == moved, "the bubble follows the window")
        rig.recorder.simulateWindowHidden()
        await rig.settle()
        #expect(rig.model.phase == .paused)
        #expect(rig.effects.toasts.last?.text.hasPrefix("Paused:") == true)
        rig.recorder.simulateWindowClosed()
        await rig.settle()
        #expect(rig.model.phase == .idle)
        #expect(rig.effects.toasts.last == Messages.windowClosed)
    }

    @Test func overlayGeometry() {
        let bounds = CGSize(width: 1512, height: 982)
        let r = AreaGeometry.drawn(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 100, y: 100), bounds: bounds)
        #expect(r == CGRect(x: 100, y: 100, width: 400, height: 300))
        let snapped = AreaGeometry.drawn(from: .zero, to: CGPoint(x: 1270, y: 10), bounds: bounds, snap169: true)
        #expect(snapped.size == CGSize(width: 1280, height: 720))
        let moved = AreaGeometry.moved(r, by: CGSize(width: 5000, height: 0), bounds: bounds)
        #expect(moved.maxX == bounds.width, "never leaves the display")
        let resized = AreaGeometry.resized(r, handle: .bottomRight, to: CGPoint(x: 700, y: 600), bounds: bounds)
        #expect(resized == CGRect(x: 100, y: 100, width: 600, height: 500))
        #expect(AreaOverlayState(displaySize: bounds, rect: CGRect(x: 0, y: 0, width: 300, height: 240)).tooSmall)
    }
}

// MARK: - Snapshots for the designer (design.md §11)

@MainActor @Suite struct SourceSnapshots {
    static let panelBase = Catalog.panel()

    static func panel(_ source: SourceRowState) -> RecorderPanelState {
        var s = panelBase
        s.source = source
        return s
    }

    static let window = SourceRowState.PickedWindow(appName: "Safari", title: "Pull request #42 · gvergnaud/bubble",
                                                    appPath: "/Applications/Safari.app")

    @Test func panelSources() {
        Snap.render("panel-source-full-screen", backdrop: .none) {
            RecorderPanelView(state: Self.panel(SourceRowState(kind: .fullScreen))).background(.regularMaterial)
        }
        Snap.render("panel-source-window", backdrop: .none) {
            RecorderPanelView(state: Self.panel(SourceRowState(kind: .window, window: Self.window))).background(.regularMaterial)
        }
        Snap.render("panel-source-area", backdrop: .none) {
            RecorderPanelView(state: Self.panel(SourceRowState(kind: .area, areaSize: CGSize(width: 1280, height: 720),
                                                               areaDisplay: "Built-in Retina Display"))).background(.regularMaterial)
        }
        Snap.render("panel-source-window-too-small", backdrop: .none) {
            RecorderPanelView(state: Self.panel(SourceRowState(kind: .window, window: Self.window, tooSmallForBubble: true)))
                .background(.regularMaterial)
        }
    }

    static let display = CGSize(width: 1512, height: 982)

    @Test func areaOverlay() {
        Snap.render("area-overlay-empty", size: Self.display, backdrop: .desktop) {
            AreaOverlayView(state: AreaOverlayState(displaySize: Self.display))
        }
        Snap.render("area-overlay-drawing", size: Self.display, backdrop: .desktop) {
            AreaOverlayView(state: AreaOverlayState(displaySize: Self.display, rect: CGRect(x: 180, y: 140, width: 1024, height: 576)))
        }
        Snap.render("area-overlay-too-small", size: Self.display, backdrop: .desktop) {
            AreaOverlayView(state: AreaOverlayState(displaySize: Self.display, rect: CGRect(x: 600, y: 360, width: 280, height: 190)))
        }
        Snap.render("area-overlay-from-hotkey", size: Self.display, backdrop: .desktop) {
            AreaOverlayView(state: AreaOverlayState(displaySize: Self.display, rect: CGRect(x: 180, y: 300, width: 1280, height: 640),
                                                    startsRecording: true))
        }
    }

    @Test func cornerBrackets() {
        Snap.render("area-brackets", size: CGSize(width: 720, height: 420), backdrop: .desktop) {
            CornerBracketsView(size: CGSize(width: 640, height: 360))
        }
    }

    // §11.6 snapshots.

    @Test func recordingsSplitButton() {
        func state(_ kind: SourceKind, _ title: String) -> RecordingsState {
            var s = RecordingsSnapshots.state()
            s.source = kind
            s.recordTitle = title
            return s
        }
        for (name, kind, title) in [("full-screen", SourceKind.fullScreen, "Record Full Screen"),
                                    ("window", .window, "Record Safari"), ("area", .area, "Record Area")] {
            Snap.render("recordings-record-\(name)", size: CGSize(width: 720, height: 520)) {
                RecordingsView(state: state(kind, title), selection: .constant([]), icon: RecordingsSnapshots.icon)
            }
        }
        // The ▾ menu, as a mock (a real NSMenu doesn't render offscreen).
        Snap.render("recordings-record-menu", backdrop: .none) {
            MenuMock(rows: [
                .init(id: 0, title: "✓ Full Screen", shortcut: nil, enabled: true, label: false),
                .init(id: 1, title: "   Window…", shortcut: nil, enabled: true, label: false),
                .init(id: 2, title: "   Area…", shortcut: nil, enabled: true, label: false),
            ])
        }
    }

    static func rows(_ entries: [MenuEntry]) -> [MenuMock.Row] {
        entries.enumerated().map { i, e in
            switch e {
            case .item(let t, let s, _, let enabled): MenuMock.Row(id: i, title: t, shortcut: s, enabled: enabled, label: false)
            case .label(let t): MenuMock.Row(id: i, title: t, shortcut: nil, enabled: false, label: true)
            case .separator: MenuMock.Row(id: i, title: nil, shortcut: nil, enabled: true, label: false)
            }
        }
    }

    /// The menu bar idle menu and the File menu for: last = full screen, last = Safari (still open),
    /// last = area saved (design.md §11.6: "…" = picker / overlay first, ⌥⇧L on what it does).
    @Test func recordMenusByLastSource() {
        let contexts: [(String, MenuBuilder.RecordContext)] = [
            ("last-full-screen", .init(lastSource: .fullScreen, openWindowApp: "Safari", areaSaved: true)),
            ("last-safari", .init(lastSource: .window, openWindowApp: "Safari", areaSaved: false)),
            ("last-area", .init(lastSource: .area, openWindowApp: nil, areaSaved: true)),
        ]
        for (name, ctx) in contexts {
            Snap.render("menu-idle-record-\(name)", backdrop: .none) {
                MenuMock(rows: Self.rows(MenuBuilder.menu(phase: .idle, cameraAvailable: true, cameraHidden: false,
                                                          hasLastRecording: true, record: ctx)))
            }
            // The File menu as AppDelegate.validateMenuItem fills it in.
            let file: [MenuEntry] = MenuBuilder.recordItems(ctx) + [
                .item(title: "Pause", shortcut: HotkeyAction.pauseResume.shortcut, action: .pause, enabled: false),
                .item(title: "Discard…", shortcut: HotkeyAction.discard.shortcut, action: .discard, enabled: false),
                .separator,
                .item(title: "Open Video…", shortcut: "⌘O", action: .openVideo, enabled: true),
                .item(title: "Open Recent", shortcut: "▸", action: .openVideo, enabled: true),
                .separator,
                .item(title: "Play", shortcut: "⌘↓", action: .openFolder, enabled: false),
                .item(title: "Edit", shortcut: "⌘E", action: .openFolder, enabled: false),
                .item(title: "Show in Finder", shortcut: "⇧⌘R", action: .openFolder, enabled: false),
                .item(title: "Move to Trash", shortcut: "⌘⌫", action: .openFolder, enabled: false),
                .separator,
                .item(title: "Open Recordings Folder", shortcut: nil, action: .openFolder, enabled: true),
                .item(title: "Close Window", shortcut: "⌘W", action: .openFolder, enabled: true),
            ]
            Snap.render("main-menu-file-\(name)", backdrop: .none) { MenuMock(rows: Self.rows(file)) }
        }
    }

    @Test func countdownWithItsSource() {
        for (name, line) in [("full-screen", "Full screen"), ("full-screen-2-displays", "Full screen · Studio Display"),
                             ("window", "Safari — Pull request #42 · gvergnaud/bubble"), ("area", "Area · 1280 × 720")] {
            Snap.render("countdown-source-\(name)", backdrop: .desktop) { CountdownView(digit: 3, source: line) }
        }
        Snap.render("countdown-window-outline", size: CGSize(width: 760, height: 480), backdrop: .desktop) {
            ZStack {
                WindowOutlineView(size: CGSize(width: 646, height: 406))
                CountdownView(digit: 2, source: "Safari — Pull request #42 · gvergnaud/bubble").scaleEffect(0.8)
            }
        }
        Snap.render("countdown-area-brackets", size: CGSize(width: 760, height: 480), backdrop: .desktop) {
            ZStack {
                CornerBracketsView(size: CGSize(width: 648, height: 368))
                CountdownView(digit: 1, source: "Area · 640 × 360").scaleEffect(0.8)
            }
        }
    }

    @Test func windowToasts() {
        let toasts: [(String, Toast)] = [
            ("toast-window-not-on-screen", Messages.windowHidden(.notOnScreen, appName: "Safari")),
            ("toast-window-app-hidden", Messages.windowHidden(.appHidden, appName: "Safari")),
            ("toast-window-other-display", Messages.windowHidden(.otherDisplay, appName: "Safari")),
            ("toast-window-back", Messages.windowBack),
            ("toast-window-closed", Messages.windowClosed),
        ]
        for (name, toast) in toasts {
            Snap.render(name, backdrop: .desktop) { ToastView(toast: toast) }
        }
    }
}
