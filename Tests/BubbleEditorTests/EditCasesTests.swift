// Owner: QA. EditPlan against the golden cases of web/fixtures/edits-cases.json, the same file the
// page's model.js runs (web/test/edits-cases.test.mjs) and the servers answer (web/test/contract.mjs).
import BubbleEditor
import Foundation
import Testing

enum Repo {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }
}

struct EditCases: Decodable {
    struct Seg: Decodable { var start: Double; var end: Double; var rate: Double }
    struct ValidateCase: Decodable {
        var name: String; var valid: Bool
        /// nil when the case's segments are not a well-typed list (the server answers 422 at decoding).
        var segments: [Seg]?
        enum K: String, CodingKey { case name, valid, segments }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            name = try c.decode(String.self, forKey: .name); valid = try c.decode(Bool.self, forKey: .valid)
            segments = try? c.decode([Seg].self, forKey: .segments)
        }
    }
    struct PiecesCase: Decodable { var name: String; var segments: [Seg]; var pieces: [Seg]; var outputDuration: Double }
    struct TimeMap: Decodable { struct P: Decodable { var source: Double; var edited: Double }; var segments: [Seg]; var points: [P] }
    var duration: Double
    var validate: [ValidateCase]
    var pieces: [PiecesCase]
    var timeMap: TimeMap

    static let all: EditCases = try! JSONDecoder().decode(EditCases.self, from: Data(contentsOf: Repo.url("web/fixtures/edits-cases.json")))
}

extension EditCases.Seg { var segment: Segment { Segment(start: start, end: end, rate: rate) } }

@Suite struct EditCasesTests {
    let c = EditCases.all

    @Test func validateCases() {
        for v in c.validate {
            guard let segs = v.segments else {
                #expect(!v.valid, "\(v.name): not decodable, so it must be an invalid case")
                continue
            }
            let why = EditPlan.validate(segs.map(\.segment), duration: c.duration)
            #expect((why == nil) == v.valid, "\(v.name): \(why ?? "valid")")
        }
    }

    @Test func piecesCases() {
        for p in c.pieces {
            let got = EditPlan.pieces(duration: c.duration, segments: p.segments.map(\.segment))
            let ok = got.count == p.pieces.count && zip(got, p.pieces).allSatisfy {
                abs($0.start - $1.start) < 1e-6 && abs($0.end - $1.end) < 1e-6 && $0.rate == $1.rate
            }
            #expect(ok, "\(p.name): got \(got.map { "[\($0.start), \($0.end), \($0.rate)]" })")
            let d = EditPlan.outputDuration(duration: c.duration, segments: p.segments.map(\.segment))
            #expect(abs(d - p.outputDuration) < 1e-6, "\(p.name): output \(d), want \(p.outputDuration)")
        }
    }

    @Test func timeMapCases() {
        for p in c.timeMap.points {
            let e = EditPlan.outputTime(forSource: p.source, duration: c.duration, segments: c.timeMap.segments.map(\.segment))
            #expect(abs(e - p.edited) < 1e-6, "source \(p.source) → \(e), want \(p.edited)")
        }
    }
}
