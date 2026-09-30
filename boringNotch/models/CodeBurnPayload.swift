//
//  CodeBurnPayload.swift
//  boringNotch
//
//  The subset of `codeburn status --format menubar-json` that the CodeBurn tab
//  renders. Foundation-only so scripts/codeburn-check.sh can compile it standalone.
//

import Foundation

enum CodeBurnPeriod: String, CaseIterable, Identifiable {
    case today
    case week
    case thirtyDays = "30days"
    case month

    var id: String { rawValue }
    var cliArg: String { rawValue }

    var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .week: return String(localized: "7d")
        case .thirtyDays: return String(localized: "30d")
        case .month: return String(localized: "Month")
        }
    }
}

enum CodeBurnFetchError: Error, Equatable {
    case notInstalled
    case busy
    case timeout
    case failed
    case decode

    /// Maps the XPC helper's reply code (see CodeBurnRunner) to an app error.
    init(helperCode: String?) {
        switch helperCode {
        case "not-installed": self = .notInstalled
        case "busy": self = .busy
        case "timeout": self = .timeout
        default: self = .failed
        }
    }
}

struct CodeBurnPayload: Decodable, Equatable {
    struct Currency: Decodable, Equatable {
        var code: String
        var symbol: String
        var rate: Double

        init(code: String = "USD", symbol: String = "$", rate: Double = 1) {
            self.code = code
            self.symbol = symbol
            self.rate = rate
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decodeIfPresent(String.self, forKey: .code) ?? "USD"
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "$"
            rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 1
        }

        private enum CodingKeys: String, CodingKey { case code, symbol, rate }
    }

    struct Model: Decodable, Equatable {
        let name: String
        let cost: Double
    }

    struct Project: Decodable, Equatable {
        /// Folder basename; two projects can share it.
        let name: String
        let cost: Double
    }

    struct Current: Decodable, Equatable {
        let label: String
        let cost: Double
        let calls: Int
        let sessions: Int
        /// 0–100.
        let cacheHitPercent: Double
        /// Exact only when `identity`; absent or anything else means `sessions` is a lower bound.
        let sessionCountBasis: String?
        /// Sorted by cost, uncapped, may contain $0 rows.
        let topModels: [Model]
        /// Models that ran but have no price (shown as $0 upstream).
        let unpricedModelCount: Int
        let topProjects: [Project]

        private enum CodingKeys: String, CodingKey {
            case label, cost, calls, sessions, cacheHitPercent, sessionCountBasis
            case topModels, unpricedModels, topProjects
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            cost = try c.decode(Double.self, forKey: .cost)
            calls = try c.decode(Int.self, forKey: .calls)
            sessions = try c.decode(Int.self, forKey: .sessions)
            cacheHitPercent = try c.decodeIfPresent(Double.self, forKey: .cacheHitPercent) ?? 0
            sessionCountBasis = try c.decodeIfPresent(String.self, forKey: .sessionCountBasis)
            topModels = try c.decodeIfPresent([Model].self, forKey: .topModels) ?? []
            unpricedModelCount = try c.decodeIfPresent([Ignored].self, forKey: .unpricedModels)?.count ?? 0
            topProjects = try c.decodeIfPresent([Project].self, forKey: .topProjects) ?? []
        }
    }

    struct LiveSessions: Decodable, Equatable {
        let count: Int

        private enum CodingKeys: String, CodingKey { case sessions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = try c.decodeIfPresent([Ignored].self, forKey: .sessions)?.count ?? 0
        }
    }

    /// Consumes one JSON value without keeping it; used where only a count matters.
    private struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    let generated: String
    /// True when the CLI served older data because another process held its cache lock.
    let stale: Bool?
    let currency: Currency
    let current: Current
    /// Absent means "unknown", not zero.
    let liveSessions: LiveSessions?
    /// `generated` parsed once at decode time.
    let generatedDate: Date?

    private enum CodingKeys: String, CodingKey { case generated, stale, currency, current, liveSessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated = try c.decode(String.self, forKey: .generated)
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale)
        currency = try c.decodeIfPresent(Currency.self, forKey: .currency) ?? Currency()
        current = try c.decode(Current.self, forKey: .current)
        liveSessions = try c.decodeIfPresent(LiveSessions.self, forKey: .liveSessions)
        generatedDate = Self.withFraction.date(from: generated) ?? Self.plain.date(from: generated)
    }

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    // MARK: - Display

    /// Payload costs are USD. Fraction digits come from the currency (JPY 0, USD 2).
    /// A fresh formatter per call keeps this thread-safe; it runs a handful of times per render.
    func formatCost(_ usd: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US_POSIX")
        f.currencyCode = currency.code
        return currency.symbol + String(format: "%.*f", Int32(f.maximumFractionDigits), usd * currency.rate)
    }

    var sessionsText: String {
        let isExact = current.sessionCountBasis == "identity"
        return (isExact ? "" : "≥") + "\(current.sessions)"
    }

    /// $0 rows (local, free or unpriced models) are left out; unpriced ones are counted separately.
    var pricedModels: [Model] { current.topModels.filter { $0.cost > 0 } }

    /// Freshness of the data itself (the CLI may serve a saved snapshot), not of the fetch.
    static func ageText(since date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = locale
        return f.localizedString(for: date, relativeTo: now)
    }
}
