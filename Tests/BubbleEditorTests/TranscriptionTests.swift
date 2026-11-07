// Owner: E2 (transcription). Words.post, AudioExtract, FixtureTranscriber, TranscriptionJobs, on the fixture.
// No real engine here: nothing touches Speech, the mic or the network.
@testable import BubbleEditor
import AVFoundation
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(1))) struct TranscriptionTests {
    // MARK: Words.post

    @Test func fillersAreFlaggedByWordList() {
        for f in ["uh,", "Um...", "euh", "hmm.", "Erm", "ben", "bah!"] { #expect(Words.isFiller(f), "\(f)") }
        for w in ["umbrella", "uh-oh", "bend", "hum", "I"] { #expect(!Words.isFiller(w), "\(w)") }
    }

    @Test func postSortsRenamesAndFlags() {
        let r = TranscriptResult(language: "en", speakers: ["speaker_1", "speaker_0"], words: [
            TimedWord(start: 2, end: 2.4, text: "world.", speaker: "speaker_0"),
            TimedWord(start: 0.5, end: 0.9, text: " Hello ", speaker: "speaker_1"),
            TimedWord(start: 1, end: 1.2, text: "uh,", speaker: "speaker_1"),
            TimedWord(start: 1.5, end: 1.4, text: "x", speaker: "speaker_1"),        // end < start: fixed
            TimedWord(start: 1.6, end: 1.7, text: "  ", speaker: "speaker_1"),       // empty: dropped
            TimedWord(start: 3, end: 3.3, text: "so", speaker: "speaker_0", filler: true),  // engine hint kept
            TimedWord(start: 9, end: 11, text: "late", speaker: "speaker_0"),        // clamped to duration
        ])
        let p = Words.post(r, duration: 10)
        #expect(p.speakers == [TranscriptSpeaker(id: "S1", name: "Speaker 1"), TranscriptSpeaker(id: "S2", name: "Speaker 2")])
        #expect(p.words.map(\.text) == ["Hello", "uh,", "x", "world.", "so", "late"])
        #expect(p.words.map(\.speaker) == ["S1", "S1", "S1", "S2", "S2", "S2"])
        #expect(p.words.map(\.filler) == [false, true, false, false, true, false])
        #expect(p.words[2].end == 1.5)
        #expect(p.words[5].end == 10)
    }

    @Test func noDiarizationIsOneSpeaker() {
        let p = Words.post(TranscriptResult(language: nil, speakers: [], words: [TimedWord(start: 0, end: 1, text: "hi")]))
        #expect(p.speakers == [TranscriptSpeaker(id: "S1", name: "Speaker 1")])
        #expect(p.words.first?.speaker == "S1")
    }

    // MARK: AudioExtract

    @Test func extractsA16kMonoWAVOnTheSourceTimeline() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try await AudioExtract.wav(from: MediaFixtures.demo, to: dir.appendingPathComponent("a.wav"))
        #expect(abs(out.duration - 68.638) < 0.1, "\(out.duration)")
        let file = try AVAudioFile(forReading: out.url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(Double(file.length) / 16_000 - out.duration) < 0.001)
        #expect(out.bytes == Int64(file.length) * 2 + 44)

        // Beeps stay at their source times.
        let src = dir.appendingPathComponent("beeps.mp4")
        try await SyntheticAV.make(src, seconds: 4, beeps: [0.4, 2.7])
        let wav = try await AudioExtract.wav(from: src, to: dir.appendingPathComponent("b.wav"))
        let samples = try readInt16(wav.url)
        let onsets = onsetTimes(samples, rate: 16_000)
        #expect(onsets.count == 2)
        if onsets.count == 2 {
            #expect(abs(onsets[0] - 0.4) < 0.01, "\(onsets)")
            #expect(abs(onsets[1] - 2.7) < 0.01, "\(onsets)")
        }
    }

    // MARK: FixtureTranscriber + jobs

    @Test func fixtureTranscriberReturnsTheFixtureWords() async throws {
        let t = FixtureTranscriber(wordsFile: MediaFixtures.demoProject)
        #expect(await t.availability() == .available)
        let missing = FixtureTranscriber(wordsFile: URL(fileURLWithPath: "/nope.json"))
        #expect(await missing.availability() != .available)
        let r = try await t.transcribe(audio: URL(fileURLWithPath: "/dev/null"), language: nil) { _ in }
        #expect(r.language == "en")
        #expect(r.words.count == 217)
        #expect(r.speakers == ["S1", "S2"])
        #expect(r.words.first == TimedWord(start: 0.68, end: 0.898, text: "Hey", speaker: "S1"))
    }

    @Test func jobRunsToReadyWithTheAPIShape() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = UpdateLog()
        let jobs = TranscriptionJobs(engines: [FixtureTranscriber(wordsFile: MediaFixtures.demoProject, steps: 10)]) { log.add($0, $1) }
        #expect(await jobs.engines() == [EngineInfo(id: "fixture", name: "Fixture (test words)", local: true, available: true, why: nil)])
        let queued = try await jobs.start(projectID: "demo", source: MediaFixtures.demo, folder: dir, duration: 68.638)
        #expect(queued.status == .queued)
        #expect(queued.engine == "fixture")
        let end = try #require(await jobs.wait(projectID: "demo"))
        #expect(end.status == .ready)
        #expect(end.progress == 1)
        #expect(end.language == "en")
        #expect(end.words.count == 217)
        #expect(end.speakers.map(\.id) == ["S1", "S2"])
        #expect(end.speakers.map(\.name) == ["Speaker 1", "Speaker 2"])
        #expect(end.words.filter(\.filler).map(\.text) == ["uh,", "um,", "Uh,", "um,", "uh,", "uh,"])   // = the fixture's flags
        #expect(zip(end.words, end.words.dropFirst()).allSatisfy { $0.start <= $1.start })

        let statuses = log.updates.filter { $0.0 == "demo" }.map(\.1.status)
        #expect(statuses.first == .queued)
        #expect(statuses.contains(.running))
        #expect(statuses.last == .ready)
        let running = log.updates.filter { $0.1.status == .running }.map(\.1.progress)
        #expect(zip(running, running.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript-raw/fixture.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcribe-audio.wav").path))
    }

    @Test func unknownAndUnavailableEnginesThrow() async throws {
        let jobs = TranscriptionJobs(engines: [FixtureTranscriber(wordsFile: URL(fileURLWithPath: "/nope.json"))])
        await #expect(throws: TranscriptionJobs.Failure.unknownEngine("voxtral")) {
            try await jobs.start(projectID: "p", source: MediaFixtures.demo, engine: "voxtral", folder: FileManager.default.temporaryDirectory)
        }
        await #expect(throws: TranscriptionJobs.Failure.self) {
            try await jobs.start(projectID: "p", source: MediaFixtures.demo, engine: "fixture", folder: FileManager.default.temporaryDirectory)
        }
        await #expect(throws: TranscriptionJobs.Failure.noEngine) {
            try await jobs.start(projectID: "p", source: MediaFixtures.demo, folder: FileManager.default.temporaryDirectory)
        }
        #expect(await jobs.engines().first?.available == false)
        #expect(await jobs.engines().first?.why != nil)
    }

    @Test func engineFailureIsASentenceAndCancelGoesBackToNone() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = TranscriptionJobs(engines: [FailingTranscriber(), FixtureTranscriber(wordsFile: MediaFixtures.demoProject, delay: .seconds(5))])
        _ = try await jobs.start(projectID: "a", source: MediaFixtures.demo, engine: "failing", folder: dir)
        let failed = await jobs.wait(projectID: "a")
        #expect(failed?.status == .failed)
        #expect(failed?.error == "The engine is out of tea.")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(TranscriptionJobs.workAudioName).path))

        // No audio → failed with a sentence.
        _ = try await jobs.start(projectID: "b", source: dir.appendingPathComponent("missing.mp4"), engine: "fixture", folder: dir)
        let missing = await jobs.wait(projectID: "b")
        #expect(missing?.status == .failed)
        #expect(missing?.error == "The recording is missing: it was moved or deleted.")

        _ = try await jobs.start(projectID: "c", source: MediaFixtures.demo, engine: "fixture", folder: dir)
        try await Task.sleep(for: .milliseconds(300))
        await jobs.cancel(projectID: "c")
        let c = await jobs.state(projectID: "c")
        #expect(c?.status == TranscriptionState.Status.none, "\(String(describing: c))")
    }

    @Test func launchSweepDeletesLeftovers() throws {
        let root = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let p = root.appendingPathComponent("p1")
        try fm.createDirectory(at: p.appendingPathComponent("exports/.abc.partial"), withIntermediateDirectories: true)
        try Data([1]).write(to: p.appendingPathComponent(TranscriptionJobs.workAudioName))
        try Data([1]).write(to: p.appendingPathComponent("exports/fresh.mp4"))
        try Data([1]).write(to: p.appendingPathComponent("project.json"))
        TranscriptionJobs.sweepLeftovers(projectsFolder: root)
        ExportJobs.sweepLeftovers(projectsFolder: root)
        #expect(try fm.contentsOfDirectory(atPath: p.path).sorted() == ["exports", "project.json"])
        #expect(try fm.contentsOfDirectory(atPath: p.appendingPathComponent("exports").path) == ["fresh.mp4"])
        ExportJobs.sweepLeftovers(projectsFolder: root, now: Date().addingTimeInterval(ExportJobs.keepFor + 60))
        #expect(try fm.contentsOfDirectory(atPath: p.appendingPathComponent("exports").path).isEmpty)
    }

    // MARK: Helpers

    private func readInt16(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url).dropFirst(44)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func onsetTimes(_ s: [Int16], rate: Int) -> [Double] {
        var out: [Double] = []
        var quiet = rate   // samples since last loud one
        for (i, v) in s.enumerated() {
            if abs(Int(v)) > 3000 {
                if quiet > rate / 5 { out.append(Double(i) / Double(rate)) }
                quiet = 0
            } else { quiet += 1 }
        }
        return out
    }
}

struct FailingTranscriber: Transcriber {
    let id = "failing", name = "Failing", isLocal = true
    struct Oops: LocalizedError { var errorDescription: String? { "The engine is out of tea." } }
    func availability() async -> TranscriberAvailability { .available }
    func transcribe(audio: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptResult { throw Oops() }
}

final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(String, TranscriptionState)] = []
    func add(_ id: String, _ s: TranscriptionState) { lock.withLock { log.append((id, s)) } }
    var updates: [(String, TranscriptionState)] { lock.withLock { log } }
}
