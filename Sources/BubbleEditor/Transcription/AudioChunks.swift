// Owner: E2 (transcription). docs/editor-architecture.md §5: long audio cut into pieces an API takes
// (Voxtral 3: ≤ 15 min per call), cut in the quietest moment before the limit, each piece running on
// `overlap` seconds past its cut so the next piece's speakers can be matched to this one's.
import Foundation

public enum AudioChunks {
    public struct Plan: Sendable, Equatable {
        /// Longest piece, overlap included (seconds).
        public var maxLength: Double
        /// Seconds a piece runs past its cut (the next piece starts at the cut).
        public var overlap: Double
        /// The cut is searched in the last `searchWindow` seconds before the limit.
        public var searchWindow: Double

        public init(maxLength: Double = 15 * 60, overlap: Double = 20, searchWindow: Double = 60) {
            self.maxLength = maxLength; self.overlap = overlap; self.searchWindow = searchWindow
        }
    }

    public struct Chunk: Sendable, Equatable {
        /// Source seconds this piece covers ([start, end), `end` includes the overlap).
        public var start: Double
        public var end: Double
        public var url: URL
    }

    /// Cut points (source seconds) for audio of `duration` whose loudness is `energy` (one value per
    /// `step` seconds). Pure. One piece when it fits: [].
    static func cuts(energy: [Float], step: Double, duration: Double, plan: Plan) -> [Double] {
        var cuts: [Double] = []
        var start = 0.0
        let room = plan.maxLength - plan.overlap
        precondition(room > plan.searchWindow / 4, "chunk plan too tight")
        while duration - start > plan.maxLength {
            let hi = start + room
            let lo = max(start + room / 2, hi - plan.searchWindow)
            // Quietest 0.5 s window in [lo, hi]: its middle is the cut.
            let w = max(1, Int((0.5 / step).rounded()))
            let a = Int(lo / step), b = min(energy.count - w, Int(hi / step) - w)
            var best = hi, bestEnergy = Float.infinity
            if b > a {
                var sum: Float = energy[a..<(a + w)].reduce(0, +)
                for i in a...b {
                    if i > a { sum += energy[i + w - 1] - energy[i - 1] }
                    if sum <= bestEnergy { bestEnergy = sum; best = (Double(i) + Double(w) / 2) * step }   // ties: the latest (fewer chunks)
                }
            }
            cuts.append(best)
            start = best
        }
        return cuts
    }

    /// Splits a 16-bit mono WAV (AudioExtract's) into chunk files in `folder`. Fits in one piece: the
    /// file itself, not copied.
    public static func split(wav: URL, plan: Plan, into folder: URL) throws -> [Chunk] {
        let data = try Data(contentsOf: wav, options: .mappedIfSafe)
        guard data.count >= 44 else { return [Chunk(start: 0, end: 0, url: wav)] }
        let rate = Double(AudioExtract.sampleRate)
        let samples = (data.count - 44) / 2
        let duration = Double(samples) / rate
        guard duration > plan.maxLength else { return [Chunk(start: 0, end: duration, url: wav)] }

        // Loudness per 0.1 s (mean |x|).
        let step = 0.1, per = Int(rate * step)
        var energy = [Float](repeating: 0, count: samples / per + 1)
        data.withUnsafeBytes { raw in
            let pcm = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            for i in 0..<samples { energy[i / per] += Float(abs(Int32(pcm[i]))) }
        }
        let starts = [0] + cuts(energy: energy, step: step, duration: duration, plan: plan)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try starts.enumerated().map { n, s in
            let e = n + 1 < starts.count ? min(duration, starts[n + 1] + plan.overlap) : duration
            let a = Int(s * rate), b = min(samples, Int(e * rate))
            var out = AudioExtract.wavHeader(dataBytes: (b - a) * 2)
            out.append(data.subdata(in: (44 + a * 2)..<(44 + b * 2)))
            let url = folder.appendingPathComponent("chunk-\(n).wav")
            try out.write(to: url)
            return Chunk(start: Double(a) / rate, end: Double(b) / rate, url: url)
        }
    }
}
