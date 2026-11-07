// Owner: E2 (transcription). docs/editor-architecture.md §5: Voxtral 3 through the Mistral API, with
// diarization. Voxtral 3 answers sentences only (diarize + word → 422, checked 2026-11-06: see
// web/fixtures/voxtral3-word-errors.json), so word times come from a local reference engine (Apple's
// on-device SpeechTranscriber) through WordAligner; without it, words are spread inside their sentence.
// Long audio is sent in chunks cut at silences. The key comes from MistralKey; it is never logged.
import Foundation

public struct MistralTranscriber: Transcriber {
    public static let model = "voxtral-mini-transcribe-3"

    public let id = MistralTranscriber.model
    public let name = "Voxtral 3 (Mistral)"
    public let isLocal = false

    /// Sends one WAV chunk; returns Mistral's JSON. Live: `MistralTranscriber.upload`. Tests: a fake.
    public typealias Client = @Sendable (_ wav: URL, _ model: String, _ key: String) async throws -> Data

    let key: MistralKey
    let client: Client
    /// Gives word times (Apple's engine). nil or failing: words spread by letters (`approximate`).
    let timing: (any Transcriber)?
    let chunking: AudioChunks.Plan

    public init(key: MistralKey, timing: (any Transcriber)? = nil, client: @escaping Client = MistralTranscriber.upload,
                chunking: AudioChunks.Plan = .init()) {
        self.key = key; self.timing = timing; self.client = client; self.chunking = chunking
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case noKey
        case refused
        case rateLimited
        case unreachable
        case http(Int, String)
        case badAnswer

        public var errorDescription: String? {
            switch self {
            case .noKey: "Add your Mistral API key to transcribe with Voxtral."
            case .refused: "Mistral refused the API key. Check it in the transcription settings."
            case .rateLimited: "Mistral is busy (rate limit). Try again in a minute."
            case .unreachable: "Mistral can't be reached. Check the connection, or transcribe on this Mac."
            case .http(let code, let message): "Mistral answered \(code)\(message.isEmpty ? "" : ": \(message)")."
            case .badAnswer: "Mistral's answer could not be read."
            }
        }
    }

    public func availability() async -> TranscriberAvailability {
        key.current() == nil ? .unavailable("Add your Mistral API key.") : .available
    }

    public func transcribe(audio: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptResult {
        guard let (apiKey, _) = key.current() else { throw Failure.noKey }
        let work = audio.deletingLastPathComponent().appendingPathComponent(".voxtral-chunks-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let chunks = try AudioChunks.split(wav: audio, plan: chunking, into: work)

        // 1. Voxtral 3, chunk by chunk (sentences, speakers, language).
        var answers: [(chunk: AudioChunks.Chunk, data: Data, parsed: Parsed)] = []
        let share = timing == nil ? 1.0 : 0.6
        for (n, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let data = try await client(chunk.url, Self.model, apiKey)
            guard let parsed = Self.parse(data) else { throw Failure.badAnswer }
            answers.append((chunk, data, parsed))
            progress(share * Double(n + 1) / Double(chunks.count))
        }
        let segments = Self.merge(answers.map { ($0.chunk, $0.parsed.segments) })
        let detected = answers.lazy.compactMap(\.parsed.language).first ?? language

        // 2. Word times from the local engine, on the same audio. Never fails the transcript.
        var reference: [TimedWord]?
        if let timing, await timing.availability().isAvailable {
            reference = try? await timing.transcribe(audio: audio, language: detected) { p in progress(share + (1 - share) * p) }.words
            try Task.checkCancellation()
        }
        let words = WordAligner.align(segments: segments, reference: reference)
        var speakers: [String] = []
        for s in segments where !speakers.contains(s.speaker) { speakers.append(s.speaker) }
        progress(1)
        return TranscriptResult(language: detected, speakers: speakers, words: words,
                                raw: Self.rawRecord(answers.map { ($0.chunk, $0.data) }, referenceWords: reference?.count))
    }

    // MARK: - Mistral's answer

    struct Parsed: Equatable {
        var language: String?
        var segments: [TextSegment]
    }

    /// `{ language, text, segments: [{ text, start, end, speaker_id }] }` → segments (text trimmed).
    /// No segments but a text: one segment over the whole chunk is not invented; it returns nil.
    static func parse(_ data: Data) -> Parsed? {
        struct Answer: Decodable {
            struct Segment: Decodable { var text: String; var start: Double; var end: Double; var speaker_id: String? }
            var language: String?
            var segments: [Segment]?
        }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data), let segs = a.segments else { return nil }
        let segments = segs.compactMap { s -> TextSegment? in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, s.start.isFinite, s.end.isFinite else { return nil }
            return TextSegment(start: s.start, end: max(s.start, s.end), text: text, speaker: s.speaker_id ?? "speaker")
        }
        return Parsed(language: a.language, segments: segments)
    }

    /// Chunk answers → one list on the source timeline. A chunk keeps the segments whose middle is before
    /// the next chunk's start (the overlap belongs to the later chunk); a later chunk's speakers are
    /// renamed after the earlier chunk's speakers who said the same overlap (most shared time), else new.
    static func merge(_ chunks: [(AudioChunks.Chunk, [TextSegment])]) -> [TextSegment] {
        var out: [TextSegment] = []
        var previous: [TextSegment] = []   // the previous chunk's segments, global labels, all of them
        var newSpeakers = 0
        for (index, (chunk, segments)) in chunks.enumerated() {
            let shifted = segments.map {
                TextSegment(start: $0.start + chunk.start, end: $0.end + chunk.start, text: $0.text, speaker: $0.speaker)
            }
            // Speaker labels for this chunk.
            var names: [String: String] = [:]
            if index == 0 {
                for s in shifted where names[s.speaker] == nil { names[s.speaker] = s.speaker }
            } else {
                var shared: [String: [String: Double]] = [:]
                for s in shifted {
                    for p in previous {
                        let t = min(s.end, p.end) - max(s.start, p.start)
                        if t > 0 { shared[s.speaker, default: [:]][p.speaker, default: 0] += t }
                    }
                }
                var taken = Set<String>()
                for (label, scores) in shared.sorted(by: { $0.value.values.max()! > $1.value.values.max()! }) {
                    if let best = scores.filter({ $0.value >= 0.3 && !taken.contains($0.key) }).max(by: { $0.value < $1.value }) {
                        names[label] = best.key; taken.insert(best.key)
                    }
                }
                for s in shifted where names[s.speaker] == nil {
                    newSpeakers += 1
                    names[s.speaker] = "chunk\(index)-\(s.speaker)-\(newSpeakers)"
                }
            }
            let labelled = shifted.map { TextSegment(start: $0.start, end: $0.end, text: $0.text, speaker: names[$0.speaker]!) }
            let nextStart = index + 1 < chunks.count ? chunks[index + 1].0.start : .infinity
            out.removeAll { index > 0 && ($0.start + $0.end) / 2 >= chunk.start }   // overlap: the later chunk's version wins
            out += labelled.filter { ($0.start + $0.end) / 2 < nextStart || index + 1 == chunks.count }
            out += []
            previous = labelled
        }
        return out.sorted { $0.start < $1.start }
    }

    /// What goes in transcript-raw/voxtral-mini-transcribe-3.json: every chunk's answer as Mistral sent it.
    static func rawRecord(_ answers: [(AudioChunks.Chunk, Data)], referenceWords: Int?) -> Data? {
        let chunks: [[String: Any]] = answers.map { chunk, data in
            ["start": chunk.start, "end": chunk.end, "answer": (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()]
        }
        var record: [String: Any] = ["model": model, "chunks": chunks]
        record["referenceWords"] = referenceWords ?? NSNull()
        return try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - HTTP

    /// POST /v1/audio/transcriptions: the WAV with diarization, segment times and language detection.
    /// Never sends `language` (Mistral rejects it with timestamps; the detected one comes back with
    /// return_language). The multipart body is written to a temp file and streamed from disk.
    public static let upload: Client = { wav, model, key in
        let boundary = "bubble-\(UUID().uuidString)"
        let body = wav.deletingLastPathComponent().appendingPathComponent(".\(wav.lastPathComponent).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        try writeMultipart(wav: wav, model: model, boundary: boundary, to: body)

        var request = URLRequest(url: URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.upload(for: request, fromFile: body) } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw Failure.unreachable
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 401, 403: throw Failure.refused
        case 429: throw Failure.rateLimited
        default: throw Failure.http(code, errorMessage(data))
        }
    }

    /// The form fields Mistral gets (no `language`: see `upload`).
    static func formFields(model: String) -> [(String, String)] {
        [("model", model), ("diarize", "true"), ("return_language", "true"), ("timestamp_granularities", "segment")]
    }

    /// multipart/form-data: the fields, then the WAV copied in 1 MB pieces (memory stays flat).
    static func writeMultipart(wav: URL, model: String, boundary: String, to url: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        for (name, value) in formFields(model: model) {
            try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try out.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: wav)
        defer { try? input.close() }
        while let piece = try input.read(upToCount: 1 << 20), !piece.isEmpty { try out.write(contentsOf: piece) }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    /// Mistral's error message (`message` string, or `message.detail[0].msg`), short, never the request.
    static func errorMessage(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        var text: String?
        if let m = obj["message"] as? String { text = m }
        else if let m = obj["message"] as? [String: Any], let d = (m["detail"] as? [[String: Any]])?.first { text = d["msg"] as? String }
        return String((text ?? "").prefix(200))
    }
}
