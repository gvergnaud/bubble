// The edit model, pure (docs/editor-architecture.md §3, editor-api.md §3). Owner: E1.
// Segments are in source time; what is not in a segment plays at rate 1. Used by the PUT /edits
// route (validation), the export (pieces, duration) and tests. The page has a JS twin; both run
// the golden cases of web/fixtures/edits-cases.json.
import Foundation

public enum EditPlan {
    /// A kept stretch of the source, played at `rate` (> 0).
    public struct Piece: Sendable, Equatable, Codable {
        public var start: Double
        public var end: Double
        public var rate: Double
        public init(start: Double, end: Double, rate: Double) { self.start = start; self.end = end; self.rate = rate }
        public var outputDuration: Double { (end - start) / rate }
    }

    /// Tolerances: the same as web/mock-server.mjs `validate` (the page sends ms-rounded floats).
    static let durationSlack = 1e-3
    static let orderSlack = 1e-6
    public static let shortest = 1.0 / 30

    /// nil when `segments` hold the invariants of editor-api.md §3, else a sentence saying which
    /// segment breaks which rule (the `message` of the 422).
    public static func validate(_ segments: [Segment], duration: Double) -> String? {
        var prevEnd = 0.0
        for (i, s) in segments.enumerated() {
            guard s.start.isFinite, s.end.isFinite, s.rate.isFinite else { return "segment \(i): start, end, rate must be numbers" }
            if !(s.start >= 0 && s.start < s.end && s.end <= duration + durationSlack) { return "segment \(i): needs 0 <= start < end <= duration" }
            if s.start < prevEnd - orderSlack { return "segment \(i): overlaps or is out of order" }
            if s.rate == 1 { return "segment \(i): rate 1 is not a segment" }
            if !(s.rate == 0 || (s.rate >= 0.25 && s.rate <= 4)) { return "segment \(i): rate must be 0 or 0.25..4" }
            if s.end - s.start < shortest - orderSlack { return "segment \(i): shorter than one frame" }
            prevEnd = s.end
        }
        return nil
    }

    /// The kept pieces of the source in order, with their rates: the gaps between segments at
    /// rate 1, the segments with rate > 0; cuts are left out. Touching pieces of the same rate are
    /// merged. `segments` must be valid.
    public static func pieces(duration: Double, segments: [Segment]) -> [Piece] {
        var out: [Piece] = []
        func add(_ start: Double, _ end: Double, _ rate: Double) {
            let end = min(end, duration)
            guard end - start > 1e-9, rate > 0 else { return }
            if let last = out.last, last.rate == rate, abs(last.end - start) < 1e-9 {
                out[out.count - 1].end = end
            } else {
                out.append(Piece(start: start, end: end, rate: rate))
            }
        }
        var cursor = 0.0
        for s in segments {
            add(cursor, s.start, 1)
            add(max(s.start, cursor), s.end, s.rate)
            cursor = max(cursor, s.end)
        }
        add(cursor, duration, 1)
        return out
    }

    /// Seconds of the edited video: Σ kept / rate.
    public static func outputDuration(duration: Double, segments: [Segment]) -> Double {
        pieces(duration: duration, segments: segments).reduce(0) { $0 + $1.outputDuration }
    }

    /// Where source time `t` lands in the edited video. A time inside a cut maps to the start of
    /// what follows it.
    public static func outputTime(forSource t: Double, duration: Double, segments: [Segment]) -> Double {
        var out = 0.0
        for p in pieces(duration: duration, segments: segments) {
            if t <= p.start { return out }
            if t < p.end { return out + (t - p.start) / p.rate }
            out += p.outputDuration
        }
        return out
    }
}
