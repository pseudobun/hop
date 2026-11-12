import Foundation
import Testing
@testable import hop

struct FrecencyTests {
    nonisolated struct Sequence: CustomTestStringConvertible, Sendable {
        let name: String
        let steps: [(t: Double, before: Double, anchor: Double, after: Double)]
        let probes: [(days: Double, score: Double)]
        var testDescription: String { name }
    }

    nonisolated static let sequences: [Sequence] = {
        let model = Fixtures.frecency["observed_rust_visit_model"] as! [String: Any]
        return (model["sequences"] as! [[String: Any]]).map { s in
            let steps = (s["steps"] as! [[String: NSNumber]]).map {
                (t: $0["t"]!.doubleValue, before: $0["score_before"]!.doubleValue,
                 anchor: $0["anchor_after"]!.doubleValue, after: $0["score_after"]!.doubleValue)
            }
            let probes = (s["probes"] as! [[String: NSNumber]]).map {
                (days: $0["days_after_last"]!.doubleValue, score: $0["score"]!.doubleValue)
            }
            return Sequence(name: s["name"] as! String, steps: steps, probes: probes)
        }
    }()

    static func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-9 * max(1, abs(b)) }

    @Test(arguments: sequences)
    func goldenVisits(_ s: Sequence) {
        var anchor: Double?
        for step in s.steps {
            let before = anchor.map { Frecency.score(anchor: $0, at: step.t) } ?? 1
            #expect(Self.close(before, step.before))
            anchor = Frecency.visit(anchor: anchor, at: step.t)
            #expect(Self.close(anchor!, step.anchor))
            #expect(Self.close(Frecency.score(anchor: anchor!, at: step.t), step.after))
        }
        let last = s.steps.last!.t
        for p in s.probes {
            #expect(Self.close(Frecency.score(anchor: anchor!, at: last + p.days * 86_400), p.score))
        }
    }

    @Test func oneVisitIs101() {
        let t = 1_800_000_000.0
        #expect(Self.close(Frecency.score(anchor: Frecency.visit(anchor: nil, at: t), at: t), 101))
    }
}
