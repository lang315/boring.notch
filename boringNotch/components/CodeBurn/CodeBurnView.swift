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
        let id: String
        let name: String
        let cost: String
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
                        .foregroundStyle(manager.period == period ? .white : .gray)
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
                Text(verbatim: CodeBurnPayload.ageText(since: date))
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            if manager.current.status == .loading {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button {
                    manager.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.gray)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(.notInstalled):
                VStack(alignment: .leading, spacing: 4) {
                    message("CodeBurn CLI not found")
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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                stat("\(current.calls) calls")
                stat("\(payload.sessionsText) sessions")
                stat("\(Int(current.cacheHitPercent.rounded()))% cache")
                if let live = payload.liveSessions {
                    stat("● \(live.count) active ≤10m")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            list("MODELS",
                 rows: payload.pricedModels.prefix(4).map { Row(id: $0.name, name: $0.name, cost: payload.formatCost($0.cost)) },
                 footer: current.unpricedModelCount > 0 ? "+\(current.unpricedModelCount) unpriced" : nil)
            list("PROJECTS",
                 rows: current.topProjects.prefix(4).map { Row(id: $0.rowID, name: $0.name, cost: payload.formatCost($0.cost)) },
                 footer: nil)
        }
    }

    private func list(_ title: LocalizedStringKey, rows: [Row], footer: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.gray)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Text(verbatim: row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(verbatim: row.cost)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.white)
            }
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.gray)
            .lineLimit(1)
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
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
