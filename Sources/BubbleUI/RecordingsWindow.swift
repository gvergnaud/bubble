// Owner: app/UI track. The Recordings window (design.md §10.3): lists the save folder live,
// loads durations and thumbnails in the background (cached), and acts on the selection
// (open, Show in Finder, copy, Move to Trash). Its window controller is in the responder chain,
// so File › Open / Show in Finder / Move to Trash and Edit › Copy act on the selected rows.
import AppKit
import AVFoundation
import BubbleCore
import Observation
import SwiftUI

@MainActor
@Observable
final class RecordingsStore {
    var state = RecordingsState(folderPath: "", items: [])
    var selection: Set<URL> = []
}

@MainActor
final class RecordingsWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let model: AppModel
    private let store = RecordingsStore()
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    /// Durations and thumbnails, by file URL + modification date.
    private var cache: [String: (duration: TimeInterval?, thumbnail: CGImage?, unreadable: Bool)] = [:]
    private var loading: Set<String> = []
    /// New Recording from this window hid it; it comes back after Stop.
    private var hiddenForTake = false
    /// The last app in front that was not Bubble: it gets the focus back for a take.
    private var lastOtherApp: NSRunningApplication?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Recordings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BubbleRecordings")
        if !window.setFrameUsingName("BubbleRecordings") { window.center() }
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: RecordingsRoot(store: store, actions: actions(), icon: NSApplication.shared.applicationIconImage))

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != NSRunningApplication.current { self?.lastOtherApp = app }
            }
        }
        // Folder changed in Settings, a take started or ended: list again.
        trackChanges { [weak self] in
            guard let self else { return }
            _ = self.model.settings.folder
            _ = self.model.settings.lastRecording
            _ = self.model.takeURL
            self.reload()
        }
        trackChanges { [weak self] in self?.followTake() }
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppLog.info("recordings window shown: \(store.state.items.count) items")
    }

    // MARK: Listing

    func reload() {
        let folder = model.settings.folder
        watch(folder)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let take = model.takeURL?.standardizedFileURL
        var items: [RecordingItem] = []
        for url in urls where ["mp4", "mov"].contains(url.pathExtension.lowercased()) && url.standardizedFileURL != take {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            let date = v?.creationDate ?? v?.contentModificationDate ?? .distantPast
            let key = "\(url.path)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            let cached = cache[key]
            items.append(RecordingItem(url: url, date: date, bytes: Int64(v?.fileSize ?? 0), duration: cached?.duration,
                                       thumbnail: cached?.thumbnail, unreadable: cached?.unreadable ?? false))
            if cached == nil { load(url, key: key) }
        }
        items.sort { $0.date > $1.date }
        store.state = RecordingsState(folderPath: (folder.path as NSString).abbreviatingWithTildeInPath, items: items, now: Date())
        store.selection = store.selection.intersection(Set(items.map(\.url)))
        pumpLoads()
    }

    /// Files waiting for their duration and thumbnail, in list order (newest first).
    private var pending: [(url: URL, key: String)] = []
    private var inFlight = 0
    /// A few at a time: a folder of 200 recordings must not open 200 decoders at once.
    private static let maxLoads = 3

    private func load(_ url: URL, key: String) {
        guard !loading.contains(key) else { return }
        loading.insert(key)
        pending.append((url, key))
    }

    private func pumpLoads() {
        // Newest first: follow the list's order.
        let order = Dictionary(uniqueKeysWithValues: store.state.items.enumerated().map { ($1.url, $0) })
        pending.sort { (order[$0.url] ?? .max) < (order[$1.url] ?? .max) }
        while inFlight < Self.maxLoads, !pending.isEmpty {
            let next = pending.removeFirst()
            inFlight += 1
            startLoad(next.url, key: next.key)
        }
    }

    private func startLoad(_ url: URL, key: String) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            var duration: TimeInterval?
            var image: CGImage?
            var unreadable = false
            do {
                let d = try await asset.load(.duration)
                duration = d.seconds.isFinite ? d.seconds : nil
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 192, height: 108)
                let at = CMTime(seconds: min(1, max(0, (duration ?? 1) / 2)), preferredTimescale: 600)
                image = try? await generator.image(at: at).image
            } catch {
                unreadable = true
            }
            guard let self else { return }
            self.loading.remove(key)
            self.inFlight -= 1
            self.pumpLoads()
            self.cache[key] = (duration, image, unreadable)
            if let i = self.store.state.items.firstIndex(where: { $0.url == url }) {
                self.store.state.items[i].duration = duration
                self.store.state.items[i].thumbnail = image
                self.store.state.items[i].unreadable = unreadable
            }
        }
    }

    /// Follows the folder: a file added, renamed, moved or trashed in Finder.
    private func watch(_ folder: URL) {
        guard folder != watchedFolder else { return }
        watcher?.cancel()
        watcher = nil
        watchedFolder = nil
        // The folder may not exist yet (no recording so far): the next reload tries again.
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFolder = folder
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                // The folder itself was renamed or deleted (and maybe recreated): the source
                // follows the old inode, so drop it; the reload below watches the path again.
                if let events = source?.data, !events.intersection([.rename, .delete]).isEmpty {
                    self?.watcher?.cancel()
                    self?.watcher = nil
                    self?.watchedFolder = nil
                }
                // A file being written fires many events: list again a moment later.
                NSObject.cancelPreviousPerformRequests(withTarget: self as Any, selector: #selector(RecordingsWindowController.reloadLater), object: nil)
                self?.perform(#selector(RecordingsWindowController.reloadLater), with: nil, afterDelay: 0.3)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    @objc private func reloadLater() { reload() }

    // MARK: Takes started from this window

    func newRecording() {
        guard model.phase == .idle || model.phase == .ready else { model.hotkey(.startStop); return }
        if window?.isVisible == true {
            hiddenForTake = true
            window?.orderOut(nil)
        }
        // Record the user's work, not Bubble.
        lastOtherApp?.activate()
        model.hotkey(.startStop)
    }

    private var lastPhase: Phase = .idle
    private func followTake() {
        let phase = model.phase
        defer { lastPhase = phase }
        guard hiddenForTake else { return }
        if phase == .idle, lastPhase != .idle {
            hiddenForTake = false
            reload()
            if let last = model.settings.lastRecording, store.state.items.contains(where: { $0.url == last }) {
                store.selection = [last]
            }
            // In front now; Finder and the player open right after and come above it.
            window?.orderFront(nil)
        }
    }

    // MARK: Actions on the selection

    private func actions() -> RecordingsActions {
        var a = RecordingsActions()
        a.newRecording = { [weak self] in self?.newRecording() }
        a.open = { urls in urls.forEach { AfterStop.openInPlayer($0) } }
        a.reveal = { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) }
        a.edit = { [model] url in model.effects.editRecording(url) }
        a.copy = { urls in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
        }
        a.trash = { [weak self] urls in
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error { AppLog.info("trash failed: \(error.localizedDescription)") }
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        return a
    }

    private var selected: [URL] {
        store.state.items.map(\.url).filter { store.selection.contains($0) }
    }

    @objc func openSelected(_ sender: Any?) { actions().open(selected) }
    @objc func editSelected(_ sender: Any?) { if selected.count == 1, let one = selected.first { actions().edit(one) } }
    @objc func revealSelected(_ sender: Any?) { actions().reveal(selected) }
    @objc func trashSelected(_ sender: Any?) { actions().trash(selected) }
    @objc func copy(_ sender: Any?) { actions().copy(selected) }
    @objc override func selectAll(_ sender: Any?) { store.selection = Set(store.state.items.map(\.url)) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openSelected(_:)), #selector(revealSelected(_:)), #selector(trashSelected(_:)), #selector(copy(_:)):
            return !store.selection.isEmpty
        case #selector(editSelected(_:)):
            return store.selection.count == 1
                && store.state.items.contains { store.selection.contains($0.url) && !$0.unreadable }
        case #selector(selectAll(_:)):
            return !store.state.items.isEmpty
        default:
            return true
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { reload() }
}

/// Reads the store (observable) and hands plain values to RecordingsView.
private struct RecordingsRoot: View {
    let store: RecordingsStore
    let actions: RecordingsActions
    let icon: NSImage?
    var body: some View {
        RecordingsView(state: store.state,
                       selection: Binding(get: { store.selection }, set: { store.selection = $0 }),
                       actions: actions, icon: icon)
    }
}
