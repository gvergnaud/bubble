// Owner: app/UI track. The menu bar item's menus as data (titles, shortcuts, enabled flags), so tests
// check them without AppKit. StatusItemController turns them into NSMenus.
import Foundation

public enum MenuAction: String, Sendable, Equatable {
    case stop, pause, resume, hideCamera, showCamera, discard
    case startNow, cancelCountdown
    case startRecording, showRecorder, recordings
    case showLastRecording, editLastRecording, openVideo, openFolder, settings, quit
}

public enum MenuEntry: Sendable, Equatable {
    case item(title: String, shortcut: String?, action: MenuAction, enabled: Bool)
    /// A grey line of text (e.g. "Saving…").
    case label(String)
    case separator

    public var title: String? {
        switch self {
        case .item(let t, _, _, _), .label(let t): t
        case .separator: nil
        }
    }
}

public enum MenuBuilder {
    /// The menu for `phase`. Idle and Ready get the app menu (right-click); a take gets the take menu
    /// (design.md v1 scope note, "v1 menu bar menu while recording").
    /// `recordingApp`: a window take's app ("Recording Safari" heads the take menu, design.md §11.5).
    public static func menu(phase: Phase, cameraAvailable: Bool, cameraHidden: Bool, hasLastRecording: Bool,
                            recordingApp: String? = nil) -> [MenuEntry] {
        switch phase {
        case .idle, .ready:
            return [
                .item(title: "Start Recording", shortcut: HotkeyAction.startStop.shortcut, action: .startRecording, enabled: true),
                .item(title: "Show Recorder", shortcut: nil, action: .showRecorder, enabled: true),
                .item(title: "Recordings", shortcut: "⌘0", action: .recordings, enabled: true),
                .separator,
                .item(title: "Show Last Recording in Finder", shortcut: nil, action: .showLastRecording, enabled: hasLastRecording),
                .item(title: "Edit Last Recording", shortcut: nil, action: .editLastRecording, enabled: hasLastRecording),
                .item(title: "Open Video…", shortcut: "⌘O", action: .openVideo, enabled: true),
                .item(title: "Open Recordings Folder", shortcut: nil, action: .openFolder, enabled: true),
                .separator,
                .item(title: "Settings…", shortcut: "⌘,", action: .settings, enabled: true),
                .separator,
                .item(title: "Quit Bubble", shortcut: "⌘Q", action: .quit, enabled: true),
            ]
        case .countdown:
            return [
                .item(title: "Start Now", shortcut: "↩", action: .startNow, enabled: true),
                .item(title: "Cancel", shortcut: "⎋", action: .cancelCountdown, enabled: true),
            ]
        case .starting:
            return [.label("Starting…")]
        case .recording, .paused, .resumeCountdown:
            let paused = phase != .recording
            var entries: [MenuEntry] = [
                .item(title: "Stop Recording", shortcut: HotkeyAction.startStop.shortcut, action: .stop, enabled: true),
                paused
                    ? .item(title: "Resume", shortcut: HotkeyAction.pauseResume.shortcut, action: .resume, enabled: phase == .paused)
                    : .item(title: "Pause", shortcut: HotkeyAction.pauseResume.shortcut, action: .pause, enabled: true),
            ]
            if cameraAvailable {
                entries.append(cameraHidden
                    ? .item(title: "Show Camera", shortcut: nil, action: .showCamera, enabled: true)
                    : .item(title: "Hide Camera", shortcut: nil, action: .hideCamera, enabled: true))
            }
            entries.append(.item(title: "Discard…", shortcut: HotkeyAction.discard.shortcut, action: .discard, enabled: true))
            if let recordingApp { entries.insert(.label("Recording \(recordingApp)"), at: 0) }
            return entries
        case .saving:
            return [.label("Saving…")]
        }
    }
}
