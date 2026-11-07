// Owner: E2 (transcription). docs/editor-architecture.md §5: Apple's on-device SpeechTranscriber (macOS 26,
// SpeechAnalyzer). The local engine ("On this Mac": words with times, one speaker), and the word-time
// reference for Voxtral 3. Nothing leaves the Mac. The language model may need a one-time download by
// macOS (AssetInventory). Not run on the user's Mac while he records: Speech may show a prompt.
import AVFoundation
import Foundation
import Speech

public struct AppleTranscriber: Transcriber {
    public let id = "apple-local"
    public let name = "On this Mac"
    public let isLocal = true

    public init() {}

    public enum Failure: Error, LocalizedError, Equatable {
        case needsMacOS26
        case unavailable
        case unsupportedLanguage(String)

        public var errorDescription: String? {
            switch self {
            case .needsMacOS26: "Transcribing on this Mac needs macOS 26."
            case .unavailable: "Speech recognition isn't available on this Mac."
            case .unsupportedLanguage(let l): "This Mac can't transcribe \(l) yet."
            }
        }
    }

    public func availability() async -> TranscriberAvailability {
        guard #available(macOS 26, *) else { return .unavailable(Failure.needsMacOS26.errorDescription!) }
        guard SpeechTranscriber.isAvailable else { return .unavailable(Failure.unavailable.errorDescription!) }
        // Only asks what is installed (no download, no prompt).
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return .available }
        switch await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)]) {
        case .installed: return .available
        case .supported, .downloading: return .availableWithNote(Self.downloadNote)
        case .unsupported: return .available   // another language may be: decided at transcription time
        @unknown default: return .available
        }
    }

    static let downloadNote = "First time: macOS downloads its speech model, so it takes a bit longer."

    /// `language`: "en", "fr", "en-US"... (nil: the Mac's language).
    public func transcribe(audio: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptResult {
        guard #available(macOS 26, *) else { throw Failure.needsMacOS26 }
        return try await Self.run(audio: audio, language: language, progress: progress)
    }

    @available(macOS 26, *)
    static func run(audio: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptResult {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        let wanted = language.map { Locale(identifier: $0) } ?? Locale.current
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw Failure.unsupportedLanguage(Locale.current.localizedString(forIdentifier: wanted.identifier) ?? wanted.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // The language model: macOS downloads it once (shared by every app), then it's on disk.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collect = Task { () throws -> [TimedWord] in
            var words: [TimedWord] = []
            for try await result in transcriber.results {
                words += Self.words(in: result.text)
                if duration > 0 { progress(min(0.99, result.range.end.seconds / duration)) }
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collect.cancel()
            throw error
        }
        let words = try await withTaskCancellationHandler { try await collect.value } onCancel: { collect.cancel() }
        progress(1)
        return TranscriptResult(language: locale.language.languageCode?.identifier, speakers: words.isEmpty ? [] : [""],
                                words: words.sorted { $0.start < $1.start })
    }

    /// Words from a result's text: its runs carry `audioTimeRange`. A run can be part of a word (glued to
    /// the next run without a space) or hold several words (their times then shared by letters, approximate).
    @available(macOS 26, *)
    static func words(in text: AttributedString) -> [TimedWord] {
        var pieces: [TimedPiece] = []
        for run in text.runs {
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }
            pieces.append(TimedPiece(text: String(text[run.range].characters), start: range.start.seconds, end: range.end.seconds))
        }
        return words(from: pieces)
    }

    struct TimedPiece: Equatable { var text: String; var start: Double; var end: Double }

    /// Pure (tested): timed text pieces → words.
    static func words(from pieces: [TimedPiece]) -> [TimedWord] {
        var out: [TimedWord] = []
        var current: TimedWord?
        func close() { if let c = current, !c.text.isEmpty { out.append(c) }; current = nil }
        for p in pieces where p.start.isFinite && p.end.isFinite {
            let tokens = p.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { close(); continue }
            if p.text.first?.isWhitespace == true { close() }
            if tokens.count == 1 {
                if var c = current { c.text += tokens[0]; c.end = max(c.end, p.end); current = c }
                else { current = TimedWord(start: p.start, end: p.end, text: tokens[0]) }
            } else {
                let times = WordAligner.spread(tokens, from: p.start, to: p.end)
                for (k, (token, t)) in zip(tokens, times).enumerated() {
                    if k == 0, var c = current { c.text += token; c.end = t.1; c.approximate = true; current = c; continue }
                    close()
                    current = TimedWord(start: t.0, end: t.1, text: token, approximate: true)
                }
            }
            if p.text.last?.isWhitespace == true { close() }
        }
        close()
        return out.map(trimLeadingPause)
    }

    /// Apple's runs are back to back: a word's range starts where the previous one ended, so the pause
    /// before it counts as part of it (measured on the fixture: sentence starts 0.68 s early, median).
    /// Ends are right. A word is at most `0.12 s + 0.06 s per letter` long; the rest is the pause
    /// (sentence starts then 0.15 s off, median, on the fixture).
    static func trimLeadingPause(_ w: TimedWord) -> TimedWord {
        var w = w
        let longest = 0.12 + 0.06 * Double(max(1, WordAligner.normalize(w.text).count))
        w.start = max(w.start, w.end - longest)
        return w
    }
}

/// The engines the app offers, in the page's order (docs/editor-api.md §5): Voxtral 3 (its word times from
/// Apple's engine) and Apple's alone. Which one is the default is the server's call (first available).
public enum TranscriptionEngines {
    public static func standard(key: MistralKey) -> [any Transcriber] {
        let apple = AppleTranscriber()
        return [MistralTranscriber(key: key, timing: apple), apple]
    }
}
