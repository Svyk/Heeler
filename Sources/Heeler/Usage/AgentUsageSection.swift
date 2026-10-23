import SwiftUI

/// Shared content for the Host summary and the Usage page's loading states.
struct AgentUsageContent: View {
    let state: AgentUsageStore.State

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView("Loading Usage…")
        case .requirement(let message):
            Text(message).foregroundStyle(.secondary)
        case .unsupportedPlatform:
            Text("Not supported on Windows").foregroundStyle(.secondary)
        case .runtimeMissing:
            Text("Use any Agent on this computer once, or restart herdr, then refresh Usage.")
                .foregroundStyle(.secondary)
        case .updateRequired:
            Text("Update Heeler to read this Host's Usage format.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
        case .available(let report):
            if report.refreshing == true {
                ProgressView("Refreshing")
            }
            if report.scan?.state == "partial" {
                Text("Token Usage is still being summarized.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(report.programs ?? [], id: \.program) { program in
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.program == "claude" ? "Claude Code" : "Codex")
                        .font(.headline)
                    if program.tokenUsage.state == "ok", let totals = program.tokenUsage.totals {
                        Text("Token Usage on this Host")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Today: \(totals.today.tokens.total.formatted()) tokens")
                            .font(.subheadline)
                        Text("Last 30 days: \(totals.last30Days.tokens.total.formatted()) tokens")
                            .font(.subheadline)
                    } else if program.tokenUsage.state == "noData" {
                        Text("No Token Usage recorded on this Host yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Token Usage could not be read.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct AgentUsageSection: View {
    let store: AgentUsageStore

    var body: some View {
        Section("Usage") {
            AgentUsageContent(state: store.state)
        }
        .task { await store.refresh() }
    }
}
