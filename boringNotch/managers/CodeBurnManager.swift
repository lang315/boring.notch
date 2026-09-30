//
//  CodeBurnManager.swift
//  boringNotch
//
//  Fetches CodeBurn spend per period through the XPC helper and caches it.
//

import Combine
import Foundation

@MainActor
final class CodeBurnManager: ObservableObject {
    static let shared = CodeBurnManager()

    enum Status: Equatable {
        case idle
        case loading
        case failed(CodeBurnFetchError)
    }

    struct Entry {
        var payload: CodeBurnPayload?
        var fetchedAt: Date?
        var status: Status = .idle
    }

    static let maxAge: TimeInterval = 5 * 60

    @Published var period: CodeBurnPeriod = .today {
        didSet { refreshIfStale() }
    }
    @Published private(set) var entries: [CodeBurnPeriod: Entry] = [:]
    @Published private(set) var isFetching = false

    var current: Entry { entries[period] ?? Entry() }

    /// Called on tab appear and period change.
    func refreshIfStale() {
        if let fetchedAt = current.fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.maxAge { return }
        refresh()
    }

    /// One fetch at a time. The result lands on the period it was requested for, so
    /// switching periods mid-fetch never shows another period's numbers.
    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        let requested = period
        entries[requested, default: Entry()].status = .loading
        Task {
            let result = await XPCHelperClient.shared.codeBurnStatus(period: requested.cliArg)
            var decoded: CodeBurnPayload?
            if case .success(let data) = result {
                decoded = await Task.detached { Self.decode(data) }.value
            }
            apply(result, decoded: decoded, to: requested)
            isFetching = false
            if period != requested { refreshIfStale() }
        }
    }

    nonisolated static func decode(_ data: Data) -> CodeBurnPayload? {
        try? JSONDecoder().decode(CodeBurnPayload.self, from: data)
    }

    private func apply(_ result: Result<Data, CodeBurnFetchError>, decoded: CodeBurnPayload?, to period: CodeBurnPeriod) {
        var entry = entries[period] ?? Entry()
        switch result {
        case .success:
            if let payload = decoded {
                entry.payload = payload
                entry.fetchedAt = Date()
                entry.status = .idle
            } else {
                entry.status = .failed(.decode)
            }
        case .failure(let error):
            entry.status = .failed(error)
        }
        entries[period] = entry
    }
}
