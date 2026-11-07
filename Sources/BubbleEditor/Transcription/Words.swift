// Owner: E2 (transcription). docs/editor-architecture.md §5: from an engine's words to the transcript the
// page shows: time order, fillers flagged, speakers renamed S1, S2... in order of first appearance.
import Foundation

/// A word of the final transcript (docs/editor-api.md §2 `Word`).
public struct TranscriptWord: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    public var text: String
    /// "S1", "S2"...
    public var speaker: String
    public var filler: Bool
    /// Time estimated (spread by letters), not heard: `Word.approximate` in the API.
    public var approximate: Bool

    public init(start: Double, end: Double, text: String, speaker: String, filler: Bool = false, approximate: Bool = false) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker; self.filler = filler
        self.approximate = approximate
    }
}

public struct TranscriptSpeaker: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum Words {
    /// Words that are only hesitation, in the languages we expect (compared without punctuation, lowercased).
    public static let fillers: Set<String> = ["uh", "um", "uhm", "umm", "uhh", "euh", "hmm", "hm", "erm", "ben", "bah", "mmh", "mh"]

    public struct Posted: Sendable, Equatable {
        public var speakers: [TranscriptSpeaker]
        public var words: [TranscriptWord]
    }

    /// Sorted by start, empty and invalid words dropped, times clamped to `duration` (if given) and made
    /// monotonic (end ≥ start), fillers flagged, speakers renamed in order of first appearance.
    /// No diarization (every label empty) → one speaker "S1".
    public static func post(_ result: TranscriptResult, duration: Double? = nil) -> Posted {
        var words = result.words
            .filter { $0.start.isFinite && $0.end.isFinite && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        var ids: [String: String] = [:]
        var speakers: [TranscriptSpeaker] = []
        var out: [TranscriptWord] = []
        out.reserveCapacity(words.count)
        for i in words.indices {
            var w = words[i]
            w.text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            w.start = max(0, w.start)
            if let duration { w.start = min(w.start, duration); w.end = min(w.end, duration) }
            w.end = max(w.start, w.end)
            words[i] = w
            let label = w.speaker
            let id: String
            if let known = ids[label] { id = known } else {
                id = "S\(speakers.count + 1)"
                ids[label] = id
                speakers.append(TranscriptSpeaker(id: id, name: "Speaker \(speakers.count + 1)"))
            }
            out.append(TranscriptWord(start: w.start, end: w.end, text: w.text, speaker: id, filler: w.filler || isFiller(w.text), approximate: w.approximate))
        }
        return Posted(speakers: speakers, words: out)
    }

    /// "uh," "Um..." "euh" → true; "umbrella" → false.
    public static func isFiller(_ text: String) -> Bool {
        let core = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(.symbols))
        return fillers.contains(core)
    }
}
