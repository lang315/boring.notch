import Foundation

/// Stands in for the app's XPCHelperClient; same call signature as the real wrapper.
final class XPCHelperClient {
    static let shared = XPCHelperClient()
    var calls: [String] = []
    var handler: (String) async -> Result<Data, CodeBurnFetchError> = { _ in .failure(.failed) }

    func codeBurnStatus(period: String) async -> Result<Data, CodeBurnFetchError> {
        calls.append(period)
        return await handler(period)
    }
}

@main
enum ManagerCheck {
    @MainActor
    static func main() async throws {
        func payload(_ label: String) -> Data {
            Data("""
            {"generated":"2026-09-29T09:09:22.900Z","current":{"label":"\(label)","cost":1,"calls":1,"sessions":1,
             "cacheHitPercent":0,"topModels":[],"topProjects":[]}}
            """.utf8)
        }
        func sleep(_ ms: UInt64) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000) }

        let client = XPCHelperClient.shared
        client.handler = { period in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .success(payload(period))
        }
        let m = CodeBurnManager()

        // Switching period mid-fetch: the result lands on the period it was requested for.
        m.refresh()
        m.period = .week
        try await sleep(100)
        check(client.calls == ["today"], "one fetch in flight: \(client.calls)")
        check(m.entries[.today]?.status == .loading, "today loading")
        try await sleep(350)
        check(m.entries[.today]?.payload?.current.label == "today", "today result lands on today")
        check(m.entries[.week]?.payload == nil, "week not filled by today's result")
        check(client.calls == ["today", "week"], "week fetched after today finished: \(client.calls)")
        try await sleep(350)
        check(m.current.payload?.current.label == "week", "week shows week data")
        check(m.current.status == .idle, "week idle after success")

        // Fresh cache: no refetch.
        m.refreshIfStale()
        try await sleep(50)
        check(client.calls.count == 2, "fresh cache must not refetch: \(client.calls)")

        // Errors land on their own period only.
        client.handler = { _ in .failure(.notInstalled) }
        m.period = .month
        try await sleep(100)
        check(m.current.status == .failed(.notInstalled), "month failed: \(m.current.status)")
        check(m.entries[.week]?.status == .idle, "week untouched")

        // Undecodable output.
        client.handler = { _ in .success(Data("not json".utf8)) }
        m.refresh()
        try await sleep(100)
        check(m.current.status == .failed(.decode), "decode failure: \(m.current.status)")

        print("ManagerCheck OK")
    }
}
