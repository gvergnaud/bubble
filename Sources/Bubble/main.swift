// Owner: app/UI track. Entry point: a menu bar app (LSUIElement, no Dock icon).
// BUBBLE_FAKE=1 wires the fakes (FakeRecorder & co): nothing is captured, the camera stays off, the
// bubble shows a placeholder face. Otherwise the Live* engine (capture track) once it lands.
// BUBBLE_FAKE_PERMISSIONS=none|relaunch starts the fake app with permissions missing (Welcome flow).
import AppKit
import BubbleCore
import BubbleEditor
import BubbleTesting
import BubbleUI

@MainActor
func makeDelegate() -> AppDelegate {
    let env = ProcessInfo.processInfo.environment
    let fake = env["BUBBLE_FAKE"].map { !$0.isEmpty && $0 != "0" } ?? false
    guard fake else {
        let effects = SystemEffects()
        wireEditor(effects, fake: false)
        let model = AppModel(recorder: LiveRecorder(), camera: LiveCameraFeed(),
                             // LiveDeviceCatalog lists the system default input first ("automatic" mic).
                             devices: LiveDeviceCatalog(), permissions: LivePermissions(),
                             settings: Settings(), effects: effects,
                             // Apple's content-sharing picker (design.md §11.1); unavailable before macOS 15.2.
                             windowPicker: LiveWindowPicker(),
                             // The picked window, looked up again just before each take.
                             windowLookup: { RecordedWindow.current($0) })
        return AppDelegate(model: model, effects: effects)
    }

    let displays = NSScreen.screens.enumerated().map { i, s in
        DisplayInfo(id: (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(i + 1),
                    name: s.localizedName, frame: s.frame, scale: s.backingScaleFactor)
    }
    let catalog = FakeDeviceCatalog(
        displays: displays.isEmpty ? [FakeDeviceCatalog.builtIn] : displays,
        cameras: [FakeDeviceCatalog.faceTime, FakeDeviceCatalog.continuity],
        microphones: [FakeDeviceCatalog.builtInMic, FakeDeviceCatalog.airPods])
    let permissions: FakePermissions = switch env["BUBBLE_FAKE_PERMISSIONS"] {
    case "none": FakePermissions()
    case "relaunch": FakePermissions([.screen: .needsRelaunch, .camera: .granted, .microphone: .notDetermined])
    default: FakePermissions.allGranted()
    }
    let defaults = UserDefaults(suiteName: "local.bubble.Bubble.fake") ?? .standard
    let effects = SystemEffects(dryRun: true)
    wireEditor(effects, fake: true)
    let model = AppModel(recorder: TickingFakeRecorder(), camera: FakeCameraFeed(), devices: catalog,
                         permissions: permissions, settings: Settings(defaults: defaults), effects: effects,
                         windowPicker: FakeWindowPicker())
    return AppDelegate(model: model, effects: effects, placeholder: SyntheticFrames.placeholderFace(size: 520))
}

struct EditorPageMissing: LocalizedError {
    var errorDescription: String? { "The editor page is missing from this build." }
}

/// The editor (docs/editor-architecture.md): its server starts lazily on the first Edit, stops at quit.
/// Live: the standard engines with the Mistral key (Keychain, else MISTRAL_API_KEY at launch).
/// BUBBLE_FAKE: the fixture engine, a key in memory (never the real Keychain), its own projects folder.
@MainActor
func wireEditor(_ effects: SystemEffects, fake: Bool) {
    let fm = FileManager.default
    let appSupport = (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support"))
        .appending(path: fake ? "Bubble Fake" : "Bubble", directoryHint: .isDirectory)
    let webRoot = resource("editor", repo: "web/editor", check: "index.html")
    let key: MistralKey
    let engines: [any Transcriber]
    if fake {
        key = MistralKey(store: MemorySecretStore(), environment: [:])
        engines = resource("fixtures", repo: "web/fixtures", check: "demo.project.json")
            .map { [FixtureTranscriber(wordsFile: $0.appending(path: "demo.project.json"))] } ?? []
    } else {
        key = MistralKey()
        engines = TranscriptionEngines.standard(key: key)
    }
    // "Edit any video" (docs/editor-open-video.md): the save folder read at each open (Settings can
    // change it), Bubble's open panel for the page's Open Video… and Locate, Finder for its Show in
    // Finder, Open Recent after every open.
    let suiteName: String? = fake ? "local.bubble.Bubble.fake" : nil
    let picker = effects.picker
    let editor = EditorService(
        appSupport: appSupport, webRoot: webRoot, transcribers: engines, mistralKey: key,
        recordingsFolder: { Settings.savedFolder(suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard) },
        pickVideo: { pick in await pickVideo(picker, pick) },
        bringPanelToFront: { Task { @MainActor in picker.bringToFront() } },
        onOpened: { url in Task { @MainActor in effects.noteOpened(url) } },
        revealInFinder: { url in Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) } })
    effects.editor = { recording in
        // No page in this build: say so in the alert, never a 404 in the browser.
        guard webRoot != nil else { throw EditorPageMissing() }
        return try await editor.editURL(for: recording)
    }
    effects.stopEditor = { editor.stop() }
}

/// The page asked for a video (Open Video…, Locate): the panel, then the focus back to the browser.
@MainActor
func pickVideo(_ picker: VideoPicker, _ pick: VideoPick) async -> URL? {
    switch pick.purpose {
    case .open: await picker.pick(.open, giveFocusBack: true)
    case .locate(let title, let fileName): await picker.pick(.locate(title: title, fileName: fileName), giveFocusBack: true)
    }
}

/// A folder of the app's Resources (copied by build-app.sh); a bare `swift run` has no bundle, so it
/// falls back to the repo's copy. nil when neither holds `check`.
func resource(_ name: String, repo: String, check: String) -> URL? {
    let bundled = Bundle.main.resourceURL?.appending(path: name, directoryHint: .isDirectory)
    let inRepo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../\(repo)", directoryHint: .isDirectory).standardized
    return [bundled, inRepo].compactMap { $0 }
        .first { FileManager.default.fileExists(atPath: $0.appending(path: check).path) }
}

/// FakeRecorder whose elapsed time moves, so the menu bar timer runs in BUBBLE_FAKE mode.
@MainActor
final class TickingFakeRecorder: Recorder {
    private let inner = FakeRecorder()
    private var startedAt: Date?
    private var banked: TimeInterval = 0
    var state: RecorderState { inner.state }
    var elapsed: TimeInterval { banked + (startedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    var onEvent: (@MainActor (RecorderEvent) -> Void)? {
        get { inner.onEvent }
        set { inner.onEvent = newValue }
    }
    func start(_ options: RecordingOptions) async throws -> URL {
        let url = try await inner.start(options)
        banked = 0; startedAt = Date()
        return url
    }
    func pause() { banked = elapsed; startedAt = nil; inner.pause() }
    func resume() { startedAt = Date(); inner.resume() }
    func stop() async -> RecordingResult {
        inner.elapsed = elapsed; startedAt = nil
        return await inner.stop()
    }
    func discard() async { startedAt = nil; await inner.discard() }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { makeDelegate() }
app.delegate = delegate
// A regular app (design.md §10): Dock icon, "Bubble" top-left, a main menu; the menu bar item stays.
app.setActivationPolicy(.regular)
app.run()
