// Owner: app/UI track. The Welcome window (design.md §5.1): a regular titled window, shown on first
// launch and when Start needs Screen Recording. Polls the permission states once a second while
// open (macOS sends no notification when the user flips a switch in System Settings).
import AppKit
import BubbleCore
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var host: NSHostingView<WelcomeView>?
    private var poll: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
        trackChanges { [weak self] in self?.apply() }
    }

    private func apply() {
        guard model.welcomeOpen else { close(); return }
        _ = model.devicesVersion // re-render when permissions change
        let view = WelcomeView(state: model.welcome, icon: NSApplication.shared.applicationIconImage,
                               onAction: { [weak self] p in self?.model.welcomeAction(p) },
                               onFinish: { [weak self] in self?.model.welcomeFinish() })
        if let host {
            host.rootView = view
            return
        }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Bubble"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.host = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.permissionsMayHaveChanged() }
        }
    }

    private func close() {
        poll?.invalidate(); poll = nil
        window?.delegate = nil
        window?.close()
        window = nil
        host = nil
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate(); poll = nil
        window = nil
        host = nil
        model.welcomeClosed()
    }
}
