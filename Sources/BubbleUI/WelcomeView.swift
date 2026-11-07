// Owner: app/UI track. The Welcome window's content (design.md §5.1): the 3 permissions.
// Plain values in, callbacks out: QA renders every state offscreen.
import BubbleCore
import SwiftUI

public struct WelcomeState: Sendable, Equatable {
    public var screen: PermissionStatus
    public var camera: PermissionStatus
    public var microphone: PermissionStatus
    public var shortcut: String

    public init(screen: PermissionStatus, camera: PermissionStatus, microphone: PermissionStatus, shortcut: String = "⌥⇧L") {
        self.screen = screen; self.camera = camera; self.microphone = microphone; self.shortcut = shortcut
    }

    public func status(_ p: Permission) -> PermissionStatus {
        switch p {
        case .screen: screen
        case .camera: camera
        case .microphone: microphone
        }
    }

    public enum MainButton: Equatable { case relaunch, done, waitingForScreen }

    public var mainButton: MainButton {
        switch screen {
        // .denied = the user was sent to System Settings in this run. macOS may keep saying "no"
        // until a relaunch even after the switch is on, so Relaunch is offered from then on.
        case .needsRelaunch, .denied: .relaunch
        case .granted: .done
        case .notDetermined: .waitingForScreen
        }
    }

    public var allGranted: Bool { screen == .granted && camera == .granted && microphone == .granted }
}

public struct WelcomeView: View {
    var state: WelcomeState
    var onAction: (Permission) -> Void
    var onFinish: () -> Void

    var icon: NSImage?

    /// `icon`: the app icon (NSApplication.shared.applicationIconImage in the app, the .icns in snapshots).
    public init(state: WelcomeState, icon: NSImage? = nil, onAction: @escaping (Permission) -> Void = { _ in },
                onFinish: @escaping () -> Void = {}) {
        self.state = state; self.icon = icon; self.onAction = onAction; self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 56, height: 56)
                        .padding(-6) // the icon artwork has its own margin
                } else {
                    AppGlyph(size: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Bubble")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Record your screen and your face. Files stay on this Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 22)

            VStack(spacing: 0) {
                row(.screen, title: "Screen Recording", purpose: "to see your screen")
                Divider().padding(.horizontal, 12)
                row(.camera, title: "Camera", purpose: "for the bubble")
                Divider().padding(.horizontal, 12)
                row(.microphone, title: "Microphone", purpose: "for your voice")
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    if state.allGranted {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Bubble lives in the menu bar.")
                        }
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("Start and stop anytime with")
                            .foregroundStyle(.secondary)
                        KeyCaps(state.shortcut)
                    }
                }
                .fixedSize()
                Spacer(minLength: 16)
                mainButton
            }
            .font(.system(size: 13))
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder private var mainButton: some View {
        switch state.mainButton {
        case .relaunch:
            Button("Relaunch Bubble", action: onFinish)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        case .done:
            Button("Done", action: onFinish)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        case .waitingForScreen:
            Button("Done", action: onFinish)
                .controlSize(.large)
                .disabled(true)
                .help("Turn on Screen Recording first")
        }
    }

    private func row(_ p: Permission, title: String, purpose: String) -> some View {
        let status = state.status(p)
        return HStack(spacing: 12) {
            StatusDot(status: status, permission: p)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail(p, status, purpose: purpose))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            rowButton(p, status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private func detail(_ p: Permission, _ status: PermissionStatus, purpose: String) -> String {
        switch (p, status) {
        case (_, .granted): "Allowed"
        case (_, .needsRelaunch): "Relaunch to finish"
        case (.screen, .notDetermined): "Needed to record. Open Settings and switch on Bubble."
        case (.screen, .denied): "Switch on Bubble in Screen & System Audio Recording, then relaunch."
        case (_, .notDetermined): purpose
        case (.camera, .denied): "Optional. Switch on Bubble in Privacy & Security › Camera."
        case (_, .denied): "Optional. Switch on Bubble in Privacy & Security › Microphone."
        }
    }

    @ViewBuilder private func rowButton(_ p: Permission, _ status: PermissionStatus) -> some View {
        switch status {
        case .needsRelaunch:
            // Not finished: no check. The main button says Relaunch Bubble.
            EmptyView()
        case .granted:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .frame(minWidth: 24)
        case .notDetermined where p == .screen:
            // The first thing to do: the one prominent button until Screen Recording is asked.
            Button("Open Settings") { onAction(p) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Opens System Settings › Privacy & Security › Screen & System Audio Recording")
        case .notDetermined:
            Button("Allow") { onAction(p) }
        case .denied:
            Button("Open Settings") { onAction(p) }
                .help("Opens System Settings › Privacy & Security › \(p == .screen ? "Screen & System Audio Recording" : p == .camera ? "Camera" : "Microphone")")
        }
    }
}

/// ● grey = not asked · green = allowed · red = denied · orange = relaunch to finish.
struct StatusDot: View {
    var status: PermissionStatus
    var permission: Permission = .camera
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
    }
    private var color: Color {
        switch status {
        case .notDetermined: Color.gray.opacity(0.55)
        case .granted: .green
        case .needsRelaunch: .orange
        // Screen Recording "denied" = sent to Settings, switch maybe not on yet: a step, not a refusal.
        case .denied: permission == .screen ? .orange : .red
        }
    }
}

/// "⌥⇧L" drawn as key caps.
public struct KeyCaps: View {
    var keys: [String]
    public init(_ shortcut: String) { keys = shortcut.map(String.init) }
    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
        }
        .accessibilityLabel(Text("Option Shift \(keys.last ?? "")"))
    }
}

/// The app's mark: a rounded screen with a round bubble in its bottom-left corner.
public struct AppGlyph: View {
    var size: CGFloat
    public init(size: CGFloat) { self.size = size }
    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.55, green: 0.33, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .fill(.white)
                .frame(width: size * 0.36, height: size * 0.36)
                .shadow(color: .black.opacity(0.2), radius: size * 0.03, y: size * 0.01)
                .padding(size * 0.15)
        }
        .frame(width: size, height: size)
    }
}
