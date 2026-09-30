//
//  CodeBurnView.swift
//  boringNotch
//
//  CodeBurn tab: AI coding spend from the locally installed `codeburn` CLI.
//

import SwiftUI

struct CodeBurnView: View {
    @ObservedObject var manager = CodeBurnManager.shared

    private struct Row: Identifiable {
        let id: Int
        let name: String
        let cost: String
        /// Cost relative to the largest in its column (0...1); sizes the spend bar.
        let share: Double
    }

    private let ember = Color(red: 249 / 255, green: 115 / 255, blue: 22 / 255)
    private let flame = Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255)
    private var emberGradient: LinearGradient {
        LinearGradient(colors: [ember, flame], startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .onAppear { manager.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(CodeBurnPeriod.allCases) { period in
                Button {
                    manager.period = period
                } label: {
                    Text(period.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(manager.period == period ? ember : .gray)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(manager.period == period ? ember.opacity(0.2) : .clear))
                }
                .buttonStyle(.plain)
            }
            if let label = manager.current.payload?.current.label {
                Text(verbatim: label)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let date = manager.current.payload?.generatedDate {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(verbatim: CodeBurnPayload.ageText(since: date, now: context.date))
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
            if manager.current.status == .loading || manager.isFetching {
                ProgressView()
                    .controlSize(.mini)
                    .tint(ember)
            } else {
                Button {
                    manager.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
                .accessibilityLabel("Refresh")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let entry = manager.current
        if let payload = entry.payload {
            VStack(alignment: .leading, spacing: 4) {
                if payload.current.calls == 0 {
                    message("No usage in this period")
                } else {
                    columns(payload)
                        .opacity(payload.stale == true ? 0.5 : 1)
                }
                if case .failed(let error) = entry.status {
                    Text(refreshFailureText(error))
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        } else {
            switch entry.status {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
                    .tint(ember)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(.notInstalled):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(ember)
                        message("CodeBurn CLI not found")
                    }
                    Text(verbatim: "brew install codeburn  ·  npm i -g codeburn")
                        .font(.caption.monospaced())
                        .foregroundStyle(.gray)
                }
            case .failed(.decode):
                message("Unexpected CodeBurn output (CLI version?)")
            case .failed:
                message("Couldn't load CodeBurn data")
            }
        }
    }

    private func columns(_ payload: CodeBurnPayload) -> some View {
        let current = payload.current
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: payload.formatCost(current.cost))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(emberGradient)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                stat("\(current.calls.formatted()) calls")
                stat("\(payload.sessionsText) sessions")
                stat("\(Int(current.cacheHitPercent.rounded()))% cache")
                if let live = payload.liveSessions {
                    (Text(verbatim: "● ").foregroundStyle(ember) + Text("\(live.count) active ≤10m"))
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let models = payload.pricedModels.prefix(4)
            let modelMax = models.map(\.cost).max() ?? 0
            let projects = current.topProjects.prefix(4)
            let projectMax = projects.map(\.cost).max() ?? 0
            list("MODELS",
                 rows: models.enumerated().map { Row(id: $0.offset, name: $0.element.name, cost: payload.formatCost($0.element.cost), share: modelMax > 0 ? $0.element.cost / modelMax : 0) },
                 footer: current.unpricedModelCount > 0 ? "+\(current.unpricedModelCount) unpriced" : nil)
            list("PROJECTS",
                 rows: projects.enumerated().map { Row(id: $0.offset, name: $0.element.name, cost: payload.formatCost($0.element.cost), share: projectMax > 0 ? $0.element.cost / projectMax : 0) },
                 footer: nil)
        }
    }

    private func list(_ title: LocalizedStringKey, rows: [Row], footer: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.gray)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Text(verbatim: row.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(verbatim: row.cost)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .background(alignment: .leading) {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(emberGradient)
                            .opacity(0.28)
                            .frame(width: proxy.size.width * row.share)
                    }
                }
            }
            if let footer {
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.gray)
            .lineLimit(1)
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(.gray)
    }

    private func refreshFailureText(_ error: CodeBurnFetchError) -> LocalizedStringKey {
        switch error {
        case .decode: return "Unexpected CodeBurn output (CLI version?)"
        case .notInstalled: return "CodeBurn CLI not found"
        default: return "Couldn't refresh CodeBurn"
        }
    }
}
