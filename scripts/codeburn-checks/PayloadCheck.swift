import Foundation

@main
enum PayloadCheck {
    static func main() throws {
        let checksDir = URL(fileURLWithPath: CommandLine.arguments[1])
        let decoder = JSONDecoder()
        func decode(_ json: String) throws -> CodeBurnPayload {
            try decoder.decode(CodeBurnPayload.self, from: Data(json.utf8))
        }

        // Real-shaped fixture.
        let data = try Data(contentsOf: checksDir.appendingPathComponent("fixtures/codeburn-today.json"))
        let p = try decoder.decode(CodeBurnPayload.self, from: data)
        check(p.current.label == "Today (2026-09-29)", "label")
        check(p.current.calls == 1445, "calls")
        check(p.formatCost(p.current.cost) == "$149.96", "USD cost: \(p.formatCost(p.current.cost))")
        check(p.sessionsText == "≥45", "partial sessions: \(p.sessionsText)")
        check(p.pricedModels.map(\.name) == ["Opus 5.5", "Sonnet 5.5", "Haiku 4.5", "GPT-5"], "priced models: \(p.pricedModels.map(\.name))")
        check(p.current.unpricedModelCount == 1, "unpriced count")
        check(p.current.topProjects.map(\.rowID) == ["/Users/dev/work/alpha", "/Users/dev/other/alpha", "beta"], "project row ids")
        check(p.liveSessions?.count == 2, "live count")
        check(p.stale == nil, "stale absent")
        check(p.generatedDate != nil, "generated parses with fractional seconds")

        // Optional blocks absent, JPY, identity session basis, stale.
        let minimal = try decode("""
        {"generated":"2026-09-29T09:09:22Z","stale":true,
         "currency":{"code":"JPY","symbol":"¥","rate":150},
         "current":{"label":"7 Days","cost":10.004,"calls":3,"sessions":2,"sessionCountBasis":"identity",
                    "cacheHitPercent":50,"topModels":[],"topProjects":[]}}
        """)
        check(minimal.formatCost(minimal.current.cost) == "¥1501", "JPY zero decimals: \(minimal.formatCost(minimal.current.cost))")
        check(minimal.sessionsText == "2", "identity sessions: \(minimal.sessionsText)")
        check(minimal.liveSessions == nil, "liveSessions absent means unknown")
        check(minimal.current.unpricedModelCount == 0, "unpricedModels absent")
        check(minimal.stale == true, "stale true")
        check(minimal.generatedDate != nil, "generated parses without fractional seconds")

        // No currency block at all: USD defaults.
        let noCurrency = try decode("""
        {"generated":"2026-09-29T09:09:22.900Z",
         "current":{"label":"Month","cost":1.5,"calls":1,"sessions":1,"cacheHitPercent":0,"topModels":[],"topProjects":[]}}
        """)
        check(noCurrency.formatCost(1.5) == "$1.50", "default currency: \(noCurrency.formatCost(1.5))")
        check(noCurrency.sessionsText == "≥1", "absent basis is a lower bound: \(noCurrency.sessionsText)")

        // Fresh user: CLI exits 0 with zeros and empty arrays.
        let empty = try decode("""
        {"generated":"2026-09-29T09:09:22.900Z","currency":{"code":"USD","symbol":"$","rate":1},
         "current":{"label":"Today (2026-09-29)","cost":0,"calls":0,"sessions":0,"cacheHitPercent":0,
                    "topModels":[],"unpricedModels":[],"topProjects":[]},
         "liveSessions":{"windowSeconds":600,"sessions":[]}}
        """)
        check(empty.current.calls == 0, "empty calls")
        check(empty.liveSessions?.count == 0, "empty live sessions")

        // Freshness label.
        let base = Date(timeIntervalSince1970: 1_000_000)
        check(CodeBurnPayload.ageText(since: base, now: base.addingTimeInterval(30)) == "now", "age now")
        check(CodeBurnPayload.ageText(since: base, now: base.addingTimeInterval(240)) == "4m ago", "age minutes")
        check(CodeBurnPayload.ageText(since: base, now: base.addingTimeInterval(7300)) == "2h ago", "age hours")

        // Periods match the helper allowlist; helper codes map to errors.
        check(CodeBurnPeriod.allCases.map(\.cliArg) == ["today", "week", "30days", "month"], "period cli args")
        check(CodeBurnFetchError(helperCode: "not-installed") == .notInstalled, "not-installed")
        check(CodeBurnFetchError(helperCode: "busy") == .busy, "busy")
        check(CodeBurnFetchError(helperCode: "timeout") == .timeout, "timeout")
        check(CodeBurnFetchError(helperCode: "failed") == .failed, "failed")
        check(CodeBurnFetchError(helperCode: nil) == .failed, "nil code")

        print("PayloadCheck OK")
    }
}
