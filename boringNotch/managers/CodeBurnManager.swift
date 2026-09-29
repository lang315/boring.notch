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
    private var inFlight = false

    var current: Entry { entries[period] ?? Entry() }

    /// Called on tab appear and period change.
    func refreshIfStale() {
        if let fetchedAt = current.fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.maxAge { return }
        refresh()
    }

    /// One fetch at a time. The result lands on the period it was requested for, so
    /// switching periods mid-fetch never shows another period's numbers.
    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let requested = period
        entries[requested, default: Entry()].status = .loading
        Task {
            let result = await XPCHelperClient.shared.codeBurnStatus(period: requested.cliArg)
            apply(result, to: requested)
            inFlight = false
            if period != requested { refreshIfStale() }
        }
    }

    private func apply(_ result: Result<Data, CodeBurnFetchError>, to period: CodeBurnPeriod) {
        var entry = entries[period] ?? Entry()
        switch result {
        case .success(let data):
            if let payload = try? JSONDecoder().decode(CodeBurnPayload.self, from: data) {
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
