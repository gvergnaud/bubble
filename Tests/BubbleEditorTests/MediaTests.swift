// Owner: E2 (media). Waveform, Poster, Exporter, ExportJobs on web/fixtures/demo.mp4 and synthetic media.
// Exports go to temp folders; the source is never written (checked by hash).
@testable import BubbleEditor
import CryptoKit
import ImageIO
import Foundation
import Testing

// Time limit: a stalled render must fail the test, never hang the gate (it did once: m_423). 2 min, above
// the export's own 60 s stall watchdog, so a real stall fails as Exporter.Failure.stalled (it says where)
// and a slow loaded gate (exports run 3× slower there) doesn't fail at all.
@Suite(.serialized, .timeLimit(.minutes(2))) struct MediaTests {
    let frame = 1.0 / 30

    // MARK: Waveform

    @Test func waveformMatchesTheFixture() async throws {
        let peaks = try await Waveform.peaks(of: MediaFixtures.demo)
        struct W: Decodable { var peaksPerSecond: Int; var peaks: String }
        let fixture = try JSONDecoder().decode(W.self, from: Data(contentsOf: MediaFixtures.demoWaveform))
        let expected = Data(base64Encoded: fixture.peaks)!
        #expect(fixture.peaksPerSecond == Waveform.peaksPerSecond)
        #expect(abs(peaks.count - Int((68.638 * 50).rounded(.up))) <= 2, "\(peaks.count) peaks")
        #expect(abs(peaks.count - expected.count) <= 2)
        // Same formula, different AAC decoders (ffmpeg vs Apple): close, not identical.
        let n = min(peaks.count, expected.count)
        var diff = 0
        for i in 0..<n { diff += abs(Int(peaks[i]) - Int(expected[i])) }
        let mean = Double(diff) / Double(n)
        #expect(mean < 6, "mean |Δ| = \(mean)")
        #expect(peaks.max()! > 100)
    }

    @Test func peakAccumulatorFormula() {
        var acc = PeakAccumulator(samplesPerPeak: 4, gain: 1.4)
        acc.add([0, 0.1, -0.5, 0.2, 0.9, 0, 0, 0, 0.05])
        let out = [UInt8](acc.finish())
        #expect(out == [UInt8(0.5 * 255 * 1.4), 255, UInt8(0.05 * 255 * 1.4)])
    }

    @Test func noAudioGivesNoPeaks() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("silent.mp4")
        try await SyntheticAV.make(url, seconds: 1, beeps: [])
        // has an audio track (silence): flat zero peaks
        let peaks = try await Waveform.peaks(of: url)
        #expect(abs(peaks.count - 50) <= 2)
        #expect(peaks.allSatisfy { $0 == 0 })
    }

    // MARK: Poster

    @Test func posterIsAJPEGAt1280() async throws {
        let jpeg = try await Poster.jpeg(of: MediaFixtures.demo)
        #expect(jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
        let small = try await Poster.jpeg(of: MediaFixtures.demo, maxWidth: 640)
        #expect(small.count < jpeg.count)
        let src = CGImageSourceCreateWithData(small as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 640)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 360)
    }

    // MARK: Exporter

    @Test func frameSlotsDropAndRepeat() {
        var s = FrameSlots(total: 6)
        #expect(s.place(time: 0) == .init(repeats: 0..<0, slot: 0))
        #expect(s.place(time: 0.02) == .init(repeats: 1..<1, slot: 1))      // round(0.6) = 1
        #expect(s.place(time: 0.04) == .init(repeats: 2..<2, slot: nil))    // round(1.2) = 1, taken: dropped (speed-up)
        #expect(s.place(time: 0.15) == .init(repeats: 2..<5, slot: 5))      // gap: slots 2-4 repeat (slow-down / static)
        #expect(s.place(time: 0.3) == .init(repeats: 6..<6, slot: nil))     // past the end
        #expect(s.finish() == 6..<6)

        var late = FrameSlots(total: 4)
        #expect(late.place(time: 0.1) == .init(repeats: 0..<3, slot: 3))    // first frame late: it fills from 0
        var short = FrameSlots(total: 5)
        _ = short.place(time: 0)
        #expect(short.finish() == 1..<5)                                     // last frame held to the end
    }

    @Test func outputDurationIsSumOfKeptOverRate() {
        let p = [MediaPiece(start: 0, end: 2, rate: 1), MediaPiece(start: 3, end: 6, rate: 1.5), MediaPiece(start: 6, end: 7, rate: 0.5)]
        #expect(abs(Exporter.outputDuration(p) - 6) < 1e-9)
        #expect(Exporter.frameCount(duration: 6) == 180)
        #expect(Exporter.clamp([MediaPiece(start: -1, end: 2, rate: 1), MediaPiece(start: 2, end: 2, rate: 1),
                                MediaPiece(start: 5, end: 99, rate: 2)], to: 10)
                == [MediaPiece(start: 0, end: 2, rate: 1), MediaPiece(start: 5, end: 10, rate: 2)])
    }

    /// The fixture project's own edits (2 cuts + a 1.5× range): exact duration, 30 fps CFR, A/V together,
    /// source untouched.
    @Test func exportsTheFixtureProject() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = try JSONDecoder().decode(MediaFixtures.DemoEdits.self, from: Data(contentsOf: MediaFixtures.demoProject))
        let pieces = MediaFixtures.pieces(duration: project.video.duration, segments: project.edits.segments.map { ($0.start, $0.end, $0.rate) })
            .map { MediaPiece(start: $0.start, end: $0.end, rate: $0.rate) }
        let expected = Exporter.outputDuration(pieces)
        #expect(abs(expected - 62.585) < 0.01)
        let before = try sha256(MediaFixtures.demo)
        let out = dir.appendingPathComponent("out.mp4")
        let progress = ProgressLog()
        let result = try await Exporter.render(source: MediaFixtures.demo, pieces: pieces, to: out) { progress.add($0) }

        #expect(try sha256(MediaFixtures.demo) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["out.mp4"])
        #expect(abs(result.duration - expected) <= frame, "got \(result.duration), expected \(expected)")
        #expect(result.frames == Exporter.frameCount(duration: expected))
        let probe = try await Probe.read(out)
        #expect(abs(probe.videoDuration - expected) <= frame)
        #expect(abs(probe.audioDuration - probe.videoDuration) <= 0.05, "audio \(probe.audioDuration) vs video \(probe.videoDuration)")
        expectCFR(probe.frameTimes, count: result.frames)
        let values = progress.values
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values.count > 10)
    }

    /// Flashes and beeps at known source times, through a cut, a 1.5× and a 0.5× range: each one lands at
    /// its output time (± 1 frame), together, and the beeps keep their 1 kHz pitch.
    @Test func cutsAndSpeedKeepSyncAndPitch() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("beeps.mp4")
        let beeps = (0..<12).map { Double($0) + 0.4 }
        try await SyntheticAV.make(src, seconds: 12, beeps: beeps)
        let plan = MediaFixtures.pieces(duration: 12, segments: [(2.5, 3.5, 0), (4.5, 8.5, 1.5), (9.5, 10.6, 0.5)])
        let out = dir.appendingPathComponent("edited.mp4")
        let result = try await Exporter.render(source: src, pieces: plan.map { MediaPiece(start: $0.start, end: $0.end, rate: $0.rate) }, to: out)
        let expected = plan.reduce(0) { $0 + ($1.end - $1.start) / $1.rate }
        #expect(abs(result.duration - expected) <= frame)

        let probe = try await Probe.read(out)
        expectCFR(probe.frameTimes, count: result.frames)
        let wanted = beeps.compactMap { MediaFixtures.outputTime(of: $0, in: plan) }
        #expect(wanted.count == 11)                                   // the 3.4 beep is cut
        #expect(probe.flashes.count == wanted.count, "flashes \(probe.flashes)")
        #expect(probe.beeps.count == wanted.count, "beeps \(probe.beeps)")
        for (i, t) in wanted.enumerated() where i < probe.flashes.count && i < probe.beeps.count {
            #expect(abs(probe.flashes[i] - t) <= frame + 0.001, "flash \(i): \(probe.flashes[i]) vs \(t)")
            #expect(abs(probe.beeps[i] - t) <= 0.04, "beep \(i): \(probe.beeps[i]) vs \(t)")
            #expect(abs(probe.beeps[i] - probe.flashes[i]) <= 0.045, "A/V \(i): beep \(probe.beeps[i]) flash \(probe.flashes[i])")
        }
        // Pitch: a beep inside the 1.5× range and the one inside the 0.5× range are still ~1 kHz.
        for source in [5.4, 10.4] {
            let t = MediaFixtures.outputTime(of: source, in: plan)!
            let f = probe.frequency(at: t + 0.015, length: 0.035)
            #expect(abs(f - 1000) < 100, "beep at source \(source): \(f) Hz")
        }
    }

    /// A variable-frame-rate source (the recorder skips frames on a static screen) comes out 30 fps CFR,
    /// flashes in place.
    @Test func variableFrameRateBecomesCFR() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("vfr.mp4")
        try await SyntheticAV.make(src, seconds: 6, beeps: [1.4, 3.9], variableFrameRate: true)
        let out = dir.appendingPathComponent("cfr.mp4")
        let result = try await Exporter.render(source: src, pieces: [MediaPiece(start: 0, end: 6, rate: 1)], to: out)
        #expect(result.frames == 180)
        let probe = try await Probe.read(out)
        expectCFR(probe.frameTimes, count: 180)
        #expect(probe.flashes.count == 2)
        if probe.flashes.count == 2 {
            #expect(abs(probe.flashes[0] - 1.4) <= frame + 0.001)
            #expect(abs(probe.flashes[1] - 3.9) <= frame + 0.001)
        }
    }

    /// No mic and no computer sound: the recording has no audio track, the export is video only.
    @Test func noAudioTrackExportsVideoOnly() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("mute.mp4")
        try await SyntheticAV.make(src, seconds: 4, beeps: [1.4], audio: false)
        let out = dir.appendingPathComponent("mute-out.mp4")
        let result = try await Exporter.render(source: src, pieces: [MediaPiece(start: 0, end: 1, rate: 1), MediaPiece(start: 2, end: 4, rate: 2)], to: out)
        #expect(abs(result.duration - 2) <= frame)
        let probe = try await Probe.read(out)
        #expect(probe.audioDuration == 0)
        expectCFR(probe.frameTimes, count: 60)
        #expect(try await Waveform.peaks(of: src).isEmpty)
    }

    @Test func notEnoughSpaceFailsBeforeRendering() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let needed = Exporter.estimatedBytes(width: 1280, height: 720, duration: 2)
        #expect(needed == Int64(((4_000_000.0 + 128_000) / 8 * 2 * 1.1).rounded(.up)))   // 4 Mb/s floor at 720p
        await #expect(throws: Exporter.Failure.notEnoughSpace(needed: needed)) {
            try await Exporter.render(source: MediaFixtures.demo, pieces: [MediaPiece(start: 0, end: 2, rate: 1)],
                                      to: dir.appendingPathComponent("x.mp4"), bytesFree: { _ in 1000 })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(Exporter.Failure.notEnoughSpace(needed: 2_340_000_000).description == "Not enough space to export (needs ~2.3 GB).")
    }

    /// Audio that runs past the video (and past the last piece): the audio side stops early while the
    /// video still reads. With one reader for both tracks this stalled forever; one reader per track doesn't.
    @Test func audioLongerThanVideoDoesNotStall() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("long-audio.mp4")
        try await SyntheticAV.make(src, seconds: 6, beeps: [1.4, 4.4], audioSeconds: 12)
        for pieces in [[MediaPiece(start: 0, end: 6, rate: 1)],
                       [MediaPiece(start: 0, end: 2, rate: 1), MediaPiece(start: 3, end: 6, rate: 2)],
                       [MediaPiece(start: 0, end: 12, rate: 1)]] {
            let out = dir.appendingPathComponent("out.mp4")
            let result = try await Exporter.render(source: src, pieces: pieces, to: out, stallTimeout: .seconds(20))
            #expect(abs(result.duration - Exporter.outputDuration(pieces)) <= frame, "\(pieces)")
            let probe = try await Probe.read(out)
            expectCFR(probe.frameTimes, count: result.frames)
        }
    }

    @Test func aStallFailsInsteadOfHanging() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: Exporter.Failure.stalled) {
            try await Exporter.render(source: MediaFixtures.demo, pieces: [MediaPiece(start: 0, end: 60, rate: 1)],
                                      to: dir.appendingPathComponent("x.mp4"), stallTimeout: .zero)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    // MARK: Sound at the joins

    @Test func joinPlanOverlapsNeighboursAroundEachJoin() {
        let pieces = [MediaPiece(start: 0, end: 2, rate: 1), MediaPiece(start: 3, end: 5, rate: 1), MediaPiece(start: 5, end: 7, rate: 1.5)]
        let plan = AudioJoinPlan.make(pieces: pieces, outputStarts: [0, 2, 4], end: 4 + 2 / 1.5, sourceDuration: 10,
                                      crossfade: 0.04, sampleRate: 48_000)
        #expect(plan.total == 256_000)
        // 20 ms each side of a join, + 200 ms read before (thrown away) and after each part.
        let want: [(Double, Double, Int, Int, Int, Int, Int, Bool)] = [   // source start/end, output start, length, preRoll, fades, continues
            (0, 2.22, 0, 96_960, 0, 0, 1920, false),
            (2.78, 5.22, 95_040, 97_920, 9600, 1920, 1920, true),
            (5 - 0.22 * 1.5, 7 + 0.2 * 1.5, 191_040, 64_960, 9600, 1920, 0, false),
        ]
        #expect(plan.parts.count == 3)
        for (p, w) in zip(plan.parts, want) {
            #expect(abs(p.sourceStart - w.0) < 1e-9 && abs(p.sourceEnd - w.1) < 1e-9, "\(p)")
            #expect(p.outputStart == w.2 && p.length == w.3 && p.preRoll == w.4, "\(p)")
            #expect(p.fadeIn == w.5 && p.fadeOut == w.6 && p.continuesIntoNext == w.7, "\(p)")
        }
        // A piece of 10 ms: its fades shrink to fit (never longer than half of it on each side).
        let tiny = AudioJoinPlan.make(pieces: [MediaPiece(start: 0, end: 1, rate: 1), MediaPiece(start: 2, end: 2.01, rate: 1), MediaPiece(start: 3, end: 4, rate: 1)],
                                      outputStarts: [0, 1, 1.01], end: 2.01, sourceDuration: 4, crossfade: 0.04, sampleRate: 48_000)
        #expect(tiny.parts[1].fadeIn == 480 && tiny.parts[1].fadeOut == 480)
        // No sound before 0 / after the end of the recording to fade with: no fade there.
        let edge = AudioJoinPlan.make(pieces: [MediaPiece(start: 0, end: 1, rate: 1), MediaPiece(start: 1.5, end: 2, rate: 1)],
                                      outputStarts: [0, 1], end: 1.5, sourceDuration: 1.0, crossfade: 0.04, sampleRate: 48_000)
        #expect(edge.parts[0].fadeOut == 0)
        // Gains: equal power keeps out² + in² = 1; equal gain keeps out + in = 1.
        for k in [0, 10, 959, 1919] {
            let p = AudioJoinPlan.gains(k, of: 1920, equalPower: true), g = AudioJoinPlan.gains(k, of: 1920, equalPower: false)
            #expect(abs(p.out * p.out + p.in * p.in - 1) < 1e-5)
            #expect(abs(g.out + g.in - 1) < 1e-5)
        }
    }

    /// A steady tone cut where its phase jumps: a butt splice clicks (one big sample jump), the crossfade
    /// doesn't. Measured as the largest sample-to-sample step near the join vs in the steady tone.
    @Test func cutJoinHasNoClick() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("tone.mp4")
        try await SyntheticAV.make(src, seconds: 4, beeps: [], signal: { Float(0.5 * sin(2 * .pi * 300 * $0)) })
        // Cut at a crest (+0.5) and back in at a trough (-0.5): a butt splice jumps by 1.0.
        let pieces = [MediaPiece(start: 0, end: 2 + 1 / 1200.0, rate: 1), MediaPiece(start: 2.1225 + 1 / 1200.0, end: 4, rate: 1)]
        func steps(crossfade: Double) async throws -> (join: Float, steady: Float) {
            let out = dir.appendingPathComponent("tone-\(crossfade).mp4")
            try await Exporter.render(source: src, pieces: pieces, to: out, crossfade: crossfade)
            let samples = try await Probe.read(out).samples
            func maxStep(_ a: Double, _ b: Double) -> Float {
                var m: Float = 0
                for i in (Int(a * 48_000) + 1)..<Int(b * 48_000) { m = max(m, abs(samples[i] - samples[i - 1])) }
                return m
            }
            return (maxStep(1.97, 2.03), maxStep(0.5, 1.5))
        }
        let smooth = try await steps(crossfade: Exporter.crossfade)
        let butt = try await steps(crossfade: 0)
        #expect(butt.join > 3 * butt.steady, "the test must see a butt splice's click: \(butt)")
        #expect(smooth.join <= 1.3 * smooth.steady, "click at the join: \(smooth)")
    }

    /// Noise through a cut and a speed range: the level stays even across every join (no dip, no bump),
    /// in 10 ms windows, within 2 dB of the steady level.
    @Test func joinsKeepTheLevel() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("noise.mp4")
        try await SyntheticAV.make(src, seconds: 6, beeps: [], signal: { t in
            var x = UInt64(t * 48_000 + 0.5) &* 0x9E37_79B9_7F4A_7C15
            x ^= x >> 31; x = x &* 0xBF58_476D_1CE4_E5B9; x ^= x >> 29
            return Float(Double(x % 10_000) / 10_000 * 2 - 1) * 0.3
        })
        let pieces = [MediaPiece(start: 0, end: 2, rate: 1), MediaPiece(start: 2.5, end: 3, rate: 1),
                      MediaPiece(start: 3, end: 4, rate: 1.5), MediaPiece(start: 4, end: 6, rate: 1)]
        let out = dir.appendingPathComponent("noise-out.mp4")
        try await Exporter.render(source: src, pieces: pieces, to: out)
        let samples = try await Probe.read(out).samples
        func rms(_ a: Double) -> Double {
            let i = Int(a * 48_000)
            let w = samples[i..<(i + 480)]
            return sqrt(w.reduce(0) { $0 + Double($1 * $1) } / 480)
        }
        // Each side's own level (the stretcher plays noise ~1 dB softer at 1.5×), 40-100 ms from the join;
        // across the join (±40 ms) the level stays within 2 dB of the two sides' mean. A missing side would be
        // -3 dB at the middle, a butt splice of two loud sides +3 dB: both fail.
        func level(_ a: Double, _ b: Double) -> Double {
            let w = stride(from: a, to: b, by: 0.01).map(rms)
            return 20 * log10(w.reduce(0, +) / Double(w.count))
        }
        for join in [2.0, 2.5, 2.5 + 1 / 1.5] {   // the cut, then into and out of 1.5×
            let sides = (level(join - 0.1, join - 0.04) + level(join + 0.04, join + 0.1)) / 2
            for t in stride(from: join - 0.04, to: join + 0.04, by: 0.005) {
                let db = 20 * log10(rms(t)) - sides
                #expect(abs(db) < 2, "level at \(t) (join \(join)): \(db) dB")
            }
        }
    }

    /// 100 short cuts, then a 1.5×, a 2× and a 0.5× range: every part's sound is placed from absolute
    /// output times, so after 106 joins the last flashes and beeps are still where they belong (± 1 frame)
    /// and together.
    @Test func manyJoinsDoNotDrift() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("many.mp4")
        let beeps = (0..<60).map { Double($0) + 0.4 }
        try await SyntheticAV.make(src, seconds: 60, beeps: beeps, variableFrameRate: true)
        var segments: [(Double, Double, Double)] = []
        for k in 0..<50 {   // two 50 ms cuts per second, away from the beeps
            segments.append((Double(k) + 0.6, Double(k) + 0.65, 0))
            segments.append((Double(k) + 0.8, Double(k) + 0.85, 0))
        }
        segments += [(50.55, 52.55, 1.5), (53.55, 55.55, 2), (56.55, 57.55, 0.5)]
        let plan = MediaFixtures.pieces(duration: 60, segments: segments)
        let out = dir.appendingPathComponent("many-out.mp4")
        let result = try await Exporter.render(source: src, pieces: plan.map { MediaPiece(start: $0.start, end: $0.end, rate: $0.rate) }, to: out)
        #expect(plan.count == 107)
        #expect(abs(result.duration - plan.reduce(0) { $0 + ($1.end - $1.start) / $1.rate }) <= frame)
        let probe = try await Probe.read(out)
        expectCFR(probe.frameTimes, count: result.frames)
        let wanted = beeps.compactMap { MediaFixtures.outputTime(of: $0, in: plan) }
        #expect(probe.flashes.count == wanted.count && probe.beeps.count == wanted.count, "\(probe.flashes.count) flashes, \(probe.beeps.count) beeps, \(wanted.count) wanted")
        guard probe.flashes.count == wanted.count, probe.beeps.count == wanted.count else { return }
        for i in (wanted.count - 3)..<wanted.count {   // the end, after every join
            #expect(abs(probe.flashes[i] - wanted[i]) <= frame + 0.001, "flash \(i): \(probe.flashes[i]) vs \(wanted[i])")
            #expect(abs(probe.beeps[i] - wanted[i]) <= frame, "beep \(i): \(probe.beeps[i]) vs \(wanted[i])")
            #expect(abs(probe.beeps[i] - probe.flashes[i]) <= frame, "A/V \(i): \(probe.beeps[i] - probe.flashes[i])")
        }
    }

    /// Not a check: BUBBLE_JOIN_BENCH=1 prints the render time of a 10 min synthetic source without edits
    /// and with 200 cuts (docs/editor-architecture.md §4).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUBBLE_JOIN_BENCH"] != nil), .timeLimit(.minutes(10)))
    func joinBenchmark() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("ten-min.mp4")
        try await SyntheticAV.make(src, seconds: 600, beeps: (0..<600).map { Double($0) + 0.4 }, variableFrameRate: true)
        let whole = [MediaPiece(start: 0, end: 600, rate: 1)]
        var segments: [(Double, Double, Double)] = []
        for k in 0..<200 {
            let at = Double(k) * 3 + 1.6
            segments.append((at, at + 0.1, 0))
        }
        let cuts = MediaFixtures.pieces(duration: 600, segments: segments).map { MediaPiece(start: $0.start, end: $0.end, rate: $0.rate) }
        func time(_ pieces: [MediaPiece], crossfade: Double) async throws -> Double {
            let t0 = ContinuousClock.now
            try await Exporter.render(source: src, pieces: pieces, to: dir.appendingPathComponent("b.mp4"), crossfade: crossfade)
            let d = ContinuousClock.now - t0
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let a = try await time(whole, crossfade: Exporter.crossfade)
        let b = try await time(cuts, crossfade: Exporter.crossfade)
        let c = try await time(cuts, crossfade: 0)
        print(String(format: "JOIN BENCH: 10 min source, no cut %.1f s; 200 cuts (201 parts) %.1f s (%.2fx); 200 cuts butt-spliced %.1f s", a, b, b / a, c))
    }

    /// Not a check: BUBBLE_JOIN_SAMPLES=<folder> writes the fixture project's export with and without the
    /// crossfade, to listen to the joins (scripts/test.sh --filter writeJoinSamples).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUBBLE_JOIN_SAMPLES"] != nil))
    func writeJoinSamples() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BUBBLE_JOIN_SAMPLES"]!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let project = try JSONDecoder().decode(MediaFixtures.DemoEdits.self, from: Data(contentsOf: MediaFixtures.demoProject))
        let pieces = MediaFixtures.pieces(duration: project.video.duration, segments: project.edits.segments.map { ($0.start, $0.end, $0.rate) })
            .map { MediaPiece(start: $0.start, end: $0.end, rate: $0.rate) }
        try await Exporter.render(source: MediaFixtures.demo, pieces: pieces, to: dir.appendingPathComponent("demo-joins-before.mp4"), crossfade: 0)
        try await Exporter.render(source: MediaFixtures.demo, pieces: pieces, to: dir.appendingPathComponent("demo-joins-after.mp4"))
    }

    @Test func everythingCutIsAnError() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: Exporter.Failure.nothingKept) {
            try await Exporter.render(source: MediaFixtures.demo, pieces: [], to: dir.appendingPathComponent("x.mp4"))
        }
    }

    // MARK: ExportJobs

    @Test func exportJobRunsAndReplacesThePreviousOne() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = ExportJobs()
        let pieces = [MediaPiece(start: 10, end: 14, rate: 2)]
        let first = await jobs.start(projectID: "demo", revision: 3, source: MediaFixtures.demo, pieces: pieces, title: "Bubble demo", folder: dir)
        #expect(first.status == .queued || first.status == .running)
        #expect(first.duration == 2)
        #expect(first.filename == "Bubble demo (edited).mp4")
        let done = await jobs.wait(first.id)
        #expect(done?.status == .done)
        #expect(done?.progress == 1)
        let file = try #require(done?.file)
        #expect(file.lastPathComponent == "\(first.id).mp4")
        #expect(abs((done?.duration ?? 0) - 2) <= frame)
        #expect((done?.bytes ?? 0) > 10_000)

        let second = await jobs.start(projectID: "demo", revision: 4, source: MediaFixtures.demo, pieces: pieces, title: "Bubble demo", folder: dir)
        #expect(!FileManager.default.fileExists(atPath: file.path))          // previous export deleted
        _ = await jobs.wait(second.id)
        #expect(await jobs.latest(projectID: "demo")?.id == second.id)
        #expect(await jobs.latest(projectID: "other") == nil)
        #expect(await jobs.job("nope") == nil)
    }

    @Test func cancelStopsAndDeletes() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = ExportJobs()
        let whole = [MediaPiece(start: 0, end: 68.6, rate: 1)]
        let job = await jobs.start(projectID: "demo", revision: 1, source: MediaFixtures.demo, pieces: whole, title: "t", folder: dir)
        let queued = await jobs.start(projectID: "other", revision: 1, source: MediaFixtures.demo, pieces: whole, title: "t", folder: dir)
        #expect(await jobs.job(queued.id)?.status == .queued)              // one export at a time
        try await Task.sleep(for: .milliseconds(400))
        #expect(await jobs.cancel(queued.id)?.status == .canceled)
        #expect(await jobs.cancel(job.id)?.status == .canceled)
        let end = await jobs.wait(job.id)
        #expect(end?.status == .canceled)
        #expect(end?.file == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left.isEmpty, "\(left)")
    }

    @Test func failedRenderGivesASentence() async throws {
        let dir = try MediaFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jobs = ExportJobs()
        let job = await jobs.start(projectID: "p", revision: 1, source: dir.appendingPathComponent("missing.mp4"),
                                   pieces: [MediaPiece(start: 0, end: 1, rate: 1)], title: "t", folder: dir)
        let end = await jobs.wait(job.id)
        #expect(end?.status == .failed)
        #expect(end?.error == "The recording is missing: it was moved or deleted.")
    }

    @Test func filenames() {
        #expect(ExportJobs.filename(title: "Demo: v2/final") == "Demo v2final (edited).mp4")
        #expect(ExportJobs.filename(title: "  ") == "Recording (edited).mp4")
        #expect(ExportJobs.filename(title: "..hidden") == "hidden (edited).mp4")
    }

    // MARK: Helpers

    private func expectCFR(_ times: [Double], count: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(times.count - count) <= 1, "\(times.count) frames, expected \(count)", sourceLocation: sourceLocation)
        let bad = zip(times, times.dropFirst()).filter { abs(($1 - $0) - frame) > 0.001 }
        #expect(bad.isEmpty, "\(bad.count) gaps ≠ 1/30 s, first: \(bad.prefix(3))", sourceLocation: sourceLocation)
        #expect(abs((times.first ?? 1) - 0) < 0.001, sourceLocation: sourceLocation)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Double] = []
    func add(_ p: Double) { lock.withLock { log.append(p) } }
    var values: [Double] { lock.withLock { log } }
}
