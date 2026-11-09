// Opening any video (docs/editor-open-video.md, editor-api.md §8). Owner: E1.
// Paths enter only through Bubble's own UI (the app's open panel, the Dock, Open With): the page
// starts a pick and polls its outcome, or proves it holds a dropped file's bytes and Bubble finds
// that file on the Mac with Spotlight. Never a path from the page.
import Foundation
import Synchronization

final class Opener: Sendable {
    let store: ProjectStore
    let app: AppHooks
    let findFiles: @Sendable (_ name: String, _ size: Int64) async -> [URL]

    /// Finished picks are answered for 10 min, then forgotten (404).
    static let keepFor: Duration = .seconds(600)
    static let maxCandidates = 20

    private struct Pick { var state: OpenState; var finishedAt: ContinuousClock.Instant? }
    private struct Table { var picks: [String: Pick] = [:]; var panelUp = false }
    private let table = Mutex(Table())

    init(store: ProjectStore, app: AppHooks, findFiles: (@Sendable (String, Int64) async -> [URL])?) {
        self.store = store
        self.app = app
        self.findFiles = findFiles ?? { await Spotlight.find(name: $0, size: $1) }
    }

    /// Every open, by any path: checks the video (refusals), finds or makes its project, tells the
    /// app (Open Recent).
    func open(_ url: URL) async throws -> StoredProject {
        let p = try await store.open(recording: url, recordingsFolder: app.recordingsFolder?())
        app.onOpened?(url)
        return p
    }

    // MARK: picks (POST /api/open, POST /api/projects/:id/locate)

    /// Starts a panel pick; returns its openId. `locate`: the project to relink.
    func startPick(_ purpose: VideoPick.Purpose, locate projectID: String? = nil) throws -> String {
        guard let pickVideo = app.pickVideo else {
            throw EditorError.notAvailable("Opening a video needs the Bubble app (this server runs without it).")
        }
        let id = UUID().uuidString.lowercased()
        let started = table.withLock { t -> Bool in
            purge(&t)
            guard !t.panelUp else { return false }
            t.panelUp = true
            t.picks[id] = Pick(state: OpenState(state: .pending), finishedAt: nil)
            return true
        }
        guard started else {
            app.bringPanelToFront?()
            throw EditorError.busy
        }
        Task {
            let url = await pickVideo(VideoPick(purpose: purpose))
            let outcome: OpenState
            if let url {
                outcome = await self.finish(url, locate: projectID)
            } else {
                outcome = OpenState(state: .canceled)
            }
            self.table.withLock { t in
                t.panelUp = false
                t.picks[id] = Pick(state: outcome, finishedAt: .now)
            }
        }
        return id
    }

    private func finish(_ url: URL, locate projectID: String?) async -> OpenState {
        do {
            if let projectID {
                let same = try await store.relink(projectID, to: url, recordingsFolder: app.recordingsFolder?())
                app.onOpened?(url)
                return OpenState(state: .opened, projectId: projectID, sameBytes: same)
            }
            return OpenState(state: .opened, projectId: try await open(url).id)
        } catch EditorError.refused(let code, let message) {
            return OpenState(state: .failed, error: code, message: message)
        } catch {
            return OpenState(state: .failed, error: "failed",
                             message: (error as? LocalizedError)?.errorDescription ?? "Bubble couldn't open this video.")
        }
    }

    func state(_ openID: String) -> OpenState? {
        table.withLock { t in purge(&t); return t.picks[openID]?.state }
    }

    private func purge(_ t: inout Table) {
        let now = ContinuousClock.now
        t.picks = t.picks.filter { _, p in p.finishedAt.map { now - $0 < Self.keepFor } ?? true }
    }

    // MARK: drop (POST /api/open/dropped)

    struct Dropped: Sendable {
        var name: String
        var size: Int64
        /// ms since 1970 (File.lastModified)
        var lastModified: Double
        var head: String
        var tail: String
    }

    /// The file on this Mac with that name, size and both end hashes; ties: the one modified at
    /// `lastModified`, else the newest. Files Bubble can't read (macOS privacy denied) don't count.
    func findDropped(_ d: Dropped) async -> URL? {
        let candidates = await findFiles(d.name, d.size).prefix(Self.maxCandidates)
        var hits: [(url: URL, modified: Date)] = []
        for url in candidates where url.lastPathComponent == d.name {   // String ==: NFC and NFD names are equal
            // Off the cooperative pool: a candidate on a sleeping disk blocks a dispatch thread only.
            let hit = try? await BlockingRead.run { _ -> Date? in
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attrs[.size] as? NSNumber)?.int64Value == d.size else { return nil }
                let (_, head, tail) = try VideoFingerprint.hashes(of: url)
                return head == d.head && tail == d.tail ? (attrs[.modificationDate] as? Date ?? .distantPast) : nil
            }
            if let modified = hit ?? nil { hits.append((url, modified)) }
        }
        if let exact = hits.first(where: { abs($0.modified.timeIntervalSince1970 * 1000 - d.lastModified) < 1000 }) { return exact.url }
        return hits.max { $0.modified < $1.modified }?.url
    }

    static func isSHA256Hex(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
}

/// Spotlight lookup by exact name and size, through `mdfind` (no AppKit, no run loop needed).
enum Spotlight {
    /// The query in Spotlight's query language: the name is quoted, with `"`, `\` and `*` escaped.
    /// A name with accents is asked in both Unicode forms (a browser's File.name and the disk's
    /// name may differ: NFC vs NFD); the hashes decide anyway.
    static func query(name: String, size: Int64) -> String {
        func quoted(_ n: String) -> String {
            var escaped = ""
            for ch in n.unicodeScalars {
                if ch == "\"" || ch == "\\" || ch == "*" { escaped.append("\\") }
                escaped.unicodeScalars.append(ch)
            }
            return "kMDItemFSName == \"\(escaped)\""
        }
        let nfc = name.precomposedStringWithCanonicalMapping, nfd = name.decomposedStringWithCanonicalMapping
        let names = nfc.unicodeScalars.elementsEqual(nfd.unicodeScalars) ? quoted(nfc) : "(\(quoted(nfc)) || \(quoted(nfd)))"
        return "\(names) && kMDItemFSSize == \(size)"
    }

    /// Paths Spotlight knows for that name and size (5 s at most; [] on any failure).
    static func find(name: String, size: Int64) async -> [URL] {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { return [] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                p.arguments = ["-0", query(name: name, size: size)]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: []); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                let paths = data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
                cont.resume(returning: paths.prefix(Opener.maxCandidates).map { URL(fileURLWithPath: $0) })
            }
        }
    }
}
