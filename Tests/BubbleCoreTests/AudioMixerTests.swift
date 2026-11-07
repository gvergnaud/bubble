// Owner: QA track. AudioMixer on synthetic sample buffers (docs/architecture.md §3.2, §8.1).
// Host times are synthetic: origin 100 s. maxWait 0.2 s, so pull(upToHost: origin + T + 0.2) must
// give everything up to T.
import AVFoundation
import BubbleCore
import BubbleTesting
import CoreMedia
import Testing

private let origin = CMTime(seconds: 100, preferredTimescale: 48_000)
private func host(_ s: Double) -> CMTime { CMTimeAdd(origin, CMTime(seconds: s, preferredTimescale: 48_000)) }

/// Pushes `seconds` of a source in 10 ms chunks, starting at `from` seconds.
private func feed(_ mixer: AudioMixer, _ source: AudioSource, from: Double = 0, seconds: Double, rate: Double = 48_000,
                  value: Float? = nil, frequency: Double = 440) {
    let chunk = Int(rate / 100)
    let first = Int64((from * rate).rounded())
    let total = Int((seconds * rate).rounded())
    var done = 0
    while done < total {
        let n = min(chunk, total - done)
        let start = first + Int64(done)
        let sb = value.map { SyntheticAudio.constantSampleBuffer($0, frames: n, startSample: start, sampleRate: rate, origin: origin) }
            ?? SyntheticAudio.sineSampleBuffer(frames: n, startSample: start, sampleRate: rate, frequency: frequency, origin: origin)
        mixer.push(sb, from: source)
        done += n
    }
}

private struct Mixed {
    var samples: [Float] = []
    var start: Double = .nan     // host seconds - origin of the first chunk
    var chunkSizes: [Int] = []
    var contiguous = true
    var formatOK = true
}

private func drain(_ mixer: AudioMixer, upTo seconds: Double) -> Mixed {
    var m = Mixed()
    var expectedNext: CMTime?
    for (buf, time) in mixer.pull(upToHost: host(seconds)) {
        if m.start.isNaN { m.start = CMTimeSubtract(time, origin).seconds }
        if let e = expectedNext, abs(CMTimeSubtract(time, e).seconds) > 0.5 / 48_000 { m.contiguous = false }
        expectedNext = CMTimeAdd(time, CMTime(value: CMTimeValue(buf.frameLength), timescale: 48_000))
        if buf.format.sampleRate != 48_000 || buf.format.channelCount != 1 || buf.format.commonFormat != .pcmFormatFloat32 { m.formatOK = false }
        m.chunkSizes.append(Int(buf.frameLength))
        m.samples += UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
    }
    return m
}

/// True if `s[r]` exists and every sample in it passes (a short output fails instead of crashing).
private func all(_ s: [Float], _ r: Range<Int>, _ pred: (Float) -> Bool) -> Bool {
    r.upperBound <= s.count && s[r].allSatisfy(pred)
}

private func zeroCrossings(_ s: ArraySlice<Float>) -> Int {
    var n = 0, prev = s.first ?? 0
    for x in s.dropFirst() { if (prev < 0) != (x < 0) { n += 1 }; prev = x }
    return n
}

@Suite
struct AudioMixerTests {
    @Test func oneSourcePassesThrough() {
        let mixer = AudioMixer(sources: [.microphone], maxWait: 0.2)
        feed(mixer, .microphone, seconds: 1)
        let m = drain(mixer, upTo: 1.2)
        #expect(m.formatOK && m.contiguous)
        #expect(abs(m.start) < 0.001, "starts at the first sample, got \(m.start)")
        #expect(m.samples.count >= 48_000 - 1024 && m.samples.count <= 48_000, "\(m.samples.count)")
        #expect(m.chunkSizes.allSatisfy { $0 == 1024 }, "\(Set(m.chunkSizes))")
        let src = SyntheticAudio.pcm(frames: 4800, startSample: 0)
        if m.samples.count >= 4800 {
            let maxDiff = (0..<4800).map { abs(m.samples[$0] - src.floatChannelData![0][$0]) }.max()!
            #expect(maxDiff < 1e-4, "same samples out as in: \(maxDiff)")
        }
    }

    @Test func twoSourcesAreSummed() {
        let mixer = AudioMixer(sources: [.microphone, .computer], maxWait: 0.2)
        feed(mixer, .microphone, seconds: 1, value: 0.25)
        feed(mixer, .computer, seconds: 1, value: 0.5)
        let m = drain(mixer, upTo: 1.2)
        #expect(m.samples.count >= 40_000, "\(m.samples.count)")
        #expect(all(m.samples, 1000..<40_000) { abs($0 - 0.75) < 1e-3 }, "min \(m.samples.min() ?? .nan) max \(m.samples.max() ?? .nan)")
    }

    @Test func sumIsClamped() {
        let mixer = AudioMixer(sources: [.microphone, .computer], maxWait: 0.2)
        feed(mixer, .microphone, seconds: 0.5, value: 0.8)
        feed(mixer, .computer, seconds: 0.5, value: 0.8)
        let m = drain(mixer, upTo: 0.7)
        #expect(!m.samples.isEmpty)
        #expect(m.samples.allSatisfy { $0 <= 1.0 && $0 >= -1.0 })
        #expect(all(m.samples, 100..<20_000) { abs($0 - 1.0) < 1e-3 }, "\(m.samples.count)")
    }

    @Test func resamples44_1kTo48k() {
        let mixer = AudioMixer(sources: [.microphone], maxWait: 0.2)
        feed(mixer, .microphone, seconds: 1, rate: 44_100)
        let m = drain(mixer, upTo: 1.2)
        #expect(m.formatOK && m.contiguous)
        #expect(m.samples.count >= 48_000 - 2048 && m.samples.count <= 48_000 + 1024, "\(m.samples.count)")
        // 440 Hz stays 440 Hz: ~880 zero crossings per second.
        let second = m.samples.prefix(46_080)
        let zc = Double(zeroCrossings(second)) * 48_000 / Double(second.count)
        #expect(abs(zc - 880) < 10, "\(zc) crossings/s")
    }

    @Test func secondSourceStartingLater() {
        let mixer = AudioMixer(sources: [.microphone, .computer], maxWait: 0.2)
        feed(mixer, .microphone, seconds: 1, value: 0.25)
        feed(mixer, .computer, from: 0.5, seconds: 0.5, value: 0.5)
        let m = drain(mixer, upTo: 1.2)
        #expect(all(m.samples, 1000..<23_000) { abs($0 - 0.25) < 1e-3 }, "mic alone before 0.5 s")
        #expect(all(m.samples, 25_000..<45_000) { abs($0 - 0.75) < 1e-3 }, "both after 0.5 s")
    }

    @Test func holesBecomeSilence() {
        let mixer = AudioMixer(sources: [.microphone], maxWait: 0.2)
        feed(mixer, .microphone, from: 0, seconds: 0.5, value: 0.25)
        feed(mixer, .microphone, from: 1.0, seconds: 0.5, value: 0.25)
        let m = drain(mixer, upTo: 1.7)
        #expect(m.contiguous, "no jump in time")
        #expect(m.samples.count >= 70_000, "\(m.samples.count)")
        #expect(all(m.samples, 26_000..<46_000) { $0 == 0 }, "silence in the hole")
        #expect(all(m.samples, 50_000..<70_000) { abs($0 - 0.25) < 1e-3 }, "back after the hole, at the right time")
    }

    @Test func deadSourceDoesNotStall() {
        let mixer = AudioMixer(sources: [.microphone, .computer], maxWait: 0.2)
        feed(mixer, .microphone, seconds: 1, value: 0.25)    // computer sends nothing at all
        let m = drain(mixer, upTo: 1.2)
        #expect(m.samples.count >= 48_000 - 1024, "\(m.samples.count)")
        #expect(all(m.samples, 1000..<40_000) { abs($0 - 0.25) < 1e-3 })
    }

    @Test func pullIsIncremental() {
        let mixer = AudioMixer(sources: [.microphone], maxWait: 0.2)
        feed(mixer, .microphone, seconds: 2)
        let a = drain(mixer, upTo: 1.2)
        let b = drain(mixer, upTo: 2.2)
        #expect(a.samples.count + b.samples.count >= 96_000 - 1024)
        #expect(abs(b.start - (a.start + Double(a.samples.count) / 48_000)) < 1e-4, "the second pull follows the first")
        #expect(drain(mixer, upTo: 2.2).samples.isEmpty, "nothing twice")
    }

    @Test func nothingIsEmittedPastHostMinusMaxWait() {
        let mixer = AudioMixer(sources: [.microphone], maxWait: 0.2)
        feed(mixer, .microphone, seconds: 1)
        let m = drain(mixer, upTo: 0.7)                      // ready up to 0.5 s
        #expect(Double(m.samples.count) / 48_000 <= 0.5 + 1e-3, "\(m.samples.count)")
    }
}
