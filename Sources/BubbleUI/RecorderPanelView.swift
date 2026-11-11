// Owner: app/UI track. The Recorder panel (design.md §6.2), shown in a popover under the menu bar
// item: Camera, Mic, Computer sound, Display (2+ displays only), Start Recording, the shortcut hint,
// and a footer with the folder and Settings. 280 pt wide.
import BubbleCore
import SwiftUI

public struct RecorderPanelActions {
    public var selectCamera: @MainActor @Sendable (String?) -> Void = { _ in }
    public var selectMicrophone: @MainActor @Sendable (String?) -> Void = { _ in }
    public var setComputerSound: @MainActor @Sendable (Bool) -> Void = { _ in }
    public var selectDisplay: @MainActor @Sendable (CGDirectDisplayID) -> Void = { _ in }
    public var requestAccess: @MainActor @Sendable (Permission) -> Void = { _ in }
    public var openSystemSettings: @MainActor @Sendable (Permission) -> Void = { _ in }
    public var start: @MainActor @Sendable () -> Void = {}
    public var openFolder: @MainActor @Sendable () -> Void = {}
    public var openSettings: @MainActor @Sendable () -> Void = {}
    public var quit: @MainActor @Sendable () -> Void = {}
    public var source = SourceActions()
    public init() {}
}

public struct RecorderPanelView: View {
    var state: RecorderPanelState
    var actions: RecorderPanelActions

    public static let width: CGFloat = 320

    public init(state: RecorderPanelState, actions: RecorderPanelActions = .init()) {
        self.state = state; self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceSection(state: state.source, windowAvailable: state.windowSourceAvailable, actions: actions.source)
                .padding(.bottom, 12)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    rowLabel("Camera", systemImage: "video")
                    cameraControl
                }
                GridRow {
                    rowLabel("Mic", systemImage: "mic")
                    micControl
                }
                if !state.displays.isEmpty {
                    GridRow {
                        rowLabel("Display", systemImage: "display")
                        displayControl
                    }
                }
            }

            HStack {
                Label {
                    Text("Computer sound")
                } icon: {
                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                .labelStyle(PanelLabelStyle())
                Spacer()
                Toggle("Computer sound", isOn: bind(state.computerSound, actions.setComputerSound))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Also record what your Mac plays. Off by default: with speakers, the mic hears it twice.")
            }
            .padding(.top, 12)

            Button(action: actions.start) {
                HStack(spacing: 8) {
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                    Text("Start Recording")
                }
            }
            .buttonStyle(StartButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.top, 16)

            HStack(spacing: 4) {
                Text("or press")
                KeyCaps(state.shortcut).scaleEffect(0.9)
                Text("from anywhere")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            Divider().padding(.top, 14).padding(.horizontal, -14)

            HStack(spacing: 2) {
                FooterButton(title: "Recordings", systemImage: "film.stack", help: "Recordings (⌘0)", action: actions.openFolder)
                FooterButton(title: "Settings", systemImage: "gearshape", help: "Settings… (⌘,)", action: actions.openSettings)
                Spacer()
                FooterButton(title: nil, systemImage: "power", help: "Quit Bubble", action: actions.quit)
            }
            .padding(.top, 6)
            .padding(.horizontal, -6)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(width: Self.width)
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
        .labelStyle(PanelLabelStyle())
        .gridColumnAlignment(.leading)
    }

    @ViewBuilder private var cameraControl: some View {
        switch state.cameraAccess {
        case .blocked:
            BlockedControl(text: "Blocked") { actions.openSystemSettings(.camera) }
        case .notAsked:
            Button("Allow Camera…") { actions.requestAccess(.camera) }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .granted:
            if state.cameras.isEmpty {
                Text("No camera found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                PopupPicker(title: state.cameras.first { $0.id == state.selectedCameraID }?.name ?? "No Camera",
                            selection: bind(state.selectedCameraID, actions.selectCamera)) {
                    ForEach(state.cameras) { Text($0.name).tag(Optional($0.id)) }
                    Divider()
                    Text("No Camera").tag(String?.none)
                }
            }
        }
    }

    @ViewBuilder private var micControl: some View {
        switch state.microphoneAccess {
        case .blocked:
            BlockedControl(text: "Blocked") { actions.openSystemSettings(.microphone) }
        case .notAsked:
            Button("Allow Microphone…") { actions.requestAccess(.microphone) }
                .frame(maxWidth: .infinity, alignment: .leading)
        case .granted:
            if state.microphones.isEmpty {
                Text("No microphone found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                PopupPicker(title: state.microphones.first { $0.id == state.selectedMicrophoneID }?.name ?? "No Microphone",
                            selection: bind(state.selectedMicrophoneID, actions.selectMicrophone)) {
                    ForEach(state.microphones) { Text($0.name).tag(Optional($0.id)) }
                    Divider()
                    Text("No Microphone").tag(String?.none)
                }
            }
        }
    }

    private var displayControl: some View {
        PopupPicker(title: state.displays.first { $0.id == state.selectedDisplayID }?.name ?? "",
                    selection: bind(state.selectedDisplayID ?? 0, actions.selectDisplay)) {
            ForEach(state.displays) { Text($0.name).tag($0.id) }
        }
    }
}

/// A popup button whose title is leading-aligned and truncates in the middle ("MacBook Pro … Microphone"),
/// which the native popup does not do. The menu is a native one with a checkmark on the selection.
struct PopupPicker<Value: Hashable, Items: View>: View {
    var title: String
    var selection: Binding<Value>
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            Picker(title, selection: selection) { items }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .help(title)
    }
}

/// "Camera blocked · Open Settings" (design.md §7.1).
private struct BlockedControl: View {
    var text: String
    var open: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 11))
            Text(text)
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Button("Open Settings", action: open)
                .buttonStyle(.link)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PanelLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
        .font(.system(size: 13))
    }
}

/// The one colored button of the panel.
struct StartButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.92, green: 0.23, blue: 0.21))
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct FooterButton: View {
    var title: String?
    var systemImage: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if let title { Text(title) }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
