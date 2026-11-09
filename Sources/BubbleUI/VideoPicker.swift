// Owner: app/UI track. The open panel for "edit any video" (docs/editor-open-video.md §3 A, C):
// remembers the app in front (the browser), brings Bubble forward with an NSOpenPanel of movies,
// then gives the focus back. Starts in the folder of the last video picked (Movies the first time).
// One panel at a time: asking again brings it to the front. Refusals (mkv, VP9…) come back from the
// editor after the pick, with their reason; the panel greys nothing without saying why.
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class VideoPicker {
    public enum Purpose: Sendable, Equatable {
        /// File › Open Video…, the menu bar's Open Video…, the page's Open Video….
        case open
        /// The project's video is missing: "Where is <fileName>?".
        case locate(title: String, fileName: String)
    }

    private let defaults: UserDefaults
    private static let lastFolderKey = "videoPicker.lastFolder"
    private var panel: NSOpenPanel?

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isOpen: Bool { panel != nil }

    /// The panel's start folder: the last pick's folder if it still exists, else ~/Movies.
    public var startFolder: URL {
        if let path = defaults.string(forKey: Self.lastFolderKey),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies", directoryHint: .isDirectory)
    }

    /// The panel's title and message for a purpose (plain values, tested).
    public static func texts(_ purpose: Purpose) -> (title: String, message: String?, prompt: String) {
        switch purpose {
        case .open: ("Open Video", nil, "Open")
        case .locate(let title, let fileName): (title, "Where is \(fileName)?", "Choose")
        }
    }

    /// Shows the panel and returns the picked file, nil on cancel (or when a panel is already up:
    /// that one comes to the front). `giveFocusBack`: re-activate the app that was in front
    /// (the page's flows); File › Open Video… opens the browser right after, so it doesn't need it.
    public func pick(_ purpose: Purpose, giveFocusBack: Bool) async -> URL? {
        if panel != nil {
            bringToFront()
            return nil
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let panel = NSOpenPanel()
        let texts = Self.texts(purpose)
        panel.title = texts.title
        panel.message = texts.message ?? ""
        panel.prompt = texts.prompt
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = startFolder
        self.panel = panel
        AppLog.info("video panel: open (\(purpose == .open ? "open" : "locate"))")

        NSApp.activate()
        let response = await withCheckedContinuation { (done: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { done.resume(returning: $0) }
            panel.orderFrontRegardless()
        }
        self.panel = nil
        let url = response == .OK ? panel.url : nil
        if let url { defaults.set(url.deletingLastPathComponent().path, forKey: Self.lastFolderKey) }
        AppLog.info("video panel: \(url.map { "picked \($0.lastPathComponent)" } ?? "canceled")")
        if giveFocusBack, let previous, previous != NSRunningApplication.current {
            // Activation is cooperative (macOS 14+): without yielding first, the activate may be ignored.
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
        return url
    }

    /// The panel may be behind the browser, on another Space: bring it (and Bubble) forward.
    public func bringToFront() {
        guard let panel else { return }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}
