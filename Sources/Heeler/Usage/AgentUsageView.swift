import Charts
import SwiftUI

struct AgentUsageView: View {
    let store: AgentUsageStore

    var body: some View {
        List {
            Section { ClaudeUsageSettings(store: store) }
            if case .available(let report) = store.state {
                if report.refreshing == true {
                    ProgressView("Refreshing")
                }
                if let failure = store.refreshFailure {
                    AgentUsageRefreshFailureNote(message: failure, isRetrying: store.isRetryingRefresh)
                }
                ForEach(report.programs ?? [], id: \.program) { program in
                    Section(program.displayName) {
                        AgentUsageLimitsView(program: program.program, limits: program.usageLimits)
                        AgentUsageProgramDetails(program: program, timeZone: report.timeZone)
                    }
                }
                Section {
                    AgentUsageCoverage(report: report)
                    CodexUsageLimitsNote()
                }
            } else {
                AgentUsageContent(state: store.state)
            }
        }
        .readableColumnPage()
        .navigationTitle("Usage")
        .task(id: store.refreshKey) { await store.refresh() }
        .refreshable { await store.pullToRefresh() }
    }
}

/// Uses the plugin's already-folded calendar dates, so chart days never shift
/// a second time when the phone's time zone differs from UTC.
struct AgentUsageProgramDetails: View {
    let program: AgentUsageReport.Program
    let timeZone: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        if program.tokenUsage.state == "ok", let totals = program.tokenUsage.totals {
            Text("Token Usage on this Host").font(.subheadline).foregroundStyle(.secondary)
            summary("Today", totals.today)
            summary("Last 7 days", totals.last7Days)
            summary("Last 30 days", totals.last30Days)
            if let daily = program.tokenUsage.daily, !daily.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Daily tokens · Last 30 days").font(.headline)
                    Chart(daily, id: \.date) { day in
                        BarMark(x: .value("Day", day.date), y: .value("Tokens", day.tokens.total))
                            .accessibilityLabel(dayText(day.date, includesYear: true))
                            .accessibilityValue("\(day.tokens.total.formatted()) tokens")
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            if showsAxisLabel(at: value.index, count: daily.count) {
                                AxisValueLabel(anchor: axisLabelAnchor(at: value.index, count: daily.count)) {
                                    if let date = value.as(String.self) {
                                        Text(dayText(date, includesYear: false))
                                    }
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(format: FloatingPointFormatStyle<Double>.number.notation(.compactName),
                            values: .automatic(desiredCount: 3))
                    }
                    .frame(height: 180)
                    .padding(.horizontal, 16)
                    if let timeZone {
                        Text("Days shown in \(timeZone)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let models = program.tokenUsage.models, !models.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Models · Last 30 days").font(.headline)
                    ForEach(models, id: \.model) { model in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.model).font(.subheadline.weight(.semibold))
                                .textSelection(.enabled)
                            Text("\(model.tokens.total.formatted()) tokens").monospacedDigit()
                            AgentUsageEstimatedCost(summary: .init(tokens: model.tokens,
                                estimatedCostUSD: model.estimatedCostUSD, unpricedTokens: model.unpricedTokens))
                            if !model.priced {
                                Text("Includes unpriced tokens").font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
            if let directories = program.tokenUsage.directories, !directories.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Top directories · Last 30 days").font(.headline)
                    ForEach(directories, id: \.path) { directory in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(directory.path).font(.subheadline.monospaced())
                                .textSelection(.enabled)
                            Text("\(directory.tokens.total.formatted()) tokens").monospacedDigit()
                            AgentUsageEstimatedCost(summary: .init(tokens: directory.tokens,
                                estimatedCostUSD: directory.estimatedCostUSD,
                                unpricedTokens: directory.unpricedTokens))
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
        } else {
            Text(program.tokenUsage.state == "noData"
                ? "No Token Usage recorded on this Host yet." : "Token Usage could not be read.")
                .foregroundStyle(.secondary)
        }
    }

    /// Weekly labels count back from today, so the newest day is always
    /// named; a label too close to the leading edge to fit is left out.
    private func showsAxisLabel(at index: Int, count: Int) -> Bool {
        let last = count - 1
        if dynamicTypeSize.isAccessibilitySize { return index == 0 || index == last }
        return (last - index).isMultiple(of: 7) && index >= 3
    }

    /// Top anchors keep every label on one row below the axis; the ends
    /// stay inside the plot's width.
    private func axisLabelAnchor(at index: Int, count: Int) -> UnitPoint {
        if index == count - 1 { return .topTrailing }
        return index == 0 ? .topLeading : .top
    }

    private func dayText(_ day: String, includesYear: Bool) -> String {
        AgentUsageCalendarDay.text(day, locale: locale, calendar: calendar, includesYear: includesYear)
    }

    private func summary(_ title: String, _ value: AgentUsageReport.Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text("\(value.tokens.total.formatted()) tokens").monospacedDigit()
            AgentUsageEstimatedCost(summary: value)
        }.accessibilityElement(children: .combine)
    }
}

struct AgentUsageCoverage: View {
    let report: AgentUsageReport
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coverage").font(.headline)
            if report.scan?.state == "partial" {
                Text("Token Usage is still being summarized.")
            }
            if let from = report.scan?.coveredFrom {
                let since = AgentUsageCalendarDay.text(
                    from, locale: locale, calendar: calendar, includesYear: true)
                Text("Recorded on this Host since \(since).")
            } else {
                Text("No Transcript coverage recorded on this Host yet.")
            }
            if let skipped = report.scan?.skippedArchives, skipped > 0 {
                Text("\(skipped.formatted()) compressed archives skipped.")
            }
            if let pricingVersion = report.pricingVersion {
                Text("Price table: \(pricingVersion)")
            }
            Text("Estimated API cost is based on recorded Token Usage, not your subscription bill.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
