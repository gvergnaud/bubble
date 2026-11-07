// Owner: app/UI track. Alerts: "Discard this recording? It goes to the Trash." [Discard] [Keep Recording],
// the quit dialog, disk and stop messages. A menu bar app has no window to attach a sheet to, so
// the alert is app-modal; Bubble comes to the front for it, then gives the focus back.
import AppKit

@MainActor
public enum AlertPresenter {
    /// Shows `alert` and returns the index of the button pressed (0 = default, Return).
    public static func run(_ alert: AppAlert) -> Int {
        let previous = NSWorkspace.shared.frontmostApplication
        let a = make(alert)
        NSApplication.shared.activate()
        a.window.level = .modalPanel
        let response = a.runModal()
        if let previous, previous != NSRunningApplication.current { previous.activate() }
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// The NSAlert for `alert`, not shown (QA lays it out offscreen for the snapshots).
    public static func make(_ alert: AppAlert, icon: NSImage? = nil) -> NSAlert {
        let a = NSAlert()
        a.messageText = alert.title
        a.informativeText = alert.message
        switch alert.style {
        case .informational: a.alertStyle = .informational
        case .warning: a.alertStyle = .warning
        case .critical: a.alertStyle = .critical
        }
        for (i, title) in alert.buttons.enumerated() {
            let b = a.addButton(withTitle: title)
            if i == 0, title == "Discard" { b.hasDestructiveAction = true }
            if i == 1 { b.keyEquivalent = "\u{1b}" } // Esc = the safe choice
        }
        if let icon = icon ?? NSApplication.shared.applicationIconImage { a.icon = icon }
        return a
    }
}
