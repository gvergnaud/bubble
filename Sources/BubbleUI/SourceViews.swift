// Owner: app/UI track. Record a window or an area (design.md §11): the Recorder panel's source
// control and row, the Area overlay, and the corner brackets that mark an area during a take.
// Every view renders from plain values (snapshots); the windows that host them live in
// SourceWindows.swift.
import AppKit
import SwiftUI

// MARK: - Values

/// What the take records (design.md §11.1). Remembered between takes.
public enum SourceKind: String, Sendable, Codable, CaseIterable, Equatable {
    case fullScreen, window, area

    public var title: String {
        switch self {
        case .fullScreen: "Full screen"
        case .window: "Window"
        case .area: "Area"
        }
    }
}

/// The panel's source control and the row under it.
public struct SourceRowState: Sendable, Equatable {
    public struct PickedWindow: Sendable, Equatable {
        public var appName: String
        public var title: String
        /// The app's bundle, for its icon (nil: a generic app icon).
        public var appPath: String?
        public init(appName: String, title: String, appPath: String? = nil) {
            self.appName = appName; self.title = title; self.appPath = appPath
        }
        /// "<App> — <window title>", or the app name alone for an untitled window.
        public var line: String { title.isEmpty ? appName : "\(appName) — \(title)" }
    }

    public var kind: SourceKind
    /// Window: the picked one (nil while the picker is up for the first time).
    public var window: PickedWindow?
    /// Area: its size in points and its display.
    public var areaSize: CGSize?
    public var areaDisplay: String?
    /// The frame's shorter side is under 240 pt: the take records without the camera.
    public var tooSmallForBubble: Bool

    public init(kind: SourceKind = .fullScreen, window: PickedWindow? = nil, areaSize: CGSize? = nil,
                areaDisplay: String? = nil, tooSmallForBubble: Bool = false) {
        self.kind = kind; self.window = window; self.areaSize = areaSize; self.areaDisplay = areaDisplay
        self.tooSmallForBubble = tooSmallForBubble
    }

    /// "1280 × 720", or "1280 × 720 · Studio Display" with 2+ displays.
    public var areaLine: String? {
        guard let areaSize else { return nil }
        let size = SourceFormat.size(areaSize)
        return areaDisplay.map { "\(size) · \($0)" } ?? size
    }

    /// design.md §11.2, under the source row.
    public var tooSmallLine: String? {
        guard tooSmallForBubble, kind != .fullScreen else { return nil }
        return kind == .window
            ? "This window is too small for your bubble: recording without the camera."
            : "This area is too small for your bubble: recording without the camera."
    }
}

public enum SourceFormat {
    /// "1280 × 720" (points, rounded).
    public static func size(_ s: CGSize) -> String { "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))" }
}

// MARK: - Panel: source control + row

public struct SourceActions {
    public var select: @MainActor @Sendable (SourceKind) -> Void = { _ in }
    /// Change…: the window picker or the area overlay again.
    public var change: @MainActor @Sendable () -> Void = {}
    public init() {}
}

struct SourceSection: View {
    var state: SourceRowState
    var windowAvailable = true
    var actions: SourceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Record", selection: Binding(get: { state.kind }, set: { actions.select($0) })) {
                Text(SourceKind.fullScreen.title).tag(SourceKind.fullScreen)
                if windowAvailable {
                    Text(SourceKind.window.title).tag(SourceKind.window)
                        .help("Menus, pop-ups and sheets that an app draws as separate windows may not show in a window recording; use Area or Full screen for those.")
                }
                Text(SourceKind.area.title).tag(SourceKind.area)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if let line = rowLine {
                HStack(spacing: 6) {
                    rowIcon
                    if state.kind == .area, let size = state.areaSize {
                        // The size never truncates; a long display name is cut at its end.
                        HStack(spacing: 4) {
                            Text(SourceFormat.size(size)).fixedSize()
                            if let name = state.areaDisplay {
                                Text("· \(name)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .font(.system(size: 12.5))
                        .help(line)
                    } else {
                        Text(line)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(line)
                    }
                    Spacer(minLength: 4)
                    Button("Change…", action: actions.change)
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .frame(height: 20)
            }
            if let tooSmall = state.tooSmallLine {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 10.5))
                    Text(tooSmall)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var rowLine: String? {
        switch state.kind {
        case .fullScreen: nil
        case .window: state.window?.line
        case .area: state.areaLine
        }
    }

    @ViewBuilder private var rowIcon: some View {
        switch state.kind {
        case .window:
            Image(nsImage: Self.icon(state.window?.appPath ?? state.window.flatMap { Self.runningAppPath($0.appName) }))
                .resizable()
                .frame(width: 16, height: 16)
        default:
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    /// The picked window's app, for its icon (the contract's PickedWindow carries only its name).
    static func runningAppPath(_ appName: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == appName }?.bundleURL?.path
    }

    static func icon(_ appPath: String?) -> NSImage {
        if let appPath { return NSWorkspace.shared.icon(forFile: appPath) }
        return NSWorkspace.shared.icon(for: .application)
    }
}

// MARK: - Area overlay (design.md §11.3)

public struct AreaOverlayState: Sendable, Equatable {
    /// The display's size in points (the overlay covers it).
    public var displaySize: CGSize
    /// The area, in the overlay's top-left coordinates. nil: nothing drawn yet.
    public var rect: CGRect?
    /// Return starts the take (opened from ⌥⇧L) instead of only choosing the area.
    public var startsRecording: Bool

    public static let minimum = CGSize(width: 320, height: 240)

    public init(displaySize: CGSize, rect: CGRect? = nil, startsRecording: Bool = false) {
        self.displaySize = displaySize; self.rect = rect; self.startsRecording = startsRecording
    }

    public var tooSmall: Bool {
        guard let rect else { return false }
        return rect.width < Self.minimum.width || rect.height < Self.minimum.height
    }

    public var canUse: Bool { rect != nil && !tooSmall }
}

public struct AreaOverlayActions {
    /// The area changed (drawn, moved, resized), in the overlay's top-left coordinates.
    public var setRect: @MainActor @Sendable (CGRect) -> Void = { _ in }
    public var use: @MainActor @Sendable () -> Void = {}
    public var cancel: @MainActor @Sendable () -> Void = {}
    public init() {}
}

/// The geometry of drawing, moving and resizing the area (pure, tested).
public enum AreaGeometry {
    public enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// A rect from two drag points; `keepRatio` (⇧) keeps `ratio`, `snap169` (⌘) snaps to 16:9 sizes.
    public static func drawn(from a: CGPoint, to b: CGPoint, bounds: CGSize, keepRatio ratio: CGFloat? = nil,
                             snap169: Bool = false) -> CGRect {
        var w = abs(b.x - a.x), h = abs(b.y - a.y)
        if snap169 {
            (w, h) = snapped169(width: w)
        } else if let ratio, ratio > 0 {
            h = w / ratio
        }
        let x = b.x >= a.x ? a.x : a.x - w
        let y = b.y >= a.y ? a.y : a.y - h
        return clamp(CGRect(x: x, y: y, width: w, height: h), bounds: bounds)
    }

    /// 16:9 sizes in 16 pt steps of width ≥ 320 (1280 × 720, 1920 × 1080…), nearest to `width`.
    public static func snapped169(width: CGFloat) -> (CGFloat, CGFloat) {
        let step: CGFloat = 64 // 64 × 36 keeps both sides whole
        let w = max(320, (width / step).rounded() * step)
        return (w, w * 9 / 16)
    }

    public static func moved(_ r: CGRect, by d: CGSize, bounds: CGSize) -> CGRect {
        var m = r.offsetBy(dx: d.width, dy: d.height)
        m.origin.x = min(max(0, m.origin.x), bounds.width - m.width)
        m.origin.y = min(max(0, m.origin.y), bounds.height - m.height)
        return m
    }

    public static func resized(_ r: CGRect, handle: Handle, to p: CGPoint, bounds: CGSize, keepRatio: Bool = false) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        var out = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        if keepRatio, r.height > 0 {
            let ratio = r.width / r.height
            out.size.height = out.width / ratio
            if [.topLeft, .topRight, .top].contains(handle) { out.origin.y = r.maxY - out.height }
        }
        return clamp(out, bounds: bounds)
    }

    public static func clamp(_ r: CGRect, bounds: CGSize) -> CGRect {
        CGRect(origin: .zero, size: bounds).intersection(r).standardized
    }

    public static func handlePoint(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The bar sits under the area, or above it when there's no room at the bottom edge.
    public static func barAbove(_ r: CGRect, bounds: CGSize, barHeight: CGFloat = 44) -> Bool {
        r.maxY + barHeight + 12 > bounds.height
    }
}

public struct AreaOverlayView: View {
    var state: AreaOverlayState
    var actions: AreaOverlayActions
    @State private var dragStart: CGPoint?
    @State private var moveOrigin: CGRect?
    @State private var resizeHandle: AreaGeometry.Handle?

    public init(state: AreaOverlayState, actions: AreaOverlayActions = .init()) {
        self.state = state; self.actions = actions
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Dimmed display with the area cut out.
            Canvas { ctx, size in
                var path = Path(CGRect(origin: .zero, size: size))
                if let r = state.rect { path.addRect(r) }
                ctx.fill(path, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
            }
            .allowsHitTesting(false)

            if let r = state.rect {
                // A 0.5 pt dark line just outside the white one keeps it visible on white content.
                Rectangle()
                    .strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5)
                    .frame(width: r.width + 1, height: r.height + 1)
                    .offset(x: r.minX - 0.5, y: r.minY - 0.5)
                    .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
                ForEach(AreaGeometry.Handle.allCases, id: \.self) { h in
                    let p = AreaGeometry.handlePoint(h, in: r)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.3), radius: 1.5)
                        .offset(x: p.x - 4.5, y: p.y - 4.5)
                        .allowsHitTesting(false)
                }
                bar(r)
            } else {
                hint
            }
        }
        .frame(width: state.displaySize.width, height: state.displaySize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(drag)
        .environment(\.colorScheme, .dark)
    }

    private var hint: some View {
        VStack(spacing: 6) {
            Text("Drag to choose the area to record")
                .font(.system(size: 15, weight: .semibold))
            Text("Esc to cancel")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.55)))
        .frame(width: state.displaySize.width, height: state.displaySize.height)
        .allowsHitTesting(false)
    }

    private func bar(_ r: CGRect) -> some View {
        let above = AreaGeometry.barAbove(r, bounds: state.displaySize)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(SourceFormat.size(r.size))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(state.tooSmall ? Color.orange : .white)
                if state.tooSmall {
                    Text("At least 320 × 240")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            Button("Cancel", action: actions.cancel)
                .keyboardShortcut(.cancelAction)
            Button(state.startsRecording ? "Start Recording" : "Use This Area", action: actions.use)
                .keyboardShortcut(.defaultAction)
                .disabled(!state.canUse)
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .frame(minWidth: 300)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.72)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .alignmentGuide(.leading) { d in
            // Centered on the area, kept on screen.
            let x = min(max(8, r.midX - d.width / 2), state.displaySize.width - d.width - 8)
            return -x
        }
        .alignmentGuide(.top) { d in -(above ? r.minY - d.height - 10 : r.maxY + 10) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { g in
                let flags = NSEvent.modifierFlags
                if dragStart == nil {
                    dragStart = g.startLocation
                    if let r = state.rect {
                        resizeHandle = AreaGeometry.Handle.allCases.first {
                            let p = AreaGeometry.handlePoint($0, in: r)
                            return hypot(p.x - g.startLocation.x, p.y - g.startLocation.y) < 10
                        }
                        if resizeHandle == nil, r.contains(g.startLocation) { moveOrigin = r }
                    }
                }
                let bounds = state.displaySize
                if let h = resizeHandle, let r = state.rect {
                    actions.setRect(AreaGeometry.resized(r, handle: h, to: g.location, bounds: bounds, keepRatio: flags.contains(.shift)))
                } else if let origin = moveOrigin {
                    actions.setRect(AreaGeometry.moved(origin, by: g.translation, bounds: bounds))
                } else if let start = dragStart {
                    actions.setRect(AreaGeometry.drawn(from: start, to: g.location, bounds: bounds,
                                                       keepRatio: flags.contains(.shift) ? 1 : nil,
                                                       snap169: flags.contains(.command)))
                }
            }
            .onEnded { _ in dragStart = nil; moveOrigin = nil; resizeHandle = nil }
    }
}

// MARK: - Corner brackets during an area take (design.md §11.3, never recorded)

public struct CornerBracketsView: View {
    var size: CGSize
    public init(size: CGSize) { self.size = size }

    public var body: some View {
        Canvas { ctx, s in
            let arm: CGFloat = min(22, min(s.width, s.height) / 4)
            let i: CGFloat = 1.5
            var p = Path()
            // top-left, top-right, bottom-right, bottom-left
            p.move(to: CGPoint(x: i, y: i + arm)); p.addLine(to: CGPoint(x: i, y: i)); p.addLine(to: CGPoint(x: i + arm, y: i))
            p.move(to: CGPoint(x: s.width - i - arm, y: i)); p.addLine(to: CGPoint(x: s.width - i, y: i)); p.addLine(to: CGPoint(x: s.width - i, y: i + arm))
            p.move(to: CGPoint(x: s.width - i, y: s.height - i - arm)); p.addLine(to: CGPoint(x: s.width - i, y: s.height - i)); p.addLine(to: CGPoint(x: s.width - i - arm, y: s.height - i))
            p.move(to: CGPoint(x: i + arm, y: s.height - i)); p.addLine(to: CGPoint(x: i, y: s.height - i)); p.addLine(to: CGPoint(x: i, y: s.height - i - arm))
            ctx.stroke(p, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
