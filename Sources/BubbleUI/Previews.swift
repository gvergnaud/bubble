// Owner: app/UI track. Every v1 screen and state as plain sample values, for QA's snapshot catalog
// (docs/architecture.md §8.1) and the designer's review. No device, timer or NSApp access.
import AppKit
import BubbleCore
import SwiftUI

public struct SnapshotEntry: Identifiable {
    public var id: String
    public var view: AnyView
    /// Draw on a busy "desktop" so translucent pieces (bubble, countdown, hover controls) read as on screen.
    public var onDesktop: Bool
}

@MainActor
public enum SnapshotCatalog {
    static let builtIn = DisplayInfo(id: 1, name: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
    static let studio = DisplayInfo(id: 2, name: "Studio Display", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), scale: 2)
    static let faceTime = DeviceInfo(id: "cam-facetime", name: "FaceTime HD Camera")
    static let iPhone = DeviceInfo(id: "cam-iphone", name: "Gabriel’s iPhone Camera")
    static let mic = DeviceInfo(id: "mic-builtin", name: "MacBook Pro Microphone")
    static let airPods = DeviceInfo(id: "mic-airpods", name: "AirPods Pro")

    static func panel(cameraAccess: Access = .granted, micAccess: Access = .granted, cameras: [DeviceInfo]? = nil,
                      selectedCamera: String?? = nil, computerSound: Bool = false, twoDisplays: Bool = false) -> RecorderPanelState {
        let cams = cameras ?? [faceTime, iPhone]
        return RecorderPanelState(
            cameras: cams, selectedCameraID: selectedCamera ?? cams.first?.id, cameraAccess: cameraAccess,
            microphones: [mic, airPods], selectedMicrophoneID: mic.id, microphoneAccess: micAccess,
            computerSound: computerSound, displays: twoDisplays ? [builtIn, studio] : [], selectedDisplayID: 1)
    }

    /// `face`: the bubble's placeholder image (SyntheticFrames.placeholderFace in BubbleTesting).
    public static func entries(face: CGImage) -> [SnapshotEntry] {
        var e: [SnapshotEntry] = []
        func add(_ id: String, desktop: Bool = false, _ v: some View) { e.append(SnapshotEntry(id: id, view: AnyView(v), onDesktop: desktop)) }

        // Recorder panel
        add("panel-1-display", RecorderPanelView(state: panel()))
        add("panel-2-displays", RecorderPanelView(state: panel(twoDisplays: true)))
        add("panel-camera-blocked", RecorderPanelView(state: panel(cameraAccess: .blocked)))
        add("panel-mic-blocked", RecorderPanelView(state: panel(micAccess: .blocked)))
        add("panel-not-asked", RecorderPanelView(state: panel(cameraAccess: .notAsked, micAccess: .notAsked)))
        add("panel-no-camera-chosen", RecorderPanelView(state: panel(selectedCamera: .some(nil))))
        add("panel-no-camera-found", RecorderPanelView(state: panel(cameras: [])))
        add("panel-computer-sound-on", RecorderPanelView(state: panel(computerSound: true)))

        // Bubble
        for size in BubbleSize.allCases {
            add("bubble-\(size.letter)", desktop: true, BubbleView(content: .image(face), diameter: size.diameter))
        }
        add("bubble-M-hover", desktop: true, ZStack {
            BubbleView(content: .image(face), diameter: 180)
            BubbleHoverControlsView(diameter: 180, size: .medium)
        })
        add("bubble-S-hover", desktop: true, ZStack {
            BubbleView(content: .image(face), diameter: 120)
            BubbleHoverControlsView(diameter: 120, size: .small)
        })
        add("bubble-M-waiting", desktop: true, BubbleView(content: .waiting, diameter: 180))
        add("bubble-M-paused", desktop: true, BubbleView(content: .image(face), diameter: 180, dimmed: true))
        add("bubble-M-not-mirrored", desktop: true, BubbleView(content: .image(face), diameter: 180, mirrored: false))

        // Countdown
        for d in [3, 2, 1] { add("countdown-\(d)", desktop: true, CountdownView(digit: d)) }
        add("countdown-resume-2", desktop: true, CountdownView(digit: 2, resuming: true))

        // Menu bar label
        add("menubar-idle", MenuBarLabelView(label: .idle(attention: false)))
        add("menubar-attention", MenuBarLabelView(label: .idle(attention: true)))
        add("menubar-recording", MenuBarLabelView(label: .recording(time: "03:12", lowDisk: false)))
        add("menubar-recording-hour", MenuBarLabelView(label: .recording(time: "1:02:03", lowDisk: false)))
        add("menubar-recording-low-disk", MenuBarLabelView(label: .recording(time: "48:10", lowDisk: true)))
        add("menubar-paused", MenuBarLabelView(label: .paused(time: "03:12")))
        add("menubar-saving", MenuBarLabelView(label: .saving))

        // Welcome
        add("welcome-all-grey", WelcomeView(state: WelcomeState(screen: .notDetermined, camera: .notDetermined, microphone: .notDetermined)))
        add("welcome-mixed", WelcomeView(state: WelcomeState(screen: .notDetermined, camera: .granted, microphone: .denied)))
        add("welcome-needs-relaunch", WelcomeView(state: WelcomeState(screen: .needsRelaunch, camera: .granted, microphone: .notDetermined)))
        add("welcome-screen-denied", WelcomeView(state: WelcomeState(screen: .denied, camera: .granted, microphone: .granted)))
        add("welcome-all-green", WelcomeView(state: WelcomeState(screen: .granted, camera: .granted, microphone: .granted)))

        // Settings
        add("settings", SettingsView(state: SettingsState(folderPath: "~/Movies/Bubble")))
        add("settings-shortcut-in-use", SettingsView(state: SettingsState(hotkeysInUse: [.pauseResume], folderPath: "~/Movies/Bubble",
                                                                          openAtLogin: true)))

        // Messages (toasts)
        add("toast-discard-hint", ToastView(toast: Toast(.discard, "Press ⌥⇧C again to discard")))
        add("toast-mic-switched", ToastView(toast: Toast(.mic, "Now using MacBook Pro Microphone")))
        add("toast-camera-disconnected", ToastView(toast: Toast(.camera, "Camera disconnected")))
        add("toast-no-video", ToastView(toast: Toast(.camera, "No video from FaceTime HD Camera")))
        add("toast-low-disk", ToastView(toast: Toast(.disk, "2 GB left, about 14 min")))
        add("toast-computer-sound-lost", ToastView(toast: Toast(.speaker, "Computer sound stopped. Recording goes on with the mic.")))
        return e
    }

    /// The alerts, for AlertPresenter.make (rendered as real NSAlerts).
    public static var alerts: [(id: String, alert: AppAlert)] {
        let url = URL(fileURLWithPath: "/Users/me/Movies/Bubble/Bubble 2026-11-06 at 14.22.05.mp4")
        func stopped(_ r: StopReason) -> AppAlert {
            Messages.stoppedOnItsOwn(RecordingResult(url: url, duration: 252, bytes: 186_000_000, reason: r))!
        }
        return [
            ("alert-discard", Messages.discardConfirm),
            ("alert-quit-while-recording", Messages.quitWhileRecording),
            ("alert-not-enough-space", Messages.notEnoughSpace(bytesFree: 600_000_000, folder: URL(fileURLWithPath: "/"))),
            ("alert-display-disconnected", stopped(.displayDisconnected)),
            ("alert-disk-full", stopped(.diskAlmostFull)),
            ("alert-screen-permission-revoked", stopped(.screenPermissionRevoked)),
            ("alert-writer-failed", stopped(.failed("The encoder stopped (error -11800)."))),
        ]
    }

    /// A busy, light "desktop" behind the floating pieces.
    public static func desktop<V: View>(_ content: V) -> some View {
        content
            .padding(24)
            .background(
                LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 0.99), Color(red: 0.80, green: 0.86, blue: 0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(0..<14, id: \.self) { i in
                                Text("func record(_ screen: Display) -> URL { // line \(i) of a document on screen")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.55))
                            }
                        }
                        .padding(12)
                    }
                    .clipped()
            )
    }
}
