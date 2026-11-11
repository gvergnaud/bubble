// Owner: app/UI track. The menu bar item (design.md §6.1): its label (MenuBarLabelView hosted in the
// button), the Recorder panel (our own panel) on left click when idle, the app menu on right click, the
// take menu while recording. Refreshes the timer at 4 Hz during a take.
import AppKit
import BubbleCore
import SwiftUI
import os

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panelWindow: RecorderPanelWindow?
    private var panelHost: NSHostingView<RecorderPanelChrome<RecorderPanelView>>?
    private var timer: Timer?
    private var outsideClickMonitor: Any?
    private var escMonitor: Any?
    var onQuit: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        item.autosaveName = "local.bubble.Bubble.status"
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Bubble")
            button.toolTip = "Bubble · Start or stop recording: ⌥⇧L"
            button.imagePosition = .imageLeading
        }
        trackChanges { [weak self] in self?.apply() }
        AppLog.info("status item created: visible \(item.isVisible), button \(item.button != nil)")
        // Its frame exists once the menu bar has laid it out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logFrame("status item after launch") }
    }

    private func logFrame(_ what: String) {
        let frame = item.button.flatMap { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)) } }
        AppLog.info("\(what): frame \(frame.map { NSStringFromRect($0) } ?? "none"), visible \(item.isVisible), length \(item.length)")
    }

    // MARK: Label

    private func apply() {
        let state = model.menuBarLabel
        if let button = item.button {
            // The button's own image and title: AppKit sizes the item from them. (A SwiftUI view
            // added as a subview made a 2 pt wide item on the first real launch: nothing to click.)
            let (image, title) = Self.content(for: state)
            button.image = image
            button.attributedTitle = title
            button.toolTip = tooltip(for: state)
        }

        // Timer while a take is on.
        let inTake = model.phase.isInTake || model.phase == .starting
        if inTake, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refreshElapsed() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        } else if !inTake, timer != nil {
            timer?.invalidate(); timer = nil
        }

        // The Recorder panel follows the Ready phase.
        if model.phase == .ready {
            showPanel()
        } else {
            hidePanel()
        }
        item.button?.highlight(model.phase == .ready)
        if panelIsShown, let host = panelHost {
            host.rootView = RecorderPanelChrome(content: panelView())
            if let window = panelWindow {
                let size = host.fittingSize
                if window.frame.size != size { window.setFrame(panelFrame(size: size), display: true) }
            }
        }
    }

    /// The menu bar item's image and title for a state (design.md §6.1).
    static func content(for state: MenuBarLabel) -> (NSImage, NSAttributedString) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        func text(_ s: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s.isEmpty ? "" : " " + s, attributes: [.font: font, .foregroundColor: color, .baselineOffset: 0])
        }
        switch state {
        case .idle(let attention):
            return (idleIcon, attention ? text("!", .systemYellow) : NSAttributedString(string: ""))
        case .countdown:
            return (idleIcon, NSAttributedString(string: ""))
        case .recording(let time, let lowDisk):
            return (recordingDot, text(time, lowDisk ? lowDiskColor : .labelColor))
        case .paused(let time):
            let pause = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Paused")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) ?? idleIcon
            pause.isTemplate = true
            return (pause, text(time, .secondaryLabelColor))
        case .saving:
            let saving = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Saving")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? idleIcon
            saving.isTemplate = true
            return (saving, NSAttributedString(string: ""))
        }
    }

    /// The two-bubble glyph (designer's MenuBarGlyph, the user's pick): template at rest.
    static var idleIcon: NSImage { MenuBarGlyph.idle }
    /// The same glyph with its big bubble in red, next to the timer.
    static var recordingDot: NSImage { MenuBarGlyph.recording }

    static let lowDiskColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow : NSColor(srgbRed: 0.70, green: 0.36, blue: 0, alpha: 1)
    }

    private func tooltip(for state: MenuBarLabel) -> String {
        switch state {
        case .idle(let attention): attention ? "Bubble · A recording stopped on its own" : "Bubble · Start or stop recording: ⌥⇧L"
        case .countdown: "Bubble · Starting…"
        case .recording(let t, let low): low ? "Recording \(t) · Disk almost full" : "Recording \(t) · Stop: ⌥⇧L"
        case .paused(let t): "Paused \(t) · Resume: ⌥⇧P"
        case .saving: "Saving…"
        }
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        AppLog.info("status item clicked · event \(NSApp.currentEvent.map { String($0.type.rawValue) } ?? "none") · phase \(model.phase)")
        let right = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        switch model.phase {
        case .idle where !right, .ready where !right:
            model.statusItemClicked()
        default:
            model.menuOpened()
            if model.phase == .ready { model.closePanel() }
            showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in model.menu {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .label(let title):
                let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                mi.isEnabled = false
                menu.addItem(mi)
            case .item(let title, let shortcut, let action, let enabled):
                let mi = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = action.rawValue
                mi.isEnabled = enabled
                if let shortcut { Self.applyShortcut(shortcut, to: mi) }
                menu.addItem(mi)
            }
        }
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left click goes to `clicked` again.
        DispatchQueue.main.async { [weak self] in self?.item.menu = nil }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = MenuAction(rawValue: raw) else { return }
        if action == .quit { onQuit?(); return }
        model.perform(action)
    }

    /// "⌥⇧L" → key equivalent "l" + Option-Shift, shown right-aligned by the menu.
    static func applyShortcut(_ shortcut: String, to item: NSMenuItem) {
        var mods: NSEvent.ModifierFlags = []
        var key = ""
        for ch in shortcut {
            switch ch {
            case "⌥": mods.insert(.option)
            case "⇧": mods.insert(.shift)
            case "⌘": mods.insert(.command)
            case "⌃": mods.insert(.control)
            case "↩": key = "\r"
            case "⎋": key = "\u{1b}"
            default: key = String(ch).lowercased()
            }
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mods
    }

    // MARK: Recorder panel

    private func panelView() -> RecorderPanelView {
        var a = RecorderPanelActions()
        a.selectCamera = { [weak self] in self?.model.selectCamera($0) }
        a.selectMicrophone = { [weak self] in self?.model.selectMicrophone($0) }
        a.setComputerSound = { [weak self] in self?.model.setComputerSound($0) }
        a.selectDisplay = { [weak self] in self?.model.selectDisplay($0) }
        a.requestAccess = { [weak self] in self?.model.requestAccess($0) }
        a.openSystemSettings = { [weak self] in self?.model.openSystemSettings($0) }
        a.start = { [weak self] in self?.model.startFromPanel() }
        a.openFolder = { [weak self] in // the footer's Recordings button (design.md §10.2)
            self?.model.closePanel()
            self?.model.perform(.recordings)
        }
        a.openSettings = { [weak self] in
            self?.model.closePanel()
            self?.model.perform(.settings)
        }
        a.quit = { [weak self] in self?.onQuit?() }
        a.source.select = { [weak self] in self?.model.selectSource($0) }
        a.source.change = { [weak self] in self?.model.changeSource() }
        return RecorderPanelView(state: model.panel, actions: a)
    }

    // The Recorder panel is our own key-capable, non-activating panel under the menu bar item, not
    // an NSPopover: on macOS 26 the status item lives in a scene hosted by Control Center and
    // NSPopover.show(relativeTo:of:) on its button silently shows nothing (the first real launch:
    // "the menu bar icon does nothing"). Non-activating: the user's app keeps the focus, and
    // Return / Esc / the pickers still work because the panel becomes key.

    private var panelIsShown: Bool { panelWindow?.isVisible == true }

    private func showPanel() {
        guard !panelIsShown else { return }
        let host = NSHostingView(rootView: RecorderPanelChrome(content: panelView()))
        let size = host.fittingSize
        let window = panelWindow ?? RecorderPanelWindow()
        panelWindow = window
        panelHost = host
        window.contentView = host
        window.setFrame(panelFrame(size: size), display: true)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        AppLog.info("panel shown: frame \(NSStringFromRect(window.frame)), visible \(window.isVisible), key \(window.isKeyWindow), screen \(window.screen?.localizedName ?? "none")")
        logFrame("status item at panel")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 1
        }
        // Click away (in another app or the menu bar) closes the panel. Clicks in our own windows
        // (the bubble, its controls) are local events and keep it open, so the bubble can be
        // dragged in Ready.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.closePanel() }
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                MainActor.assumeIsolated { self?.model.closePanel() }
                return nil
            }
            return event
        }
    }

    private func hidePanel() {
        guard let window = panelWindow, window.isVisible else { return }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        if let m = escMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        escMonitor = nil
        panelHost = nil
        window.orderOut(nil)
    }

    /// Under the menu bar item, right-aligned to it when there is room, on the screen of the item.
    private func panelFrame(size: CGSize) -> NSRect {
        let itemRect: NSRect? = item.button.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
        let screen = itemRect.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let anchorX = itemRect?.midX ?? NSEvent.mouseLocation.x
        var x = anchorX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = visible.maxY - size.height - 6
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// The Recorder panel's window: borderless, rounded, a popover material, key without activating.
@MainActor
final class RecorderPanelWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        title = "Bubble recorder"
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's background: the system popover material with rounded corners.
struct RecorderPanelChrome<Content: View>: View {
    var content: Content
    var body: some View {
        content
            .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Lets clicks through to the status bar button below.
final class LabelHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
