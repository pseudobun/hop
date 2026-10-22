import Foundation
import Testing
@testable import hop

nonisolated struct RankingScenario: CustomTestStringConvertible, Sendable {
    let name: String
    let term: String
    let sensitivity: Sensitivity
    let candidates: [RankCandidate]
    let expectedOrder: [String]
    var testDescription: String { name }

    /// Scenarios that rely on features hop deliberately lacks (aliases, stored
    /// search terms, boosted terms, contacts, pins).
    static let unsupported: Set<String> = [
        "alias exact beats everything", "alias prefix",
        "search-term exact (recent, frecency>1)", "search-term ignored when opened >17d ago",
        "search-term prefix + overbounds", "search-term overbounds count>=3",
        "contacts demoted unless strong", "boosted search term (notes)",
        "empty query: frecency, alias, type, title",
    ]

    static func weight(_ c: [String: Any]) -> Int {
        switch c["kind"] as? String {
        case "application": return TypeWeight.application
        case "quicklink": return TypeWeight.quicklink
        case "preference", "calendar-event", "file": return TypeWeight.preference
        case "contact": return 0
        default: return (c["commandType"] as? String) == "menu-bar-command" ? TypeWeight.menuBar : TypeWeight.command
        }
    }

    static func all() -> [RankingScenario] {
        (Fixtures.search["ranking"] as! [[String: Any]]).compactMap { s in
            let name = s["name"] as! String
            guard !unsupported.contains(name) else { return nil }
            let cands = (s["candidates"] as! [[String: Any]]).map { c in
                RankCandidate(id: c["id"] as! String, title: c["title"] as! String,
                              subtitle: c["subtitle"] as? String, keywords: c["keywords"] as? [String] ?? [],
                              typeWeight: weight(c), frecency: (c["score"] as? NSNumber)?.doubleValue ?? 1)
            }
            return RankingScenario(name: name, term: s["term"] as! String,
                                   sensitivity: Sensitivity(rawValue: s["sensitivity"] as! String)!,
                                   candidates: cands, expectedOrder: s["expectedOrder"] as! [String])
        }
    }
}

struct RootRankerTests {
    @Test(arguments: RankingScenario.all())
    func goldenOrder(_ s: RankingScenario) {
        let order = s.term.isEmpty
            ? RootRanker.rankEmpty(s.candidates)
            : RootRanker.rank(s.candidates, query: SearchQuery(s.term), sensitivity: s.sensitivity)
        #expect(order.map { s.candidates[$0].id } == s.expectedOrder)
    }

    @Test func safariFirstForSaf() {
        let apps = ["Safari", "Slack", "System Settings", "Screenshot", "Shortcuts"].map {
            RankCandidate(id: $0, title: $0, typeWeight: TypeWeight.application)
        }
        let order = RootRanker.rank(apps, query: SearchQuery("saf"), sensitivity: .high)
        #expect(apps[order[0]].id == "Safari")
    }
}
