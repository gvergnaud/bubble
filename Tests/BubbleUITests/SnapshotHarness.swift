// Owner: QA track. Renders SwiftUI views and NSViews to @2x PNGs, offscreen: the view is hosted in a
// borderless window that is never ordered in (nothing appears on screen), then drawn with
// cacheDisplay into a 2x bitmap. AppKit-backed controls (pickers, toggles) render for real, which
// ImageRenderer does not do. Files: $BUBBLE_SNAPSHOT_DIR (scripts/check.sh) or build/snapshots,
// named <state>-light.png and <state>-dark.png.
import AppKit
import SwiftUI

@MainActor
enum Snap {
    enum Mode: String, CaseIterable { case light, dark }

    static let dir: URL = {
        if let d = ProcessInfo.processInfo.environment["BUBBLE_SNAPSHOT_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("build/snapshots", isDirectory: true)
    }()

    /// Every PNG written in this run (the catalog test checks it against the list).
    static var written: [String] = []

    /// What sits behind a transparent view.
    enum Backdrop {
        case none          // the view draws its own background (windows, panels)
        case window        // the window background color of the mode
        case desktop       // a fake screen (synthetic page), for things that float over apps
        case menuBar       // a menu bar strip
    }

    /// Renders `view` in light and dark. `size`: points; nil = the view's fitting size.
    static func render<V: View>(_ name: String, size: CGSize? = nil, backdrop: Backdrop = .window, @ViewBuilder _ view: () -> V) {
        let content = view()
        for mode in Mode.allCases {
            let root = ZStack { backdropView(backdrop, mode); content }
                .environment(\.colorScheme, mode == .dark ? .dark : .light)
            let host = NSHostingView(rootView: root)
            host.appearance = appearance(mode)
            let s = size ?? host.fittingSize
            write(host, size: s, name: "\(name)-\(mode.rawValue)", mode: mode)
        }
    }

    /// Renders an NSView built per mode (NSAlert content, AppKit pieces).
    static func renderNSView(_ name: String, _ make: (Mode) -> (NSView, CGSize)) {
        for mode in Mode.allCases {
            let (view, size) = make(mode)
            view.appearance = appearance(mode)
            write(view, size: size, name: "\(name)-\(mode.rawValue)", mode: mode)
        }
    }

    static func appearance(_ mode: Mode) -> NSAppearance { NSAppearance(named: mode == .dark ? .darkAqua : .aqua)! }

    private static func write(_ view: NSView, size: CGSize, name: String, mode: Mode) {
        let frame = CGRect(origin: .zero, size: CGSize(width: ceil(size.width), height: ceil(size.height)))
        // Never ordered in: the window only gives the view a backing and an appearance.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance(mode)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = view
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * 2), pixelsHigh: Int(frame.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = frame.size
        NSAppearance.current = appearance(mode)
        appearance(mode).performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: frame, to: rep)
        }
        window.contentView = nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        written.append(name)
    }

    @ViewBuilder
    private static func backdropView(_ b: Backdrop, _ mode: Mode) -> some View {
        switch b {
        case .none: EmptyView()
        case .window: Color(nsColor: .windowBackgroundColor)
        case .desktop: FakeDesktop(dark: mode == .dark)
        case .menuBar: (mode == .dark ? Color(white: 0.17) : Color(white: 0.93))
        }
    }
}

/// A screen-like backdrop: a window of text on a wallpaper gradient.
struct FakeDesktop: View {
    var dark: Bool
    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.12, green: 0.14, blue: 0.24), Color(red: 0.05, green: 0.06, blue: 0.1)]
                                        : [Color(red: 0.55, green: 0.72, blue: 0.95), Color(red: 0.86, green: 0.78, blue: 0.92)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<40, id: \.self) { i in
                        Text("\(String(format: "%03d", i))  func record(_ screen: Display) -> URL { // the quick brown fox")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(dark ? Color(white: 0.85) : Color(white: 0.15))
                    }
                }
                .padding(14)
                .frame(width: g.size.width * 0.8, height: g.size.height * 0.8, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(dark ? Color(white: 0.16) : Color(white: 0.98)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
    }
}

/// A picture of an NSMenu drawn from MenuBuilder's data. NSMenu cannot be rendered offscreen; this
/// mock shows the titles, shortcuts and enabled flags the real menu gets, in the system menu style.
struct MenuMock: View {
    struct Row: Identifiable { var id: Int; var title: String?; var shortcut: String?; var enabled: Bool; var label: Bool }
    var rows: [Row]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { r in
                if let title = r.title {
                    HStack {
                        Text(title)
                        Spacer(minLength: 28)
                        if let s = r.shortcut { Text(s).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(r.enabled && !r.label ? Color.primary : Color.secondary.opacity(0.7))
                    .padding(.horizontal, 12).frame(height: 22)
                } else {
                    Divider().padding(.horizontal, 10).padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 240)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        .padding(10)
    }
}
