// Owner: app/UI track. Wires the model to the windows and the system: status item, bubble,
// countdown, welcome, settings, toasts, hotkeys, quit. main.swift builds an AppModel (live or fake)
// and hands it to AppDelegate.
import AppKit
import BubbleCore
import os
import ServiceManagement

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    public let model: AppModel
    private let effects: SystemEffects
    private let bubbleContent: (_ cameraLive: Bool) -> BubbleContent
    private var statusItem: StatusItemController?
    private var bubble: BubbleWindowController?
    private var countdown: CountdownWindowController?
    private var areaOverlay: AreaOverlayWindowController?
    private var brackets: BracketsWindowController?
    private var welcome: WelcomeWindowController?
    private let hotkeys = Hotkeys()
    private let log = Logger(subsystem: "local.bubble.Bubble", category: "App")
    /// Videos opened before launch finished (Open With, a drop on the Dock icon of a closed Bubble).
    private var pendingOpens: [URL]? = []

    /// `placeholder`: a still image for the bubble instead of the live camera (BUBBLE_FAKE mode).
    public init(model: AppModel, effects: SystemEffects, placeholder: CGImage? = nil) {
        self.model = model
        self.effects = effects
        let session = model.camera.session
        // The camera preview joins the view tree at the first real frame (never while the session is
        // starting) and then stays for the app's lifetime: one preview layer, never re-attached.
        let everLive = Flag()
        bubbleContent = { live in
            if let placeholder { return live ? .image(placeholder) : .waiting }
            if live { everLive.value = true }
            return everLive.value ? .camera(session, live: live) : .waiting
        }
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app still becomes the active app when its Welcome or Settings window is in
        // front; without a main menu the menu bar is then empty and dead (no ⌘Q, no ⌘W).
        NSApp.mainMenu = Self.mainMenu()
        effects.settingsWindow = SettingsWindowController(model: model)
        effects.recordingsWindow = RecordingsWindowController(model: model)
        statusItem = StatusItemController(model: model)
        statusItem?.onQuit = { NSApp.terminate(nil) }
        bubble = BubbleWindowController(model: model, content: bubbleContent)
        countdown = CountdownWindowController(model: model)
        areaOverlay = AreaOverlayWindowController(model: model)
        brackets = BracketsWindowController(model: model)
        trackChanges { [weak self] in
            guard let self else { return }
            self.hotkeys.setCountdownKeys(self.model.countdownKeysActive)
        }
        welcome = WelcomeWindowController(model: model)

        hotkeys.onPress = { [weak self] key in self?.hotkeyPressed(key) }
        model.hotkeysInUse = hotkeys.registerShortcuts()
        let p = model.permissions
        AppLog.info("launch \(Bundle.main.bundlePath) · screen \(p.status(.screen)) camera \(p.status(.camera)) mic \(p.status(.microphone)) · hotkeys in use: \(model.hotkeysInUse.map(\.rawValue))")
        model.launched()
        let opens = pendingOpens ?? []
        pendingOpens = nil
        // Opened by hand (Dock, Finder, Spotlight, open): the Recordings window (design.md §10.1).
        // A login-item launch stays quiet; the first launch shows Welcome, whose Done opens Recordings.
        // Launched to open videos: only the editor tabs.
        if opens.isEmpty, !model.welcomeOpen, !Self.launchedAsLoginItem() {
            effects.showRecordings()
        }
        openVideos(opens)
    }

    /// Finder's Open With, a drop on the Dock icon, the Dock's recent list
    /// (docs/editor-open-video.md §2 D/E): one editor tab per file.
    public func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        AppLog.info("open \(files.count) file(s) from Finder or the Dock\(pendingOpens != nil ? " (queued until launch)" : "")")
        if pendingOpens != nil { pendingOpens?.append(contentsOf: files) } else { openVideos(files) }
    }

    private func openVideos(_ urls: [URL]) {
        for url in urls { effects.editRecording(url) }
    }

    @objc func openVideo(_ sender: Any?) { effects.openVideo() }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        effects.editRecording(url)
    }

    @objc func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }

    /// Clicking the Dock icon or opening Bubble again while it runs: the Recordings window, in
    /// front (also while recording), or Welcome if Screen Recording is still missing.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLog.info("reopen · phase \(model.phase)")
        if model.permissions.status(.screen) != .granted {
            model.showWelcome()
        } else {
            effects.showRecordings()
        }
        return false
    }

    /// Closing the last window keeps Bubble running (Dock icon and menu bar item stay).
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Right-click on the Dock icon.
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let take = model.phase.isInTake
        let record = NSMenuItem(title: take ? "Stop Recording" : "New Recording", action: #selector(newRecording(_:)), keyEquivalent: "")
        record.target = self
        menu.addItem(record)
        let recordings = NSMenuItem(title: "Recordings", action: #selector(showRecordings(_:)), keyEquivalent: "")
        recordings.target = self
        menu.addItem(recordings)
        return menu
    }

    // MARK: Menu actions (File, Window, Dock)

    @objc func newRecording(_ sender: Any?) {
        if let window = effects.recordingsWindow, window.window?.isKeyWindow == true {
            window.newRecording()
        } else {
            model.hotkey(.startStop)
        }
    }
    @objc func pauseResume(_ sender: Any?) { model.hotkey(.pauseResume) }
    @objc func discardTake(_ sender: Any?) { Task { await model.discardWithConfirmation() } }
    @objc func showRecordings(_ sender: Any?) { effects.showRecordings() }
    @objc func openRecordingsFolder(_ sender: Any?) { model.perform(.openFolder) }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let phase = model.phase
        switch item.action {
        case #selector(newRecording(_:)):
            item.title = phase.isInTake ? "Stop Recording" : "New Recording"
            return phase != .saving && phase != .starting
        case #selector(pauseResume(_:)):
            item.title = phase == .paused || phase.countdownDigit != nil && phase.isInTake ? "Resume" : "Pause"
            return phase == .recording || phase == .paused
        case #selector(discardTake(_:)):
            return phase.isInTake
        default:
            return true
        }
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    @objc private func openSettings(_ sender: Any?) { model.perform(.settings) }

    /// The main menu (design.md §10.2). App actions target the app delegate; Open, Show in Finder,
    /// Move to Trash, Copy and Select All go up the responder chain to the Recordings window.
    public static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSApplication.shared.delegate
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                  toApp: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if toApp { i.target = app }
            return i
        }
        submenu("Bubble", [
            item("About Bubble", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(openSettings(_:)), ",", toApp: true),
            .separator(),
            item("Hide Bubble", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Bubble", #selector(NSApplication.terminate(_:)), "q"),
        ])
        // ⌥⇧L/P/C are global hotkeys already; the menu shows them without claiming them again.
        let newRec = item("New Recording", #selector(newRecording(_:)), "", toApp: true)
        let pause = item("Pause", #selector(pauseResume(_:)), "", toApp: true)
        let discard = item("Discard…", #selector(discardTake(_:)), "", toApp: true)
        // The global hotkey gets the keystroke first, so these only display the shortcut.
        StatusItemController.applyShortcut(HotkeyAction.startStop.shortcut, to: newRec)
        StatusItemController.applyShortcut(HotkeyAction.pauseResume.shortcut, to: pause)
        StatusItemController.applyShortcut(HotkeyAction.discard.shortcut, to: discard)
        // ⌘O opens any video in the editor; Open Recent lists the videos opened there
        // (docs/editor-open-video.md §2 C/E). A recording plays with Play ⌘↓.
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = RecentVideosMenu.shared
        recent.submenu = recentMenu
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        submenu("File", [
            newRec, pause, discard,
            .separator(),
            item("Open Video…", #selector(openVideo(_:)), "o", toApp: true),
            recent,
            .separator(),
            item("Play", #selector(RecordingsWindowController.openSelected(_:)), down),
            item("Edit", #selector(RecordingsWindowController.editSelected(_:)), "e"),
            item("Show in Finder", #selector(RecordingsWindowController.revealSelected(_:)), "r", [.command, .shift]),
            item("Move to Trash", #selector(RecordingsWindowController.trashSelected(_:)), "\u{8}"),
            .separator(),
            item("Open Recordings Folder", #selector(openRecordingsFolder(_:)), "", toApp: true),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Recordings", #selector(showRecordings(_:)), "0", toApp: true),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        NSApplication.shared.windowsMenu = window
        return main
    }

    private func hotkeyPressed(_ key: Hotkeys.Key) {
        switch key {
        case .startStop: model.hotkey(.startStop)
        case .pauseResume: model.hotkey(.pauseResume)
        case .discard: model.hotkey(.discard)
        case .escape: model.cancelCountdown()
        case .returnKey, .keypadEnter: model.skipCountdown()
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let phase = model.phase
        guard phase.isInTake || phase == .starting || phase == .saving || phase.countdownDigit != nil else {
            return .terminateNow
        }
        let kind: AppModel.QuitKind = Self.isLogoutOrShutdown() ? .logoutOrShutdown : .user
        Task {
            let ok = await model.shouldQuit(kind)
            sender.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) { effects.stopEditor?() }

    /// Log out, restart and shut down send a quit Apple event with a reason (kAEQuitReason).
    private static func isLogoutOrShutdown() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [AEEventID(kAELogOut), AEEventID(kAEReallyLogOut), AEEventID(kAEShowRestartDialog), AEEventID(kAERestart),
                AEEventID(kAEShowShutdownDialog), AEEventID(kAEShutDown)].contains(reason)
    }
}

@MainActor
private final class Flag { var value = false }

/// File › Open Recent: the videos opened in the editor (NSDocumentController keeps the list, which
/// also fills the Dock icon's right-click list). Filled each time the menu opens.
@MainActor
final class RecentVideosMenu: NSObject, NSMenuDelegate {
    static let shared = RecentVideosMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let delegate = NSApplication.shared.delegate
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
            item.target = delegate
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: urls.isEmpty ? nil : #selector(AppDelegate.clearRecent(_:)), keyEquivalent: "")
        clear.target = delegate
        menu.addItem(clear)
    }
}

/// The live AppEffects: AppKit alerts, toasts, Finder, the player, SMAppService.
@MainActor
public final class SystemEffects: AppEffects {
    /// BUBBLE_FAKE: the file does not exist, log instead of opening Finder or a player.
    private let dryRun: Bool
    private let toasts = ToastWindowController()
    fileprivate var settingsWindow: SettingsWindowController?
    fileprivate(set) var recordingsWindow: RecordingsWindowController?
    private let log = Logger(subsystem: "local.bubble.Bubble", category: "Effects")

    public init(dryRun: Bool = false) { self.dryRun = dryRun }

    public func present(_ alert: AppAlert) async -> Int {
        // Let the current event (menu click, hotkey) finish before the modal loop starts.
        await Task.yield()
        return AlertPresenter.run(alert)
    }

    public func showToast(_ toast: Toast) { toasts.show(toast) }

    public func afterStop(_ url: URL, open: Bool) {
        if dryRun {
            log.info("after stop (dry run): copy, reveal\(open ? ", open" : "") \(url.path, privacy: .public)")
            toasts.show(Toast(.info, "Saved \(url.lastPathComponent) (fake: nothing written)"))
            return
        }
        AfterStop.perform(url, open: open)
    }

    public func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) { AfterStop.revealInFinder(url) }
        else { openFolder(url.deletingLastPathComponent()) }
    }

    public func openFolder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    public func playTick() {
        // A soft tick (silent when the Mac is muted: NSSound follows the output volume).
        let sound = NSSound(named: "Tink")
        sound?.volume = 0.25
        sound?.play()
    }

    public func showSettings() { settingsWindow?.show() }

    public func showRecordings() { recordingsWindow?.show() }

    /// The editor (BubbleEditor's EditorService.editURL, wired by main.swift so BubbleUI stays
    /// editor-agnostic): finds or makes the project, returns the page's URL with its token.
    public var editor: (@MainActor @Sendable (URL) async throws -> URL)?
    /// Stops the editor's server at quit (EditorService.stop).
    public var stopEditor: (@MainActor @Sendable () -> Void)?

    /// design.md §10: nothing under 1 s; "Opening the editor…" if not ready after 1 s; an alert with
    /// the reason if it fails. The page opens in the default browser.
    public func editRecording(_ url: URL) {
        guard let editor else {
            AppLog.info("edit \(url.lastPathComponent): no editor")
            toasts.show(Toast(.info, "The editor isn't available in this build"))
            return
        }
        AppLog.info("edit \(url.lastPathComponent): opening")
        let slow = Task { @MainActor [toasts] in
            try await Task.sleep(for: .seconds(1))
            toasts.show(Toast(.info, "Opening the editor…"))
        }
        Task { @MainActor in
            do {
                let page = try await editor(url)
                slow.cancel()
                AppLog.info("edit \(url.lastPathComponent): \(page.host() ?? "?"):\(page.port ?? 0)\(page.path())")
                NSWorkspace.shared.open(page)
            } catch {
                slow.cancel()
                AppLog.info("edit \(url.lastPathComponent) failed: \(error.localizedDescription)")
                // The same sentence as the page (docs/editor-open-video.md §4), e.g. "Bubble can't
                // open .mkv files. It edits MP4, MOV and M4V videos. Convert it to MP4 first."
                _ = await present(AppAlert(title: "Bubble couldn't open “\(url.lastPathComponent)”.",
                                           message: error.localizedDescription, buttons: ["OK"]))
            }
        }
    }

    /// The open panel (File › Open Video…, the menu bar's Open Video…, the page's Open Video… and Locate).
    public let picker = VideoPicker()

    /// File › Open Video… ⌘O: the panel, then the editor in the browser. A panel already up comes forward.
    public func openVideo() {
        Task { @MainActor in
            if let url = await picker.pick(.open, giveFocusBack: false) { editRecording(url) }
        }
    }

    /// The video opened in the editor goes to File › Open Recent and the Dock's list.
    public func noteOpened(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    public func setOpenAtLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            log.error("open at login \(on): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
