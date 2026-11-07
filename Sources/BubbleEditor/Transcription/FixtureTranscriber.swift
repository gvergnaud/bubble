// Owner: E2 (transcription). docs/editor-architecture.md §5: an engine that returns known words, for
// tests, the contract test and fake runs. Reads a project JSON (web/fixtures/demo.project.json:
// `transcript.words` and `transcript.language`) or a bare `{ language?, words: [...] }`.
import Foundation

public struct FixtureTranscriber: Transcriber {
    public let id: String
    public let name: String
    public let isLocal = true
    public let wordsFile: URL
    /// Simulated work: progress is reported in `steps` ticks spread over `delay`.
    public var delay: Duration
    public var steps: Int

    public init(wordsFile: URL, id: String = "fixture", name: String = "Fixture (test words)",
                delay: Duration = .zero, steps: Int = 4) {
        self.wordsFile = wordsFile; self.id = id; self.name = name; self.delay = delay; self.steps = max(1, steps)
    }

    public func availability() async -> TranscriberAvailability {
        FileManager.default.isReadableFile(atPath: wordsFile.path) ? .available : .unavailable("No fixture file at \(wordsFile.path).")
    }

    public func transcribe(audio: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptResult {
        let data = try Data(contentsOf: wordsFile)
        let file = try JSONDecoder().decode(FixtureFile.self, from: data)
        let body = file.transcript ?? FixtureFile.Body(language: file.language, words: file.words ?? [])
        for i in 1...steps {
            if delay > .zero { try await Task.sleep(for: delay / steps) }
            try Task.checkCancellation()
            progress(Double(i) / Double(steps))
        }
        let words = body.words.map { TimedWord(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker ?? "", filler: $0.filler ?? false) }
        var labels: [String] = []
        for w in words where !labels.contains(w.speaker) { labels.append(w.speaker) }
        return TranscriptResult(language: body.language ?? language, speakers: labels, words: words, raw: data)
    }

    private struct FixtureFile: Decodable {
        struct Word: Decodable { var start: Double; var end: Double; var text: String; var speaker: String?; var filler: Bool? }
        struct Body: Decodable { var language: String?; var words: [Word] }
        var transcript: Body?
        var language: String?
        var words: [Word]?
    }
}
