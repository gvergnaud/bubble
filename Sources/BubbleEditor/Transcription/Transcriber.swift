// Owner: E2 (transcription). docs/editor-architecture.md §5: one interface for every speech-to-text
// engine (local or API). The rest of the editor never knows which engine it talks to.
import Foundation

public protocol Transcriber: Sendable {
    /// Stable id the page sends back: "apple-local", "voxtral-mini-2602", "fixture"...
    var id: String { get }
    /// Shown to the user.
    var name: String { get }
    /// True when the audio never leaves the Mac.
    var isLocal: Bool { get }
    func availability() async -> TranscriberAvailability
    /// `audio`: what `AudioExtract` made (16 kHz mono WAV). `progress`: 0...1 from any thread.
    func transcribe(audio: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptResult
}

public enum TranscriberAvailability: Sendable, Equatable {
    case available
    /// Usable, with a note for the user (EngineInfo `available: true` + `why`): "First time: macOS downloads…".
    case availableWithNote(String)
    /// A sentence for the user ("Add your Mistral API key.").
    case unavailable(String)

    public var isAvailable: Bool { if case .unavailable = self { false } else { true } }
    public var why: String? {
        switch self {
        case .available: nil
        case .availableWithNote(let w), .unavailable(let w): w
        }
    }
}

/// An engine's answer, before `Words.post` (fillers, speaker names).
public struct TranscriptResult: Sendable, Equatable, Codable {
    public var language: String?
    /// The engine's speaker labels, any form ("speaker_0", "A", "S1"); empty when it has no diarization.
    public var speakers: [String]
    public var words: [TimedWord]
    /// The engine's raw answer, kept in transcript-raw/<engine>.json to re-derive words later.
    public var raw: Data?

    public init(language: String?, speakers: [String], words: [TimedWord], raw: Data? = nil) {
        self.language = language; self.speakers = speakers; self.words = words; self.raw = raw
    }
}

public struct TimedWord: Sendable, Equatable, Codable {
    /// Seconds in the audio given to the engine (= source time: AudioExtract keeps the timeline).
    public var start: Double
    public var end: Double
    /// With its trailing punctuation: "everybody,".
    public var text: String
    /// The engine's label ("" when it has no diarization).
    public var speaker: String
    /// The engine says it is a filler (some do); `Words.post` also flags by word list.
    public var filler: Bool
    /// The time is an estimate (spread by letters), not heard by an engine (docs/editor-api.md `Word.approximate`).
    public var approximate: Bool

    public init(start: Double, end: Double, text: String, speaker: String = "", filler: Bool = false, approximate: Bool = false) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker; self.filler = filler
        self.approximate = approximate
    }
}

/// For GET /api/engines (docs/editor-api.md §5).
public struct EngineInfo: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var local: Bool
    public var available: Bool
    public var why: String?
}
