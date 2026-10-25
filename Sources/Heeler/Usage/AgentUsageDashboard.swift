import SwiftUI

/// One Host the Usage tab can read, with the store that reads it.
@MainActor
struct AgentUsageHostEntry: Identifiable {
    let id: Host.ID
    let name: String
    let store: AgentUsageStore
    let isConnected: Bool

    var reading: AgentUsageScope.HostReading {
        .init(id: id, name: name, state: store.state, refreshFailure: store.refreshFailure,
            isRetryingRefresh: store.isRetryingRefresh, isConnected: isConnected)
    }
}

/// The Usage tab's page: Token Usage added up across the scope's Hosts,
/// read by day, with Usage Limits kept per Host.
struct AgentUsageDashboard: View {
    let entries: [AgentUsageHostEntry]
    /// nil reads every Host.
    @Binding var scopeHostID: Host.ID?
    /// An iPad's detail column lays the page out in two columns when it
    /// has the width for them.
    var allowsColumns = false

    @State private var metric = AgentUsageMetric.cost
    @State private var range = AgentUsageRange.last30Days
    @State private var scrubbedDay: String?
    @State private var daySheet: AgentUsageDaySelection?
    @State private var isShowingLimits = false
    @State private var breakdown = AgentUsageBreakdown.Kind.models
    @State private var width: CGFloat = 0
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var scopedEntries: [AgentUsageHostEntry] {
        guard let scopeHostID else { return entries }
        return entries.filter { $0.id == scopeHostID }
    }

    var body: some View {
        let scope = AgentUsageScope(readings: scopedEntries.map(\.reading))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                controls
                content(scope)
            }
            .padding(.horizontal, isWide ? 24 : 16)
            .padding(.bottom, 24)
            .frame(maxWidth: isWide ? 1_100 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .modifier(AgentUsageSubtitle(scope: scope))
        // Every Host polls while the page is on screen: the scope menu and
        // an iPad's sidebar show each one's figures whatever the scope.
        .background {
            ForEach(entries) { entry in
                Color.clear.task(id: entry.store.refreshKey) { await entry.store.refresh() }
            }
        }
        .refreshable {
            let stores = scopedEntries.map(\.store)
            await withDiscardingTaskGroup { group in
                for store in stores {
                    group.addTask { await store.pullToRefresh() }
                }
            }
        }
        .sheet(item: $daySheet) { selection in
            AgentUsageDaySheet(scope: scope, selection: selection, isFormSheet: sizeClass == .regular)
                .presentationSizing(.form)
        }
        .sheet(isPresented: $isShowingLimits) {
            AgentUsageLimitsSheet(entries: scopedEntries)
        }
        .onChange(of: scopeHostID) { scrubbedDay = nil }
    }

    private var isWide: Bool { allowsColumns && width >= 860 }

    /// The narrower column beside the chart and the breakdown.
    private var sideColumnWidth: CGFloat { min(max((width - 72) * 0.4, 320), 400) }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Metric", selection: $metric) {
                ForEach(AgentUsageMetric.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: isWide ? 200 : 148)
            Picker("Range", selection: $range) {
                ForEach(AgentUsageRange.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: isWide ? 300 : .infinity)
            if isWide { Spacer(minLength: 0) }
        }
        .pickerStyle(.segmented)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func content(_ scope: AgentUsageScope) -> some View {
        if scope.isEmpty {
            emptyState(scope)
        } else {
            ForEach(scope.included.filter { $0.refreshFailure != nil }) { host in
                failureBanner(host, isOnlyHost: scope.included.count == 1)
            }
            if isWide {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        hero(scope)
                        programsSection(scope)
                    }
                    .frame(width: sideColumnWidth)
                    VStack(alignment: .leading, spacing: 0) {
                        limitsSection(scope)
                        chartCard(scope)
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 0) {
                        calendarCard(scope)
                        if showsHosts(scope) { hostsSection(scope) }
                    }
                    .frame(width: sideColumnWidth)
                    breakdownSection(scope)
                }
            } else {
                hero(scope)
                limitsSection(scope)
                chartCard(scope)
                calendarCard(scope)
                if showsHosts(scope) { hostsSection(scope) }
                programsSection(scope)
                breakdownSection(scope)
            }
            footer(scope)
        }
    }

    // MARK: Hero

    private func hero(_ scope: AgentUsageScope) -> some View {
        let summary = scrubbedDay.map(scope.day) ?? scope.total(range)
        let label: String
        if let scrubbedDay {
            label = AgentUsageCalendarDay.text(scrubbedDay, locale: locale, calendar: calendar,
                includesYear: false)
        } else {
            label = "\(metric == .cost ? "Estimated API cost" : "Token Usage") · \(rangeName)"
        }
        let hostCount = scope.included.count
        let place = hostCount == 1 ? "on this Host" : "on these \(hostCount.formatted()) Hosts"
        return VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric == .cost
                    ? AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale)
                    : AgentUsageStyle.tokens(summary.tokens.total, locale: locale))
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if metric == .tokens {
                    Text("tokens").font(.title3)
                }
            }
            Text(metric == .cost
                ? "\(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens \(place)"
                : "Estimated API cost \(AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale)) \(place)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let unpriced = summary.unpricedTokens, unpriced > 0, metric == .cost {
                Text("Includes unpriced tokens (\(AgentUsageStyle.tokens(unpriced, locale: locale)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !scope.excluded.isEmpty {
                Text("Not included: \(scope.excluded.map(\.name).formatted(.list(type: .and).locale(locale)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 4)
        .contentShape(.rect)
        .onTapGesture { scrubbedDay = nil }
        .accessibilityElement(children: .combine)
    }

    private var rangeName: String {
        switch range {
        case .today: "Today"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        }
    }

    // MARK: Usage Limits

    private func limitsSection(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Usage Limits", detail: scope.included.count > 1 ? "per Host" : nil) {
                Button("Details") { isShowingLimits = true }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AgentUsageLimitChip.chips(in: scope)) { chip in
                        Button { isShowingLimits = true } label: {
                            AgentUsageLimitChipView(chip: chip, showsHost: scope.included.count > 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
        .padding(.top, 22)
    }

    // MARK: Chart and calendar

    private func chartDates(_ scope: AgentUsageScope) -> [String] {
        Array(scope.dates.suffix(max(range.dayCount, 7)))
    }

    private func chartCard(_ scope: AgentUsageScope) -> some View {
        AgentUsageDailyChart(
            scope: scope, metric: metric, dates: chartDates(scope), selection: $scrubbedDay)
            .padding(16)
            .background(cardBackground)
            .padding(.top, 12)
    }

    private func calendarCard(_ scope: AgentUsageScope) -> some View {
        let dates = scope.dates
        let today = dates.last ?? ""
        let first = dates.suffix(30).first ?? today
        let values = Dictionary(uniqueKeysWithValues: dates.map { ($0, metric.value(of: scope.day($0))) })
        let coveredFrom = scope.included.compactMap { $0.report.scan?.coveredFrom }.min()
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(dayText(first)) – \(dayText(today))")
                        .font(.headline)
                    Spacer(minLength: 8)
                    ViewThatFits(in: .horizontal) {
                        Text(metric == .cost ? "Estimated API cost per day" : "Tokens per day")
                        Text("Per day")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                AgentUsageCalendar(values: values, today: today, coveredFrom: coveredFrom) { day in
                    daySheet = AgentUsageDaySelection(day: day, dates: Array(dates.suffix(30)))
                }
            }
            .padding(16)
            .background(cardBackground)
            if let note = scope.dayNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 7)
            }
        }
        .padding(.top, 16)
    }

    // MARK: Hosts

    private func showsHosts(_ scope: AgentUsageScope) -> Bool {
        scopeHostID == nil && entries.count > 1
    }

    private func hostsSection(_ scope: AgentUsageScope) -> some View {
        let total = scope.included.reduce(0) { $0 + metric.value(of: $1.last30Days) }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Hosts", detail: "Last 30 days")
            VStack(spacing: 0) {
                ForEach(Array(scope.included.enumerated()), id: \.element.id) { index, host in
                    if index > 0 { Divider().padding(.leading, 42) }
                    Button { scopeHostID = host.id } label: {
                        hostRow(name: host.name, symbol: "desktopcomputer", tint: .accentColor,
                            subtitle: "\(AgentUsageStyle.share(metric.value(of: host.last30Days), of: total, locale: locale)) · \(AgentUsageStyle.tokens(host.last30Days.tokens.total, locale: locale)) tokens",
                            value: AgentUsageStyle.value(host.last30Days, metric: metric, locale: locale))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(scope.excluded) { host in
                    Divider().padding(.leading, 42)
                    hostRow(name: host.name, symbol: host.reason == "Not connected" ? "wifi.slash" : "desktopcomputer",
                        tint: Color(uiColor: .systemGray3), subtitle: host.reason, value: nil)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .background(cardBackground)
        }
        .padding(.top, 26)
    }

    private func hostRow(name: String, symbol: String, tint: Color, subtitle: String, value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.body.weight(.semibold)).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 62)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    // MARK: Programs

    private func programsSection(_ scope: AgentUsageScope) -> some View {
        let summaries = scope.programs.map { (program: $0, summary: range.summary(in: $0.totals)) }
        let total = summaries.reduce(0) { $0 + metric.value(of: $1.summary) }
        let shareName = metric == .cost ? "of est. cost" : "of tokens"
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Programs", detail: rangeName)
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(summaries, id: \.program.id) { entry in
                            AgentUsageStyle.color(for: entry.program.program)
                                .frame(width: total > 0
                                    ? max((proxy.size.width - CGFloat(summaries.count - 1) * 2)
                                        * metric.value(of: entry.summary) / total, 0) : 0)
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(.capsule)
                .accessibilityHidden(true)
                ForEach(Array(summaries.enumerated()), id: \.element.program.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 16) }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Circle().fill(AgentUsageStyle.color(for: entry.program.program))
                                .frame(width: 8, height: 8)
                            Text(entry.program.displayName)
                            Spacer(minLength: 8)
                            Text(AgentUsageStyle.value(entry.summary, metric: metric, locale: locale))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        Text("\(AgentUsageStyle.share(metric.value(of: entry.summary), of: total, locale: locale)) \(shareName) · \(AgentUsageStyle.tokens(entry.summary.tokens.total, locale: locale)) tokens")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.leading, 16)
                        if let unpriced = entry.summary.unpricedTokens, unpriced > 0 {
                            Text("Includes unpriced tokens (\(AgentUsageStyle.tokens(unpriced, locale: locale)))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .background(cardBackground)
        }
        .padding(.top, 26)
    }

    // MARK: Breakdown

    private func breakdownSection(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Breakdown", detail: "Last 30 days")
            Picker("Breakdown", selection: $breakdown) {
                ForEach(AgentUsageBreakdown.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 10)
            AgentUsageBreakdown(scope: scope, kind: breakdown, metric: metric, limit: isWide ? 8 : 4)
                .padding(.horizontal, 16)
                .background(cardBackground)
        }
        .padding(.top, 26)
    }

    // MARK: Notes

    private func footer(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimated API cost is based on recorded Token Usage, not your subscription bill.")
            ForEach(scope.included) { host in
                Text(Self.coverage(name: host.name, report: host.report, locale: locale, calendar: calendar))
            }
            let versions = Set(scope.included.compactMap(\.report.pricingVersion))
            if !versions.isEmpty {
                Text("Price table: \(versions.sorted().joined(separator: ", "))")
            }
            ForEach(scope.loading) { host in
                Text("\(host.name): Loading Usage…")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 14)
    }

    /// What one Host's report covers: since when, and what it skipped.
    static func coverage(
        name: String, report: AgentUsageReport, locale: Locale, calendar: Calendar
    ) -> String {
        var parts: [String] = []
        if report.scan?.state == "partial" { parts.append("Token Usage is still being summarized.") }
        if let from = report.scan?.coveredFrom {
            var since = "\(name) recorded since \(AgentUsageCalendarDay.text(from, locale: locale, calendar: calendar, includesYear: true))"
            if let zone = report.timeZone { since += " (\(zone))" }
            parts.append(since + ".")
        } else {
            parts.append("No Transcript coverage recorded on \(name) yet.")
        }
        if let skipped = report.scan?.skippedArchives, skipped > 0 {
            parts.append("\(skipped.formatted()) compressed \(skipped == 1 ? "archive" : "archives") skipped.")
        }
        if let unreadable = report.scan?.unreadableFiles, unreadable > 0 {
            parts.append(unreadable == 1
                ? "\(unreadable.formatted()) Transcript or folder could not be read. It is retried on the next refresh."
                : "\(unreadable.formatted()) Transcripts or folders could not be read. They are retried on the next refresh.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: States

    @ViewBuilder
    private func emptyState(_ scope: AgentUsageScope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if entries.isEmpty {
                Text("Add a Host to read its Usage.")
            } else if !scope.loading.isEmpty {
                ProgressView("Loading Usage…")
            } else if let entry = scopedEntries.first, scopedEntries.count == 1, entry.isConnected {
                AgentUsageContent(state: entry.store.state)
            } else {
                Text("No Host in this scope can report Usage right now.")
                ForEach(scope.excluded) { host in
                    Text("\(host.name) · \(host.reason)")
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground)
        .padding(.top, 18)
    }

    private func failureBanner(_ host: AgentUsageScope.IncludedHost, isOnlyHost: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            AgentUsageRefreshFailureNote(
                message: isOnlyHost ? (host.refreshFailure ?? "") : "\(host.name): \(host.refreshFailure ?? "")",
                isRetrying: host.isRetryingRefresh)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .padding(.top, 14)
    }

    // MARK: Pieces

    private var cardBackground: some View {
        Color(uiColor: .secondarySystemGroupedBackground)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
    }

    private func sectionHeader(
        _ title: String, detail: String?, @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).fontWeight(.semibold)
                + Text(detail.map { " · \($0)" } ?? "").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing()
        }
        .font(.subheadline)
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private func dayText(_ day: String, includesYear: Bool = false) -> String {
        AgentUsageCalendarDay.text(day, locale: locale, calendar: calendar, includesYear: includesYear)
    }
}

/// The day a calendar tap opened, and the days its sheet can step through.
struct AgentUsageDaySelection: Identifiable, Equatable {
    var day: String
    let dates: [String]
    var id: String { "day" }
}

/// Refreshing, or when the oldest report was made, under the title.
private struct AgentUsageSubtitle: ViewModifier {
    let scope: AgentUsageScope
    @Environment(\.locale) private var locale

    private var text: String? {
        if scope.refreshing { return "Refreshing" }
        let formatter = ISO8601DateFormatter()
        let oldest = scope.included.compactMap { $0.report.generatedAt.flatMap(formatter.date(from:)) }.min()
        return oldest.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let text {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}
