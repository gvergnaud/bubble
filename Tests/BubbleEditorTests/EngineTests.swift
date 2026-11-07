// Owner: E2 (transcription). The engines without running them: WordAligner, Voxtral 3's answer
// (web/fixtures/voxtral3-demo.raw.json, a real answer for the fixture's audio), chunking, MistralKey, and
// Apple's word grouping. No network, no Speech, no Keychain.
@testable import BubbleEditor
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1))) struct EngineTests {
    static let raw = MediaFixtures.repo.appendingPathComponent("web/fixtures/voxtral3-demo.raw.json")

    struct FixtureWord: Decodable { var start: Double; var end: Double; var text: String; var speaker: String }
    static func fixtureWords() throws -> [FixtureWord] {
        struct P: Decodable { struct T: Decodable { var words: [FixtureWord] }; var transcript: T }
        return try JSONDecoder().decode(P.self, from: Data(contentsOf: MediaFixtures.demoProject)).transcript.words
    }

    // MARK: WordAligner

    @Test func normalizeFoldsCaseAccentsAndPunctuation() {
        #expect(WordAligner.normalize("Option-Shift-L,") == "optionshiftl")
        #expect(WordAligner.normalize("Ça") == "ca")
        #expect(WordAligner.normalize("you're") == "youre")
        #expect(WordAligner.normalize("...") == "")
    }

    @Test func matchHandlesJoinsAndSpellings() {
        let m = WordAligner.match(["you", "press", "optionshiftl", "you", "talk"], ["you", "press", "option", "shift", "l", "you", "tok"])
        #expect(m == [.init(vox: 0..<1, ref: 0..<1), .init(vox: 1..<2, ref: 1..<2), .init(vox: 2..<3, ref: 2..<5),
                      .init(vox: 3..<4, ref: 5..<6)])   // "talk"/"tok": substitution, no time taken
        let split = WordAligner.match(["option", "shift", "l"], ["optionshiftl"])
        #expect(split == [.init(vox: 0..<3, ref: 0..<1)])
        #expect(WordAligner.close("okay", "ok") == false)
        #expect(WordAligner.close("gabriel", "gabrielle"))
        #expect(WordAligner.close("recorder", "recorders"))
        #expect(!WordAligner.close("ah", "uh"))
    }

    /// The real Voxtral 3 answer for the fixture + the fixture's own words (jittered, Apple's role):
    /// almost every word gets a heard time, close to the truth; text and speakers are Voxtral's.
    @Test func alignsVoxtralSegmentsToReferenceWords() throws {
        let parsed = try #require(MistralTranscriber.parse(Data(contentsOf: Self.raw)))
        let truth = try Self.fixtureWords()
        let reference = truth.enumerated().map { i, w in
            let jitter = Double((i * 37) % 7 - 3) / 100   // ±30 ms, deterministic
            return TimedWord(start: w.start + jitter, end: w.end + jitter, text: w.text.lowercased())
        }
        let words = WordAligner.align(segments: parsed.segments, reference: reference)
        let tokens = parsed.segments.flatMap { $0.text.split(separator: " ") }
        #expect(words.count == tokens.count)
        #expect(words.map(\.text) == tokens.map(String.init))
        let approximate = words.filter(\.approximate)
        #expect(Double(approximate.count) / Double(words.count) < 0.05, "\(approximate.map(\.text))")
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start && $0.end <= $1.start + 0.0001 })
        for w in words {
            let seg = parsed.segments.first { w.start >= $0.start - 0.0001 && w.end <= $0.end + 0.0001 && $0.speaker == w.speaker }
            #expect(seg != nil, "\(w) outside its segment")
        }
        // Each heard word sits within 0.12 s of the same word in the truth (Voxtral's segment edges are
        // 0.1 s steps, so a clamp can move a word by that much).
        var far: [String] = []
        for w in words where !w.approximate {
            let n = WordAligner.normalize(w.text)
            let best = truth.filter { WordAligner.normalize($0.text) == n }.map { abs($0.start - w.start) }.min() ?? 0
            if best > 0.12 { far.append("\(w.text)@\(w.start) Δ\(best)") }
        }
        #expect(far.count <= 3, "\(far)")
        // Speakers: the second speaker's lines are found.
        #expect(words.first { $0.text == "wait," }?.speaker == "speaker_2")
        #expect(words.first { $0.text == "Hey" }?.speaker == "speaker_1")
    }

    @Test func withoutReferenceWordsAreSpreadInsideSegments() throws {
        let parsed = try #require(MistralTranscriber.parse(Data(contentsOf: Self.raw)))
        let words = WordAligner.align(segments: parsed.segments, reference: nil)
        #expect(words.allSatisfy { $0.approximate })
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start + 0.0001 })
        let first = parsed.segments[0]   // "Hey everybody." 0.6-1.4
        #expect(words[0].text == "Hey" && words[0].start == first.start)
        #expect(words[1].text == "everybody." && words[1].end <= first.end && words[1].end > first.end - 0.2)
        // Longer words get more time.
        #expect(words[1].end - words[1].start > words[0].end - words[0].start)
    }

    @Test func unmatchedRunsFillTheGapBetweenTimedNeighbours() {
        let seg = TextSegment(start: 10, end: 14, text: "one two three four", speaker: "A")
        let ref = [TimedWord(start: 10.2, end: 10.5, text: "one"), TimedWord(start: 13.0, end: 13.6, text: "four")]
        let w = WordAligner.align(segments: [seg], reference: ref)
        #expect(w.map(\.approximate) == [false, true, true, false])
        #expect(w[0].start == 10.2 && w[3].start == 13.0)
        #expect(w[1].start >= 10.5 && w[2].end <= 13.0)
        // A reference word outside the window is not used.
        let far = WordAligner.align(segments: [seg], reference: [TimedWord(start: 30, end: 31, text: "one")])
        #expect(far.allSatisfy { $0.approximate })
    }

    // MARK: Voxtral 3 answer

    @Test func parsesTheRealAnswer() throws {
        let parsed = try #require(MistralTranscriber.parse(Data(contentsOf: Self.raw)))
        #expect(parsed.language == "en")
        #expect(parsed.segments.count == 19)
        #expect(parsed.segments[0] == TextSegment(start: 0.6, end: 1.4, text: "Hey everybody.", speaker: "speaker_1"))
        #expect(Set(parsed.segments.map(\.speaker)) == ["speaker_1", "speaker_2"])
        #expect(MistralTranscriber.parse(Data("{\"object\":\"error\"}".utf8)) == nil)
        let errors = try Data(contentsOf: MediaFixtures.repo.appendingPathComponent("web/fixtures/voxtral3-word-errors.json"))
        let obj = try JSONSerialization.jsonObject(with: errors) as! [String: Any]
        let e422 = try JSONSerialization.data(withJSONObject: obj["mini3_diarize_word_http422"]!)
        #expect(MistralTranscriber.errorMessage(e422).contains("timestamp granularity must be set to ['segment']"))
        let e400 = try JSONSerialization.data(withJSONObject: obj["mini3_word_no_diarize_http400"]!)
        #expect(MistralTranscriber.errorMessage(e400) == "Word-level segments are not enabled for this model")
    }

    @Test func mergeKeepsTheLaterChunkInTheOverlapAndMatchesSpeakers() {
        let url = URL(fileURLWithPath: "/dev/null")
        let c0 = AudioChunks.Chunk(start: 0, end: 120, url: url)      // cut at 100, overlap 20
        let c1 = AudioChunks.Chunk(start: 100, end: 200, url: url)
        let first = [TextSegment(start: 2, end: 50, text: "a", speaker: "speaker_1"),
                     TextSegment(start: 60, end: 98, text: "b", speaker: "speaker_2"),
                     TextSegment(start: 101, end: 118, text: "c (first copy)", speaker: "speaker_2")]
        // In chunk 1, the same voice is "speaker_1"; a new voice appears as "speaker_2".
        let second = [TextSegment(start: 1, end: 18, text: "c", speaker: "speaker_1"),
                      TextSegment(start: 30, end: 60, text: "d", speaker: "speaker_2")]
        let merged = MistralTranscriber.merge([(c0, first), (c1, second)])
        #expect(merged.map(\.text) == ["a", "b", "c", "d"])
        #expect(merged[2].start == 101 && merged[2].speaker == "speaker_2")
        #expect(merged[3].speaker != "speaker_1" && merged[3].speaker != "speaker_2")
    }

    // MARK: Chunks

    @Test func cutsAreInTheQuietestPlaceBeforeTheLimit() {
        // 120 s of noise at 0.1 s steps, silent at 31-32 s and 63.0-63.5 s; room per chunk = 40 - 5 = 35 s,
        // searched in its last 10 s.
        var energy = [Float](repeating: 100, count: 1200)
        for i in 310..<320 { energy[i] = 0 }
        for i in 630..<635 { energy[i] = 0 }
        let plan = AudioChunks.Plan(maxLength: 40, overlap: 5, searchWindow: 10)
        let cuts = AudioChunks.cuts(energy: energy, step: 0.1, duration: 120, plan: plan)
        #expect(cuts.count == 3, "\(cuts)")
        guard cuts.count == 3 else { return }
        #expect(abs(cuts[0] - 31.5) < 0.3, "\(cuts)")          // silence in [25, 35]
        #expect(abs(cuts[1] - 63.25) < 0.3, "\(cuts)")         // silence in [56.5, 66.5]
        #expect(abs(cuts[2] - (63.25 + 35 - 0.25)) < 0.3, "\(cuts)")   // no silence: as late as possible
        #expect(AudioChunks.cuts(energy: energy, step: 0.1, duration: 30, plan: plan).isEmpty)
    }

    @Test func splitWritesChunksThatCoverTheAudio() throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 50 s of 16 kHz WAV: a ramp, so a chunk's first sample says where it starts.
        let n = 50 * 16_000
        var pcm = [Int16](repeating: 0, count: n)
        for i in 0..<n { pcm[i] = Int16(truncatingIfNeeded: i / 16) }
        var wav = AudioExtract.wavHeader(dataBytes: n * 2)
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        let src = dir.appendingPathComponent("a.wav")
        try wav.write(to: src)
        let chunks = try AudioChunks.split(wav: src, plan: .init(maxLength: 20, overlap: 4, searchWindow: 6), into: dir.appendingPathComponent("c"))
        #expect(chunks.count >= 3)
        #expect(chunks.first?.start == 0)
        #expect(abs((chunks.last?.end ?? 0) - 50) < 0.001)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.end - a.start <= 20.0001)
            #expect(abs(a.end - (b.start + 4)) < 0.001)              // runs 4 s past the next start
        }
        for c in chunks {
            let d = try Data(contentsOf: c.url)
            #expect(d.count == 44 + Int(((c.end - c.start) * 16_000).rounded()) * 2)
            let first = d.withUnsafeBytes { $0.load(fromByteOffset: 44, as: Int16.self) }
            #expect(first == Int16(truncatingIfNeeded: Int((c.start * 16_000).rounded()) / 16))
        }
        let single = try AudioChunks.split(wav: src, plan: .init(), into: dir)
        #expect(single.count == 1 && single[0].url == src)
    }

    // MARK: MistralTranscriber with a fake client

    @Test func voxtralEngineEndToEndWithFakeClient() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let answer = try Data(contentsOf: Self.raw)
        let calls = CallLog()
        let key = MistralKey(store: MemorySecretStore("sk-test"), environment: [:], verifier: { _ in .valid })
        let client: MistralTranscriber.Client = { _, model, k in calls.add("\(model) \(k)"); return answer }
        let withApple = MistralTranscriber(key: key, timing: FixtureTranscriber(wordsFile: MediaFixtures.demoProject, id: "apple-local"), client: client)
        let jobs = TranscriptionJobs(engines: [withApple])
        _ = try await jobs.start(projectID: "demo", source: MediaFixtures.demo, folder: dir, duration: 68.638)
        let state = try #require(await jobs.wait(projectID: "demo"))
        #expect(state.status == .ready, "\(state.error ?? "")")
        #expect(state.engine == "voxtral-mini-transcribe-3")
        #expect(state.language == "en")
        #expect(state.speakers.map(\.id) == ["S1", "S2"])
        #expect(state.words.count > 200)
        #expect(Double(state.words.filter(\.approximate).count) / Double(state.words.count) < 0.05)
        #expect(state.words.contains { $0.filler && $0.text == "um," })
        #expect(calls.values == ["voxtral-mini-transcribe-3 sk-test"])
        let raw = try Data(contentsOf: dir.appendingPathComponent("transcript-raw/voxtral-mini-transcribe-3.json"))
        #expect(String(decoding: raw, as: UTF8.self).contains("speaker_2"))
        #expect(!String(decoding: raw, as: UTF8.self).contains("sk-test"))

        // No Apple: every word approximate, still ready.
        let alone = MistralTranscriber(key: key, timing: nil, client: client)
        let r = try await alone.transcribe(audio: AudioExtractFixture.wav(in: dir), language: nil) { _ in }
        #expect(r.words.allSatisfy { $0.approximate })
        // Apple failing: same, never a failed transcript.
        let broken = MistralTranscriber(key: key, timing: FailingTranscriber(), client: client)
        let r2 = try await broken.transcribe(audio: AudioExtractFixture.wav(in: dir), language: nil) { _ in }
        #expect(r2.words.count == r.words.count)
    }

    @Test func voxtralErrorsAreSentencesWithoutTheKey() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = MistralKey(store: MemorySecretStore("sk-secret"), environment: [:])
        for (failure, sentence) in [(MistralTranscriber.Failure.refused, "Mistral refused the API key. Check it in the transcription settings."),
                                    (.unreachable, "Mistral can't be reached. Check the connection, or transcribe on this Mac.")] {
            let engine = MistralTranscriber(key: key, client: { _, _, _ in throw failure })
            let jobs = TranscriptionJobs(engines: [engine])
            _ = try await jobs.start(projectID: "p", source: MediaFixtures.demo, folder: dir)
            let s = await jobs.wait(projectID: "p")
            #expect(s?.status == .failed)
            #expect(s?.error == sentence)
            #expect(s?.error?.contains("sk-secret") != true)
        }
        let noKey = MistralTranscriber(key: MistralKey(store: MemorySecretStore(), environment: [:]))
        #expect(await noKey.availability() == .unavailable("Add your Mistral API key."))
    }

    @Test func multipartHasNoLanguageAndTheWholeWAV() throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = try AudioExtractFixture.wav(in: dir)
        let body = dir.appendingPathComponent("body")
        try MistralTranscriber.writeMultipart(wav: wav, model: "voxtral-mini-transcribe-3", boundary: "B", to: body)
        let data = try Data(contentsOf: body)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("name=\"timestamp_granularities\"\r\n\r\nsegment\r\n"))
        #expect(text.contains("name=\"diarize\"\r\n\r\ntrue\r\n"))
        #expect(text.contains("name=\"return_language\"\r\n\r\ntrue\r\n"))
        #expect(!text.contains("name=\"language\""))
        #expect(text.hasSuffix("\r\n--B--\r\n"))
        let wavBytes = try Data(contentsOf: wav)
        #expect(data.range(of: wavBytes) != nil)
        #expect(data.count < wavBytes.count + 1000)
    }

    @Test func availabilityNotesKeepTheEngineUsable() {
        let note = TranscriberAvailability.availableWithNote("First time: …")
        #expect(note.isAvailable && note.why == "First time: …")
        #expect(TranscriberAvailability.available.why == nil)
        #expect(!TranscriberAvailability.unavailable("x").isAvailable)
    }

    // MARK: MistralKey

    @Test func keyComesFromKeychainThenEnvironment() async throws {
        let store = MemorySecretStore()
        let verdict = VerdictBox(.valid)
        let key = MistralKey(store: store, environment: ["MISTRAL_API_KEY": " env-key \n"], verifier: { _ in verdict.value })
        #expect(key.current()?.key == "env-key")
        #expect(key.source == .environment)
        try await key.save("  sk-new ")
        #expect(key.current()?.key == "sk-new" && key.source == .keychain)
        verdict.value = .invalid
        await #expect(throws: MistralKey.SaveError.invalid) { try await key.save("sk-bad") }
        verdict.value = .unreachable
        await #expect(throws: MistralKey.SaveError.unreachable) { try await key.save("sk-maybe") }
        #expect(key.current()?.key == "sk-new")                    // a refused key never replaces the good one
        await #expect(throws: MistralKey.SaveError.invalid) { try await key.save("two words") }
        try key.delete()
        #expect(key.source == .environment)
        #expect(MistralKey(store: store, environment: [:]).source == MistralKey.Source.none)
    }

    // MARK: Apple's runs → words

    @Test func applePiecesBecomeWords() {
        typealias P = AppleTranscriber.TimedPiece
        let words = AppleTranscriber.words(from: [
            P(text: "Hey", start: 0.6, end: 0.9), P(text: " every", start: 0.92, end: 1.2), P(text: "body,", start: 1.2, end: 1.45),
            P(text: " I'm Gabriel", start: 1.7, end: 2.4), P(text: " ", start: 2.4, end: 2.5), P(text: " ok", start: 2.6, end: 2.8),
        ])
        #expect(words.map(\.text) == ["Hey", "everybody,", "I'm", "Gabriel", "ok"])
        #expect(words[1].start == 0.92 && words[1].end == 1.45 && !words[1].approximate)
        #expect(words[2].approximate && words[3].approximate)
        #expect(words[2].start == 1.7 && words[3].end <= 2.4)
        #expect(!words[4].approximate)
        // Back-to-back runs: the pause before a word is cut off its start (word ≤ 0.12 + 0.06 s/letter).
        let glued = AppleTranscriber.words(from: [P(text: "Hey", start: 0, end: 0.72), P(text: " everybody.", start: 0.72, end: 1.38)])
        #expect(abs(glued[0].start - (0.72 - 0.30)) < 1e-9)
        #expect(glued[1].start == 0.72 && glued[1].end == 1.38)   // 9 letters: 0.66 s, fits
    }
}

enum AudioExtractFixture {
    /// A 1 s silent 16 kHz WAV (the engine under test never listens to it).
    static func wav(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("silence.wav")
        var d = AudioExtract.wavHeader(dataBytes: 32_000)
        d.append(Data(count: 32_000))
        try d.write(to: url)
        return url
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    func add(_ s: String) { lock.withLock { log.append(s) } }
    var values: [String] { lock.withLock { log } }
}

final class VerdictBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: MistralKey.Verification
    init(_ v: MistralKey.Verification) { self.v = v }
    var value: MistralKey.Verification {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
