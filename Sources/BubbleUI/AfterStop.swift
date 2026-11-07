// Owner: app/UI track. What happens once a take is saved (design.md v1 add-ons), in this order:
// (1) the file goes on the clipboard as a file URL (⌘V in Slack, Mail or Finder pastes the video),
// (2) a Finder window opens on the folder with the file selected,
// (3) the file opens in the default player, in front.
import AppKit
import os

@MainActor
public enum AfterStop {
    private nonisolated static let log = Logger(subsystem: "local.bubble.Bubble", category: "AfterStop")

    public static func copyToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func openInPlayer(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error { log.error("open \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// The three steps. `open: false` skips the player (the take stopped on its own, or on quit).
    public static func perform(_ url: URL, open: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.error("after stop: no file at \(url.path, privacy: .public)")
            return
        }
        copyToClipboard(url)
        revealInFinder(url)
        if open {
            // Let Finder come up first so the player ends up in front of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { openInPlayer(url) }
        }
    }
}
