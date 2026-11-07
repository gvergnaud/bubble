// Owner: app/UI track. The Settings window's one pane (design.md §6.6). v1 shows the shortcuts
// read-only (editing is later), with "In use by another app" when macOS refused one.
import SwiftUI

public struct SettingsState: Sendable, Equatable {
    public var shortcuts: [(action: HotkeyAction, inUse: Bool)]
    public var folderPath: String
    public var countdown: Bool
    public var mirror: Bool
    public var highlightClicks: Bool
    public var openAtLogin: Bool

    public init(hotkeysInUse: Set<HotkeyAction> = [], folderPath: String, countdown: Bool = true, mirror: Bool = true,
                highlightClicks: Bool = true, openAtLogin: Bool = false) {
        shortcuts = HotkeyAction.allCases.map { ($0, hotkeysInUse.contains($0)) }
        self.folderPath = folderPath; self.countdown = countdown; self.mirror = mirror
        self.highlightClicks = highlightClicks; self.openAtLogin = openAtLogin
    }

    public static func == (a: SettingsState, b: SettingsState) -> Bool {
        a.shortcuts.map(\.action) == b.shortcuts.map(\.action) && a.shortcuts.map(\.inUse) == b.shortcuts.map(\.inUse)
            && a.folderPath == b.folderPath && a.countdown == b.countdown && a.mirror == b.mirror
            && a.highlightClicks == b.highlightClicks && a.openAtLogin == b.openAtLogin
    }
}

public struct SettingsActions {
    public var changeFolder: @MainActor @Sendable () -> Void = {}
    public var showFolder: @MainActor @Sendable () -> Void = {}
    public var setCountdown: @MainActor @Sendable (Bool) -> Void = { _ in }
    public var setMirror: @MainActor @Sendable (Bool) -> Void = { _ in }
    public var setHighlightClicks: @MainActor @Sendable (Bool) -> Void = { _ in }
    public var setOpenAtLogin: @MainActor @Sendable (Bool) -> Void = { _ in }
    public init() {}
}

public struct SettingsView: View {
    var state: SettingsState
    var actions: SettingsActions

    public init(state: SettingsState, actions: SettingsActions = .init()) {
        self.state = state; self.actions = actions
    }

    public static let width: CGFloat = 480

    // A grouped look like System Settings, laid out by hand: Form(.grouped) scrolls and has no
    // stable fitting size, so the window and the snapshot would not match.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Keyboard shortcuts", footer: "Discard: press it twice within 3 seconds.") {
                ForEach(Array(state.shortcuts.enumerated()), id: \.offset) { i, item in
                    if i > 0 { RowDivider() }
                    // v1 shows the fixed shortcuts; editing them is later (architecture.md §2).
                    SettingsRow(item.action.title,
                                subtitle: item.inUse ? "In use by another app. Use the menu bar item instead." : nil) {
                        KeyCaps(item.action.shortcut)
                            .opacity(item.inUse ? 0.45 : 1)
                            .help(item.inUse ? "Another app already uses \(item.action.shortcut)"
                                             : "\(item.action.title): \(item.action.shortcut)")
                    }
                }
            }

            SettingsSection("Recordings") {
                SettingsRow("Save recordings to") {
                    HStack(spacing: 8) {
                        Button(action: actions.showFolder) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                                Text(state.folderPath).lineLimit(1).truncationMode(.middle)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                        Button("Change…", action: actions.changeFolder)
                    }
                }
                RowDivider()
                SettingsToggle("Countdown before recording (3 s)", isOn: bind(state.countdown, actions.setCountdown))
                RowDivider()
                SettingsToggle("Highlight clicks", isOn: bind(state.highlightClicks, actions.setHighlightClicks))
            }

            SettingsSection("Camera") {
                SettingsToggle("Mirror my camera", isOn: bind(state.mirror, actions.setMirror))
            }

            SettingsSection(nil) {
                SettingsToggle("Open at login", isOn: bind(state.openAtLogin, actions.setOpenAtLogin))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: Self.width)
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String?, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 10)
            }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
        }
        .padding(.top, 14)
    }
}

private struct SettingsRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing()
    }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, subtitle == nil ? 0 : 6)
        .frame(minHeight: 38)
    }
}

private struct SettingsToggle: View {
    var title: String
    var isOn: Binding<Bool>
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; self.isOn = isOn }
    var body: some View {
        SettingsRow(title) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

private struct RowDivider: View {
    var body: some View { Divider().opacity(0.7) }
}
