// Owner: app/UI track. The user's settings, kept in UserDefaults (design.md §8 defaults).
// Pure storage: no side effects besides UserDefaults. Inject a suite in tests.
import BubbleCore
import Foundation
import Observation

/// What the user picked in the Camera menu.
public enum CameraChoice: Sendable, Equatable, Codable {
    /// The last used camera, or the built-in one the first time.
    case automatic
    case device(String)
    /// "No Camera": record the screen only, no bubble.
    case none
}

/// What the user picked in the Mic menu.
public enum MicChoice: Sendable, Equatable, Codable {
    /// The system default input.
    case automatic
    case device(String)
    /// "No Microphone": silent video (unless computer sound is on).
    case none
}

@MainActor
@Observable
public final class Settings {
    @ObservationIgnored private let defaults: UserDefaults

    public var countdownEnabled: Bool { didSet { defaults.set(countdownEnabled, forKey: Key.countdown) } }
    public var mirrorCamera: Bool { didSet { defaults.set(mirrorCamera, forKey: Key.mirror) } }
    public var highlightClicks: Bool { didSet { defaults.set(highlightClicks, forKey: Key.clicks) } }
    public var openAtLogin: Bool { didSet { defaults.set(openAtLogin, forKey: Key.login) } }
    /// Off by default; remembered once turned on (design.md v1 add-ons).
    public var computerSound: Bool { didSet { defaults.set(computerSound, forKey: Key.computerSound) } }
    public var folder: URL { didSet { defaults.set(folder.path, forKey: Key.folder) } }
    public var camera: CameraChoice { didSet { store(camera, Key.camera) } }
    public var microphone: MicChoice { didSet { store(microphone, Key.mic) } }
    /// Bubble place and size per display (key: BubblePlacement.displayKey).
    public var bubblePlaces: [String: BubblePlace] { didSet { store(bubblePlaces, Key.places) } }
    public var lastRecording: URL? { didSet { defaults.set(lastRecording?.path, forKey: Key.last) } }
    /// The Welcome window was finished once (Done). It shows again only if Screen Recording is missing.
    public var welcomeDone: Bool { didSet { defaults.set(welcomeDone, forKey: Key.welcome) } }
    /// What ⌥⇧L records (design.md §11.1).
    public var source: SourceKind { didSet { defaults.set(source.rawValue, forKey: Key.source) } }
    /// The area per display (key: BubblePlacement.displayKey), AppKit global points.
    public var areas: [String: CGRect] { didSet { store(areas, Key.areas) } }
    /// The bubble's place inside a window or an area, per source kind ("window" / "area").
    public var framePlaces: [String: BubblePlace] { didSet { store(framePlaces, Key.framePlaces) } }

    public init(defaults: UserDefaults = .standard, defaultFolder: URL = RecordingFiles.defaultFolder) {
        self.defaults = defaults
        countdownEnabled = defaults.object(forKey: Key.countdown) as? Bool ?? true
        mirrorCamera = defaults.object(forKey: Key.mirror) as? Bool ?? true
        highlightClicks = defaults.object(forKey: Key.clicks) as? Bool ?? true
        openAtLogin = defaults.object(forKey: Key.login) as? Bool ?? false
        computerSound = defaults.object(forKey: Key.computerSound) as? Bool ?? false
        folder = defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
        camera = Self.load(CameraChoice.self, defaults, Key.camera) ?? .automatic
        microphone = Self.load(MicChoice.self, defaults, Key.mic) ?? .automatic
        bubblePlaces = Self.load([String: BubblePlace].self, defaults, Key.places) ?? [:]
        lastRecording = defaults.string(forKey: Key.last).map { URL(fileURLWithPath: $0) }
        welcomeDone = defaults.bool(forKey: Key.welcome)
        source = defaults.string(forKey: Key.source).flatMap(SourceKind.init(rawValue:)) ?? .fullScreen
        areas = Self.load([String: CGRect].self, defaults, Key.areas) ?? [:]
        framePlaces = Self.load([String: BubblePlace].self, defaults, Key.framePlaces) ?? [:]
    }

    /// The save folder as stored, readable off the main actor (the editor's server asks at each open).
    public nonisolated static func savedFolder(_ defaults: UserDefaults = .standard,
                                               defaultFolder: URL = RecordingFiles.defaultFolder) -> URL {
        defaults.string(forKey: Key.folder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private enum Key {
        static let countdown = "countdownEnabled"
        static let mirror = "mirrorCamera"
        static let clicks = "highlightClicks"
        static let login = "openAtLogin"
        static let computerSound = "computerSound"
        static let folder = "folder"
        static let camera = "camera"
        static let mic = "microphone"
        static let places = "bubblePlaces"
        static let last = "lastRecording"
        static let welcome = "welcomeDone"
        static let source = "recordSource"
        static let areas = "recordAreas"
        static let framePlaces = "bubbleFramePlaces"
    }
}
