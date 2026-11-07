// Owner: E2 (transcription). docs/editor-architecture.md §5: Voxtral 3 gives sentences (text, start, end,
// speaker) but no word times. This puts a time on every word: the time of the same word in a reference
// transcript with word times (Apple's on-device SpeechTranscriber) when the two agree, else a share of the
// gap between its timed neighbours, by letter count (`approximate`). Text, punctuation and speakers always
// come from the segments; the reference only gives timing. Pure; never fails.
import Foundation

/// A timed stretch of text from an engine without word times (a Voxtral 3 segment).
public struct TextSegment: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String
    public init(start: Double, end: Double, text: String, speaker: String) {
        self.start = start; self.end = end; self.text = text; self.speaker = speaker
    }
}

public enum WordAligner {
    /// Reference words this far outside a segment can still match its words (engines disagree on edges).
    static let window = 1.0

    /// One word per whitespace-separated token of each segment, timed. `reference` nil or empty: every
    /// word is spread inside its segment (approximate).
    public static func align(segments: [TextSegment], reference: [TimedWord]?) -> [TimedWord] {
        let ref = (reference ?? []).filter { !normalize($0.text).isEmpty }.sorted { $0.start < $1.start }
        var out: [TimedWord] = []
        var nextRef = 0   // reference words are used in order, at most once
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            let tokens = seg.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            let lo = max(seg.start, 0), hi = max(seg.end, lo)
            // The reference words in this segment's window, not used by an earlier segment.
            var candidates: [Int] = []
            var i = nextRef
            while i < ref.count, ref[i].start < hi + window {
                let mid = (ref[i].start + ref[i].end) / 2
                if mid >= lo - window { candidates.append(i) }
                i += 1
            }
            let matches = match(tokens.map(normalize), candidates.map { normalize(ref[$0].text) })
            var times = [(Double, Double)?](repeating: nil, count: tokens.count)
            for m in matches {
                let r = m.ref.map { ref[candidates[$0]] }
                let s = r.map(\.start).min()!, e = r.map(\.end).max()!
                if m.vox.count == 1 {
                    times[m.vox.lowerBound] = (s, e)
                } else {   // one reference word for several of ours: share it by letters
                    let parts = spread(Array(tokens[m.vox]), from: s, to: e)
                    for (k, p) in zip(m.vox, parts) { times[k] = p }
                }
                nextRef = max(nextRef, candidates[m.ref.upperBound - 1] + 1)
            }
            out += place(tokens, times: times, in: lo, hi, speaker: seg.speaker)
        }
        return out
    }

    // MARK: - Pieces (internal for tests)

    /// Lowercased, accents folded, letters and digits only: "Option-Shift-L," → "optionshiftl", "Ça" → "ca".
    static func normalize(_ token: String) -> String {
        let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })).lowercased()
    }

    struct Match: Equatable {
        var vox: Range<Int>
        var ref: Range<Int>
    }

    /// Edit-distance alignment of two token lists. Steps: equal (cost 0), one of ours = 2-3 joined
    /// reference tokens or the reverse ("option-shift-l" ↔ "option shift l", cost 0), a close spelling
    /// (cost 0.5: "okay"/"ok", "gabriel"/"gabrielle"), substitution (cost 1, no time taken), skip (cost 1).
    /// Returns the timed pairs in order.
    static func match(_ a: [String], _ b: [String]) -> [Match] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        enum Step: UInt8 { case none, skipA, skipB, sub, pair }
        var cost = [Double](repeating: .infinity, count: (n + 1) * (m + 1))
        var back = [(Step, UInt8, UInt8)](repeating: (.none, 0, 0), count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        cost[at(0, 0)] = 0
        for i in 0...n {
            for j in 0...m {
                let c = cost[at(i, j)]
                guard c.isFinite else { continue }
                func relax(_ di: Int, _ dj: Int, _ add: Double, _ step: Step) {
                    let k = at(i + di, j + dj)
                    if c + add < cost[k] { cost[k] = c + add; back[k] = (step, UInt8(di), UInt8(dj)) }
                }
                if i < n { relax(1, 0, 1, .skipA) }
                if j < m { relax(0, 1, 1, .skipB) }
                guard i < n, j < m else { continue }
                if a[i] == b[j] { relax(1, 1, 0, .pair) }
                else if close(a[i], b[j]) { relax(1, 1, 0.5, .pair) }
                else { relax(1, 1, 1, .sub) }
                for k in 2...3 {
                    if j + k <= m, a[i] == b[j..<(j + k)].joined() { relax(1, k, 0, .pair) }
                    if i + k <= n, a[i..<(i + k)].joined() == b[j] { relax(k, 1, 0, .pair) }
                }
            }
        }
        var out: [Match] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            let (step, di, dj) = back[at(i, j)]
            if step == .none { break }
            let pi = i - Int(di), pj = j - Int(dj)
            if step == .pair { out.append(Match(vox: pi..<i, ref: pj..<j)) }
            i = pi; j = pj
        }
        return out.reversed()
    }

    /// Same word, spelled a bit differently: shared prefix of ≥ 3 and lengths within 2, or ≤ 1 edit on
    /// words of ≥ 4 letters.
    static func close(_ x: String, _ y: String) -> Bool {
        guard !x.isEmpty, !y.isEmpty, x != y else { return x == y }
        let a = Array(x), b = Array(y)
        let prefix = zip(a, b).prefix { $0 == $1 }.count
        if prefix >= 3 && abs(a.count - b.count) <= 2 { return true }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
        return levenshtein(a, b) <= 1
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var row = [i + 1]
            for (j, cb) in b.enumerated() {
                row.append(min(prev[j + 1] + 1, row[j] + 1, prev[j] + (ca == cb ? 0 : 1)))
            }
            prev = row
        }
        return prev[b.count]
    }

    /// Times for `tokens` spread over [from, to] by letter count (each word gets its share, 85 % of it
    /// spoken, the rest a gap).
    static func spread(_ tokens: [String], from: Double, to: Double) -> [(Double, Double)] {
        let weights = tokens.map { Double(max(1, normalize($0).count)) + 1 }
        let total = weights.reduce(0, +)
        let span = max(0, to - from)
        var t = from
        return weights.map { w in
            let share = span * w / total
            defer { t += share }
            return (t, t + share * 0.85)
        }
    }

    /// Final words of one segment: matched ones clamped inside it, runs without a time spread between
    /// their timed neighbours (or the segment's edges), all in order.
    static func place(_ tokens: [String], times: [(Double, Double)?], in lo: Double, _ hi: Double, speaker: String) -> [TimedWord] {
        var out: [TimedWord] = []
        var floor = lo
        var k = 0
        while k < tokens.count {
            if let (s, e) = times[k] {
                let start = min(max(s, floor), hi), end = min(max(e, start), hi)
                out.append(TimedWord(start: start, end: end, text: tokens[k], speaker: speaker))
                floor = end
                k += 1
                continue
            }
            var r = k
            while r < tokens.count, times[r] == nil { r += 1 }
            let until = r < tokens.count ? min(max(times[r]!.0, floor), hi) : hi
            for (offset, p) in spread(Array(tokens[k..<r]), from: floor, to: until).enumerated() {
                out.append(TimedWord(start: p.0, end: p.1, text: tokens[k + offset], speaker: speaker, approximate: true))
            }
            floor = until
            k = r
        }
        return out
    }
}
