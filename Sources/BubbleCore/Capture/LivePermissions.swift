// Screen, camera and mic permissions. Owner: capture track. Spec: docs/architecture.md §4.
// Main actor. status() never prompts.

import AppKit
import AVFoundation
import CoreGraphics

@MainActor
public final class LivePermissions: PermissionsProviding {
    /// Screen recording was not granted when the app launched: macOS applies a later grant only
    /// after a relaunch, and CGPreflightScreenCaptureAccess keeps saying no until then.
    private let screenGrantedAtLaunch: Bool
    private var screenRequested = false

    public init() {
        screenGrantedAtLaunch = CGPreflightScreenCaptureAccess()
    }

    public func status(_ permission: Permission) -> PermissionStatus {
        switch permission {
        case .screen:
            return Self.screenStatus(preflight: CGPreflightScreenCaptureAccess(),
                                     grantedAtLaunch: screenGrantedAtLaunch, requested: screenRequested)
        case .camera: return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        }
    }

    public func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .screen:
            screenRequested = true
            // Registers the app in System Settings › Privacy & Security › Screen & System Audio
            // Recording (and shows the system prompt the first time), then opens that pane.
            if !CGRequestScreenCaptureAccess() { openSystemSettings(.screen) }
            return status(.screen)
        case .camera, .microphone:
            let type: AVMediaType = permission == .camera ? .video : .audio
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .notDetermined:
                _ = await AVCaptureDevice.requestAccess(for: type)
            case .denied, .restricted:
                openSystemSettings(permission)
            default:
                break
            }
            return status(permission)
        }
    }

    public func openSystemSettings(_ permission: Permission) {
        let anchor = switch permission {
        case .screen: "Privacy_ScreenCapture"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    public func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// The Screen Recording state from what the process can see, without prompting.
    /// - `preflight`: CGPreflightScreenCaptureAccess() now.
    /// - `grantedAtLaunch`: the same call when the app started.
    /// - `requested`: the user was sent to System Settings in this run.
    /// `.needsRelaunch` only when the grant is really there (preflight says yes) but came after launch.
    /// No guessing from other apps' window names: macOS 26 shows some of them without the grant
    /// (menu bar extras, Control Center), which made a fresh install with no grant loop on
    /// "Relaunch to finish". If the switch was turned on but preflight still says no, the Welcome
    /// window offers Relaunch anyway once the user has been to System Settings.
    public nonisolated static func screenStatus(preflight: Bool, grantedAtLaunch: Bool, requested: Bool) -> PermissionStatus {
        if preflight { return grantedAtLaunch ? .granted : .needsRelaunch }
        return requested ? .denied : .notDetermined
    }
}
