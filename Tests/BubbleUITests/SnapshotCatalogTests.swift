// Owner: QA track. The snapshot catalog: every v1 UI state of docs/design.md, light and dark, @2x,
// rendered offscreen (SnapshotHarness). The designer reviews build/check/snapshots/index.html.
// These tests check that each state renders; how it looks is the designer's call.
import AppKit
import AVFoundation
import BubbleCore
import BubbleTesting
import BubbleUI
import SwiftUI
import Testing

@MainActor
enum Catalog {
    static let face = SyntheticFrames.placeholderFace(size: 600)
    static let cams = [FakeDeviceCatalog.faceTime, FakeDeviceCatalog.continuity]
    static let mics = [FakeDeviceCatalog.builtInMic, FakeDeviceCatalog.airPods]

    static func panel(cameras: [DeviceInfo] = cams, camera: String? = FakeDeviceCatalog.faceTime.id, cameraAccess: Access = .granted,
                      microphones: [DeviceInfo] = mics, mic: String? = FakeDeviceCatalog.builtInMic.id, micAccess: Access = .granted,
                      computerSound: Bool = false, displays: [DisplayInfo] = []) -> RecorderPanelState {
        RecorderPanelState(cameras: cameras, selectedCameraID: camera, cameraAccess: cameraAccess,
                           microphones: microphones, selectedMicrophoneID: mic, microphoneAccess: micAccess,
                           computerSound: computerSound, displays: displays, selectedDisplayID: displays.first?.id)
    }

    static func menu(_ phase: Phase, cameraHidden: Bool = false, camera: Bool = true, last: Bool = true) -> MenuMock {
        let entries = MenuBuilder.menu(phase: phase, cameraAvailable: camera, cameraHidden: cameraHidden, hasLastRecording: last)
        return MenuMock(rows: entries.enumerated().map { i, e in
            switch e {
            case .item(let t, let s, _, let enabled): MenuMock.Row(id: i, title: t, shortcut: s, enabled: enabled, label: false)
            case .label(let t): MenuMock.Row(id: i, title: t, shortcut: nil, enabled: false, label: true)
            case .separator: MenuMock.Row(id: i, title: nil, shortcut: nil, enabled: true, label: false)
            }
        })
    }

    /// A display scaled to half size with the bubble at `place`: shows corners and margins in context.
    static func bubbleOnDisplay(_ place: BubblePlace, dimmed: Bool = false) -> some View {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let f = BubblePlacement.frame(for: place, in: display)   // AppKit coords, origin bottom-left
        let pad = BubbleView.shadowPadding   // BubbleView pads itself by this, for its shadow
        return ZStack(alignment: .topLeading) {
            FakeDesktopProxy()
            BubbleView(content: .image(face), diameter: place.size.diameter, mirrored: true, dimmed: dimmed)
                .offset(x: f.minX - pad, y: display.height - f.maxY - pad)
        }
        .frame(width: display.width, height: display.height)
        .scaleEffect(0.5, anchor: .topLeading)
        .frame(width: display.width / 2, height: display.height / 2, alignment: .topLeading)
    }
}

/// A whole display at half size, as the user sees it: menu bar (with Bubble's item), the bubble at
/// its place, and in Ready the Recorder panel hanging under the item. Points are the display's.
struct ScreenComposition: View {
    enum Scene { case ready, recording(String), paused(String) }
    var scene: Scene
    @Environment(\.colorScheme) var scheme
    static let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let menuBarHeight: CGFloat = 24
    static let itemRightInset: CGFloat = 170      // Bubble's item sits left of the clock & controls

    var body: some View {
        let d = Self.display
        let place = BubblePlace(size: .medium, corner: .bottomLeft)
        let f = BubblePlacement.frame(for: place, in: CGRect(x: 0, y: 0, width: d.width, height: d.height - Self.menuBarHeight))
        let pad = BubbleView.shadowPadding
        let dimmed: Bool = { if case .paused = scene { return true }; return false }()
        ZStack(alignment: .topLeading) {
            FakeDesktopProxy().padding(.top, Self.menuBarHeight)
            BubbleView(content: .image(Catalog.face), diameter: place.size.diameter, mirrored: true, dimmed: dimmed)
                .offset(x: f.minX - pad, y: d.height - f.maxY - pad)
            menuBar
            if case .ready = scene {
                RecorderPanelView(state: Catalog.panel())
                    .frame(width: RecorderPanelView.width)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                    .offset(x: d.width - Self.itemRightInset - RecorderPanelView.width / 2 - 20, y: Self.menuBarHeight + 6)
            }
        }
        .frame(width: d.width, height: d.height, alignment: .topLeading)
        .clipped()
        .scaleEffect(0.5, anchor: .topLeading)
        .frame(width: d.width / 2, height: d.height / 2, alignment: .topLeading)
    }

    private var label: MenuBarLabel {
        switch scene {
        case .ready: .idle(attention: false)
        case .recording(let t): .recording(time: t, lowDisk: false)
        case .paused(let t): .paused(time: t)
        }
    }

    private var menuBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "applelogo").font(.system(size: 14))
            Text("Finder").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            MenuBarLabelView(label: label)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity({ if case .ready = scene { return 0.15 }; return 0 }())))
            Image(systemName: "wifi").font(.system(size: 13))
            Image(systemName: "battery.75percent").font(.system(size: 13))
            Text("Fri 6 Nov  15:22").font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .frame(width: Self.display.width, height: Self.menuBarHeight)
        .background(scheme == .dark ? Color(white: 0.12).opacity(0.85) : Color(white: 0.96).opacity(0.85))
    }
}

/// Lets the catalog put the harness backdrop inside a composed view.
struct FakeDesktopProxy: View {
    @Environment(\.colorScheme) var scheme
    var body: some View { FakeDesktop(dark: scheme == .dark) }
}

/// The states, in the order of the contact sheet. Each name becomes <name>-light.png / -dark.png.
@MainActor
let catalog: [(String, () -> Void)] = [
    // Whole-screen compositions (designer, round 2)
    ("screen-ready", { Snap.render("screen-ready", backdrop: .none) { ScreenComposition(scene: .ready) } }),
    ("screen-recording", { Snap.render("screen-recording", backdrop: .none) { ScreenComposition(scene: .recording("03:12")) } }),
    ("screen-paused", { Snap.render("screen-paused", backdrop: .none) { ScreenComposition(scene: .paused("03:12")) } }),
    // 6.1 Menu bar item
    ("menubar-idle", { Snap.render("menubar-idle", size: CGSize(width: 120, height: 24), backdrop: .menuBar) { MenuBarLabelView(label: .idle(attention: false)) } }),
    ("menubar-idle-attention", { Snap.render("menubar-idle-attention", size: CGSize(width: 120, height: 24), backdrop: .menuBar) { MenuBarLabelView(label: .idle(attention: true)) } }),
    ("menubar-recording-0007", { Snap.render("menubar-recording-0007", size: CGSize(width: 120, height: 24), backdrop: .menuBar) { MenuBarLabelView(label: .recording(time: "00:07", lowDisk: false)) } }),
    ("menubar-recording-0312", { Snap.render("menubar-recording-0312", size: CGSize(width: 120, height: 24), backdrop: .menuBar) { MenuBarLabelView(label: .recording(time: "03:12", lowDisk: false)) } }),
    ("menubar-recording-10203", { Snap.render("menubar-recording-10203", size: CGSize(width: 120, height: 24), backdrop: .menuBar) { MenuBarLabelView(label: .recording(time: "1:02:03", lowDisk: false)) } }),
    ("menubar-recording-lowdisk", { Snap.render("menubar-recording-lowdisk", size: CGSize(width: 120, height: 24), backdrop: .menuBar) { MenuBarLabelView(label: .recording(time: "41:09", lowDisk: true)) } }),
    ("menubar-paused", { Snap.render("menubar-paused", size: CGSize(width: 120, height: 24), backdrop: .menuBar) { MenuBarLabelView(label: .paused(time: "03:12")) } }),
    ("menubar-saving", { Snap.render("menubar-saving", size: CGSize(width: 120, height: 24), backdrop: .menuBar) { MenuBarLabelView(label: .saving) } }),
    // 5.7 menus (drawn from MenuBuilder data)
    ("menu-recording", { Snap.render("menu-recording", backdrop: .none) { Catalog.menu(.recording) } }),
    ("menu-paused", { Snap.render("menu-paused", backdrop: .none) { Catalog.menu(.paused) } }),
    ("menu-camera-hidden", { Snap.render("menu-camera-hidden", backdrop: .none) { Catalog.menu(.recording, cameraHidden: true) } }),
    ("menu-no-camera", { Snap.render("menu-no-camera", backdrop: .none) { Catalog.menu(.recording, camera: false) } }),
    ("menu-countdown", { Snap.render("menu-countdown", backdrop: .none) { Catalog.menu(.countdown(2)) } }),
    ("menu-idle", { Snap.render("menu-idle", backdrop: .none) { Catalog.menu(.idle) } }),
    ("menu-idle-no-last", { Snap.render("menu-idle-no-last", backdrop: .none) { Catalog.menu(.idle, last: false) } }),
    // 6.2 Recorder panel
    ("panel-1-display", { Snap.render("panel-1-display") { RecorderPanelView(state: Catalog.panel()) } }),
    ("panel-2-displays", { Snap.render("panel-2-displays") { RecorderPanelView(state: Catalog.panel(displays: [FakeDeviceCatalog.builtIn, FakeDeviceCatalog.studioDisplay])) } }),
    ("panel-no-camera-picked", { Snap.render("panel-no-camera-picked") { RecorderPanelView(state: Catalog.panel(camera: nil)) } }),
    ("panel-no-camera-found", { Snap.render("panel-no-camera-found") { RecorderPanelView(state: Catalog.panel(cameras: [], camera: nil)) } }),
    ("panel-camera-blocked", { Snap.render("panel-camera-blocked") { RecorderPanelView(state: Catalog.panel(camera: nil, cameraAccess: .blocked)) } }),
    ("panel-mic-blocked", { Snap.render("panel-mic-blocked") { RecorderPanelView(state: Catalog.panel(mic: nil, micAccess: .blocked)) } }),
    ("panel-not-asked", { Snap.render("panel-not-asked") { RecorderPanelView(state: Catalog.panel(camera: nil, cameraAccess: .notAsked, mic: nil, micAccess: .notAsked)) } }),
    ("panel-no-mic-picked", { Snap.render("panel-no-mic-picked") { RecorderPanelView(state: Catalog.panel(mic: nil)) } }),
    ("panel-computer-sound-on", { Snap.render("panel-computer-sound-on") { RecorderPanelView(state: Catalog.panel(computerSound: true)) } }),
    // 6.3 Bubble
    ("bubble-s", { Snap.render("bubble-s", backdrop: .desktop) { BubbleView(content: .image(Catalog.face), diameter: BubbleSize.small.diameter) } }),
    ("bubble-m", { Snap.render("bubble-m", backdrop: .desktop) { BubbleView(content: .image(Catalog.face), diameter: BubbleSize.medium.diameter) } }),
    ("bubble-l", { Snap.render("bubble-l", backdrop: .desktop) { BubbleView(content: .image(Catalog.face), diameter: BubbleSize.large.diameter) } }),
    ("bubble-not-mirrored", { Snap.render("bubble-not-mirrored", backdrop: .desktop) { BubbleView(content: .image(Catalog.face), diameter: 180, mirrored: false) } }),
    ("bubble-loading", { Snap.render("bubble-loading", backdrop: .desktop) { BubbleView(content: .waiting, diameter: 180) } }),
    // "Camera unavailable" (CameraFeed.onLiveChange(false)) is rendered by app-ui's RecordingsTests: bubble-camera-unavailable-s/-m.
    ("bubble-dimmed", { Snap.render("bubble-dimmed", backdrop: .desktop) { BubbleView(content: .image(Catalog.face), diameter: 180, dimmed: true) } }),
    ("bubble-hover-s", { Snap.render("bubble-hover-s", backdrop: .desktop) {
        ZStack { BubbleView(content: .image(Catalog.face), diameter: 120)
                 BubbleHoverControlsView(diameter: 120, size: .small) } } }),
    ("bubble-hover-m", { Snap.render("bubble-hover-m", backdrop: .desktop) {
        ZStack { BubbleView(content: .image(Catalog.face), diameter: 180)
                 BubbleHoverControlsView(diameter: 180, size: .medium) } } }),
    ("bubble-hover-l", { Snap.render("bubble-hover-l", backdrop: .desktop) {
        ZStack { BubbleView(content: .image(Catalog.face), diameter: 260)
                 BubbleHoverControlsView(diameter: 260, size: .large) } } }),
    ("bubble-corner-bottom-left", { Snap.render("bubble-corner-bottom-left", backdrop: .none) { Catalog.bubbleOnDisplay(BubblePlace(size: .medium, corner: .bottomLeft)) } }),
    ("bubble-corner-bottom-right", { Snap.render("bubble-corner-bottom-right", backdrop: .none) { Catalog.bubbleOnDisplay(BubblePlace(size: .medium, corner: .bottomRight)) } }),
    ("bubble-corner-top-left", { Snap.render("bubble-corner-top-left", backdrop: .none) { Catalog.bubbleOnDisplay(BubblePlace(size: .medium, corner: .topLeft)) } }),
    ("bubble-corner-top-right", { Snap.render("bubble-corner-top-right", backdrop: .none) { Catalog.bubbleOnDisplay(BubblePlace(size: .medium, corner: .topRight)) } }),
    ("bubble-free-l", { Snap.render("bubble-free-l", backdrop: .none) { Catalog.bubbleOnDisplay(BubblePlace(size: .large, corner: nil, relativeCenter: CGPoint(x: 0.62, y: 0.4))) } }),
    // 6.4 Countdown
    ("countdown-3", { Snap.render("countdown-3", size: CountdownView.windowSize, backdrop: .desktop) { CountdownView(digit: 3) } }),
    ("countdown-2", { Snap.render("countdown-2", size: CountdownView.windowSize, backdrop: .desktop) { CountdownView(digit: 2) } }),
    ("countdown-1", { Snap.render("countdown-1", size: CountdownView.windowSize, backdrop: .desktop) { CountdownView(digit: 1) } }),
    ("countdown-resume-3", { Snap.render("countdown-resume-3", size: CountdownView.windowSize, backdrop: .desktop) { CountdownView(digit: 3, resuming: true) } }),
    // 5.1 Welcome
    ("welcome-nothing-granted", { Snap.render("welcome-nothing-granted") { WelcomeView(state: WelcomeState(screen: .notDetermined, camera: .notDetermined, microphone: .notDetermined), icon: appIcon) } }),
    ("welcome-screen-needs-relaunch", { Snap.render("welcome-screen-needs-relaunch") { WelcomeView(state: WelcomeState(screen: .needsRelaunch, camera: .granted, microphone: .notDetermined), icon: appIcon) } }),
    ("welcome-mixed-denied", { Snap.render("welcome-mixed-denied") { WelcomeView(state: WelcomeState(screen: .granted, camera: .denied, microphone: .granted), icon: appIcon) } }),
    ("welcome-screen-denied", { Snap.render("welcome-screen-denied") { WelcomeView(state: WelcomeState(screen: .denied, camera: .notDetermined, microphone: .notDetermined), icon: appIcon) } }),
    ("welcome-all-granted", { Snap.render("welcome-all-granted") { WelcomeView(state: WelcomeState(screen: .granted, camera: .granted, microphone: .granted), icon: appIcon) } }),
    // 6.6 Settings
    ("settings", { Snap.render("settings") { SettingsView(state: SettingsState(folderPath: "~/Movies/Bubble")) } }),
    ("settings-shortcut-in-use", { Snap.render("settings-shortcut-in-use") {
        SettingsView(state: SettingsState(hotkeysInUse: [.startStop], folderPath: "~/Movies/Bubble")) } }),
    // Toasts (7.3, 7.4, 5.5)
    ("toast-mic-switched", { Snap.render("toast-mic-switched", backdrop: .desktop) { ToastView(toast: Toast(.mic, "Now using MacBook Pro Microphone")) } }),
    ("toast-mic-lost", { Snap.render("toast-mic-lost", backdrop: .desktop) { ToastView(toast: Toast(.mic, "Microphone disconnected. Recording goes on without sound.")) } }),
    ("toast-no-video", { Snap.render("toast-no-video", backdrop: .desktop) { ToastView(toast: Toast(.camera, "No video from FaceTime HD Camera")) } }),
    ("toast-camera-disconnected", { Snap.render("toast-camera-disconnected", backdrop: .desktop) { ToastView(toast: Toast(.camera, "Camera disconnected")) } }),
    ("toast-low-disk", { Snap.render("toast-low-disk", backdrop: .desktop) { ToastView(toast: Toast(.disk, "2 GB left, about 38 min")) } }),
    ("toast-discard-hint", { Snap.render("toast-discard-hint", backdrop: .desktop) { ToastView(toast: Toast(.discard, "Press ⌥⇧C again to discard")) } }),
    ("toast-computer-sound-lost", { Snap.render("toast-computer-sound-lost", backdrop: .desktop) { ToastView(toast: Toast(.speaker, "Computer sound stopped. Recording goes on with the mic.")) } }),
]

@MainActor
let alertCatalog: [(String, AppAlert)] = {
    let file = URL(fileURLWithPath: "/Users/me/Movies/Bubble/Bubble 2026-11-06 at 14.22.05.mp4")
    func result(_ r: StopReason) -> RecordingResult { RecordingResult(url: file, duration: 252, bytes: 186_000_000, reason: r) }
    return [
        ("alert-discard", Messages.discardConfirm),
        ("alert-quit-while-recording", Messages.quitWhileRecording),
        ("alert-not-enough-space", Messages.notEnoughSpace(bytesFree: 600_000_000, folder: URL(fileURLWithPath: "/"))),
        ("alert-display-disconnected", Messages.stoppedOnItsOwn(result(.displayDisconnected))!),
        ("alert-disk-almost-full", Messages.stoppedOnItsOwn(result(.diskAlmostFull))!),
        ("alert-screen-permission-revoked", Messages.stoppedOnItsOwn(result(.screenPermissionRevoked))!),
        ("alert-writer-failed", Messages.stoppedOnItsOwn(result(.failed("The encoder stopped (AVFoundation -11800).")))!),
    ]
}()

/// The real NSAlert, laid out and drawn offscreen (its window is never shown).
@MainActor
func alertView(_ a: AppAlert) -> (NSView, CGSize) {
    // The app's own factory (same text, style, buttons, destructive flag as at run time).
    let alert = AlertPresenter.make(a, icon: appIcon)
    alert.layout()
    let content = alert.window.contentView!
    let size = alert.window.frame.size
    alert.window.contentView = NSView()
    // The alert window's own background (an NSVisualEffectView in macOS 26) does not draw offscreen:
    // put the content on the window background color.
    let box = NSView(frame: CGRect(origin: .zero, size: size))
    box.wantsLayer = true
    let bg = NSBox(frame: box.bounds); bg.boxType = .custom; bg.fillColor = .windowBackgroundColor; bg.borderWidth = 0; bg.cornerRadius = 16
    box.addSubview(bg)
    content.frame = CGRect(origin: .zero, size: content.frame.size)
    box.addSubview(content)
    return (box, size)
}

@MainActor
let appIcon: NSImage = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")) ?? NSImage(size: CGSize(width: 64, height: 64))
}()

@MainActor @Suite(.serialized)
struct SnapshotCatalogTests {
    @Test func everyViewState() throws {
        for (name, render) in catalog {
            render()
            for mode in ["light", "dark"] {
                let url = Snap.dir.appendingPathComponent("\(name)-\(mode).png")
                #expect(FileManager.default.fileExists(atPath: url.path), "\(name)-\(mode).png not written")
                let img = NSImage(contentsOf: url)
                #expect(img != nil && img!.size.width > 10, "\(name)-\(mode).png is empty")
            }
        }
    }

    @Test func everyAlert() throws {
        for (name, alert) in alertCatalog {
            Snap.renderNSView(name) { _ in alertView(alert) }
            #expect(FileManager.default.fileExists(atPath: Snap.dir.appendingPathComponent("\(name)-light.png").path))
        }
    }

    /// The designer's list (message m_53) must all be in the catalog.
    @Test func catalogCoversTheDesignersList() {
        let names = Set(catalog.map(\.0) + alertCatalog.map(\.0))
        let required = ["menubar-idle", "menubar-recording-0007", "menubar-recording-10203", "menubar-paused",
                        "menu-recording", "menu-paused", "menu-camera-hidden",
                        "panel-1-display", "panel-2-displays", "panel-no-camera-picked", "panel-mic-blocked",
                        "bubble-s", "bubble-m", "bubble-l", "bubble-hover-m", "bubble-loading", "bubble-dimmed",
                        "bubble-corner-bottom-left", "bubble-corner-bottom-right", "bubble-corner-top-left", "bubble-corner-top-right",
                        "countdown-3", "alert-discard", "settings", "settings-shortcut-in-use",
                        "welcome-nothing-granted", "welcome-screen-needs-relaunch", "welcome-all-granted",
                        "alert-not-enough-space", "alert-disk-almost-full", "alert-quit-while-recording"]
        for r in required { #expect(names.contains(r), "missing snapshot: \(r)") }
    }
}
