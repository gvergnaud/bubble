// Owner: app/UI track. The menu bar item's menus as data (titles, shortcuts, enabled flags), so tests
// check them without AppKit. StatusItemController turns them into NSMenus.
import Foundation

public enum MenuAction: String, Sendable, Equatable {
    case stop, pause, resume, hideCamera, showCamera, discard
    case startNow, cancelCountdown
    case startRecording, showRecorder, recordings
    /// Record Full Screen / Record Window… / Record Area… (design.md §11.6).
    case recordFullScreen, recordLastWindow, recordWindow, recordArea
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
    /// What the record items depend on (design.md §11.6).
    public struct RecordContext: Sendable, Equatable {
        public var lastSource: SourceKind
        /// The last-used window's app, while that window is still open ("Record Safari").
        public var openWindowApp: String?
        public var windowAvailable: Bool
        /// An area is saved for the display with the mouse ("Record Area" starts at once).
        public var areaSaved: Bool
        public init(lastSource: SourceKind = .fullScreen, openWindowApp: String? = nil, windowAvailable: Bool = true,
                    areaSaved: Bool = false) {
            self.lastSource = lastSource; self.openWindowApp = openWindowApp
            self.windowAvailable = windowAvailable; self.areaSaved = areaSaved
        }
    }

    /// The ways to start (design.md §11.6). "…" = the picker or overlay comes first, no "…" = it
    /// starts at once. ⌥⇧L sits on the item that does exactly what ⌥⇧L does.
    public static func recordItems(_ c: RecordContext) -> [MenuEntry] {
        let key = HotkeyAction.startStop.shortcut
        var items: [MenuEntry] = [
            .item(title: "Record Full Screen", shortcut: c.lastSource == .fullScreen ? key : nil, action: .recordFullScreen, enabled: true),
        ]
        if c.windowAvailable {
            if let app = c.openWindowApp {
                items.append(.item(title: "Record \(app)", shortcut: c.lastSource == .window ? key : nil,
                                   action: .recordLastWindow, enabled: true))
            }
            let windowKey = c.lastSource == .window && c.openWindowApp == nil ? key : nil
            items.append(.item(title: "Record Window…", shortcut: windowKey, action: .recordWindow, enabled: true))
        }
        items.append(.item(title: c.areaSaved ? "Record Area" : "Record Area…", shortcut: c.lastSource == .area ? key : nil,
                           action: .recordArea, enabled: true))
        return items
    }

    /// The menu for `phase`. Idle and Ready get the app menu (right-click); a take gets the take menu
    /// (design.md v1 scope note, "v1 menu bar menu while recording").
    /// `recordingApp`: a window take's app ("Recording Safari" heads the take menu, design.md §11.5).
    public static func menu(phase: Phase, cameraAvailable: Bool, cameraHidden: Bool, hasLastRecording: Bool,
                            recordingApp: String? = nil, record: RecordContext = RecordContext()) -> [MenuEntry] {
        switch phase {
        case .idle, .ready:
            return recordItems(record) + [
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
