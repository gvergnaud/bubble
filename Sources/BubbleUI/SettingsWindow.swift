// Owner: app/UI track. Hosts SettingsView in a small titled window; reads and writes Settings.
import AppKit
import BubbleCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var host: NSHostingView<SettingsView>?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: view())
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Bubble Settings"
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            self.host = host
            trackChanges { [weak self] in
                guard let self, let host = self.host else { return }
                host.rootView = self.view()
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        host = nil
    }

    private func view() -> SettingsView {
        let s = model.settings
        let state = SettingsState(hotkeysInUse: model.hotkeysInUse, folderPath: (s.folder.path as NSString).abbreviatingWithTildeInPath,
                                  countdown: s.countdownEnabled, mirror: s.mirrorCamera,
                                  highlightClicks: s.highlightClicks, openAtLogin: s.openAtLogin)
        var actions = SettingsActions()
        actions.setCountdown = { [weak self] in self?.model.settings.countdownEnabled = $0 }
        actions.setMirror = { [weak self] in self?.model.setMirror($0) }
        actions.setHighlightClicks = { [weak self] in self?.model.settings.highlightClicks = $0 }
        actions.setOpenAtLogin = { [weak self] in self?.model.setOpenAtLogin($0) }
        actions.showFolder = { [weak self] in
            guard let self else { return }
            self.model.effects.openFolder(self.model.settings.folder)
        }
        actions.changeFolder = { [weak self] in self?.chooseFolder() }
        return SettingsView(state: state, actions: actions)
    }

    private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Bubble saves new recordings in this folder."
        panel.directoryURL = model.settings.folder
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.model.settings.folder = url
            }
        }
    }
}
