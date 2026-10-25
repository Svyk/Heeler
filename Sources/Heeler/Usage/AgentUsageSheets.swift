import SwiftUI

/// One Host's tightest Usage Limits window for one program, as a chip.
struct AgentUsageLimitChip: Identifiable, Equatable {
    let hostID: Host.ID
    let hostName: String
    let program: String
    /// nil while there is no live reading to fill the ring with.
    let percent: Double?
    let title: String
    var id: String { "\(hostID)\(program)" }

    /// Live readings first, fullest first; Usage Limits stay per Host.
    static func chips(in scope: AgentUsageScope, now: Date = .now) -> [Self] {
        let formatter = ISO8601DateFormatter()
        let chips = scope.included.flatMap { host in
            host.programs.map { program -> Self in
                let limits = program.usageLimits
                let live = (limits.windows ?? []).filter { window in
                    !window.expired && window.usedPercent != nil
                        && window.resetsAt.flatMap(formatter.date(from:)).map { $0 > now } != false
                }
                let tightest = live.max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
                let title: String
                if let tightest, limits.state == "ok" || limits.state == "throttled" {
                    title = AgentUsageLimitsView.windowName(tightest, program: program.program)
                } else if limits.state == "disabled" {
                    title = "Limits off"
                } else if limits.state == "unavailable" && limits.reason == "notReadYet" {
                    title = "Reading…"
                } else {
                    title = "Unavailable"
                }
                return Self(
                    hostID: host.id, hostName: host.name, program: program.program,
                    percent: limits.state == "ok" || limits.state == "throttled" ? tightest?.usedPercent : nil,
                    title: title)
            }
        }
        return chips.enumerated().sorted { lhs, rhs in
            switch (lhs.element.percent, rhs.element.percent) {
            case (let left?, let right?): left == right ? lhs.offset < rhs.offset : left > right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }
}

struct AgentUsageLimitChipView: View {
    let chip: AgentUsageLimitChip
    let showsHost: Bool
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 3.5)
                if let percent = chip.percent {
                    Circle()
                        .trim(from: 0, to: min(max(percent / 100, 0), 1))
                        .stroke(ringColor(percent), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text((percent / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale)))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle().fill(AgentUsageStyle.color(for: chip.program)).frame(width: 7, height: 7)
                    Text(showsHost ? chip.hostName
                        : AgentUsageReport.Program.displayName(for: chip.program))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(showsHost
                    ? "\(AgentUsageReport.Program.displayName(for: chip.program)) · \(chip.title)"
                    : chip.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chip.percent == nil ? .secondary : .primary)
            }
            .lineLimit(1)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 56)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Neutral until a window runs low.
    private func ringColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return AgentUsageStyle.color(for: chip.program)
    }
}

/// Models, directories, or days over the last 30 days.
struct AgentUsageBreakdown: View {
    enum Kind: String, CaseIterable, Identifiable {
        case models, directories, days
        var id: Self { self }
        var title: String {
            switch self {
            case .models: "Models"
            case .directories: "Directories"
            case .days: "Days"
            }
        }
    }

    struct Row: Identifiable {
        let id: String
        let program: String?
        let title: String
        let subtitle: String?
        let summary: AgentUsageReport.Summary
        let priced: Bool
    }

    let scope: AgentUsageScope
    let kind: Kind
    let metric: AgentUsageMetric
    /// Rows before Show All; nil shows every row.
    var limit: Int?
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        let rows = Self.rows(kind, in: scope, locale: locale, calendar: calendar)
        let total = rows.reduce(0) { $0 + metric.value(of: $1.summary) }
        let shown = limit.map { Array(rows.prefix($0)) } ?? rows
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 18) }
                rowView(row, total: total)
            }
            if shown.isEmpty {
                Text("Nothing recorded in the last 30 days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }
            if let limit, rows.count > limit {
                Divider()
                NavigationLink {
                    List {
                        AgentUsageBreakdown(scope: scope, kind: kind, metric: metric)
                    }
                    .navigationTitle("\(kind.title) · Last 30 days")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Text("Show All \(rows.count.formatted()) \(kind.title)")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private func rowView(_ row: Row, total: Double) -> some View {
        let value = metric.value(of: row.summary)
        return HStack(spacing: 10) {
            Circle()
                .fill(row.program.map(AgentUsageStyle.color(for:)) ?? Color.secondary)
                .frame(width: 8, height: 8)
                .opacity(row.program == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(kind == .directories ? .subheadline.monospaced() : .subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { proxy in
                    (row.program.map(AgentUsageStyle.color(for:)) ?? Color.secondary)
                        .frame(width: total > 0 ? proxy.size.width * value / total : 0)
                }
                .frame(height: 2)
                .clipShape(.capsule)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(AgentUsageStyle.value(row.summary, metric: metric, locale: locale))
                    .font(.subheadline.weight(.semibold))
                Text("\(AgentUsageStyle.share(value, of: total, locale: locale)) · \(metric == .cost ? "\(AgentUsageStyle.tokens(row.summary.tokens.total, locale: locale)) tokens" : AgentUsageStyle.cost(row.summary.estimatedCostUSD, locale: locale))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !row.priced {
                    Text("Includes unpriced tokens").font(.caption).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .layoutPriority(1)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    static func rows(_ kind: Kind, in scope: AgentUsageScope, locale: Locale, calendar: Calendar) -> [Row] {
        switch kind {
        case .models:
            return scope.programs.flatMap { program in
                program.models.map { model in
                    Row(id: "\(program.program)\(model.model)", program: program.program, title: model.model,
                        subtitle: nil, summary: model.summary,
                        priced: model.priced)
                }
            }
            .sorted { $0.summary.tokens.total > $1.summary.tokens.total }
        case .directories:
            let showsHost = scope.included.count > 1
            return scope.programs.flatMap { program in
                program.directories.map { entry in
                    Row(id: "\(program.program)\(entry.id)", program: program.program,
                        title: entry.directory.path,
                        subtitle: showsHost ? entry.hostName : nil,
                        summary: entry.directory.summary, priced: entry.directory.unpricedTokens == 0)
                }
            }
            .sorted { $0.summary.tokens.total > $1.summary.tokens.total }
        case .days:
            return scope.dates.suffix(30).reversed().map { day in
                Row(id: day, program: nil,
                    title: AgentUsageCalendarDay.text(day, locale: locale, calendar: calendar, includesYear: false),
                    subtitle: nil, summary: scope.day(day), priced: true)
            }
        }
    }
}

/// A calendar day: the scope's total, each Host's, and each program's
/// token-type split. Models and directories exist only for 30 days.
struct AgentUsageDaySheet: View {
    let scope: AgentUsageScope
    @State var selection: AgentUsageDaySelection
    /// A regular-width page shows a form sheet: the sheet's own size class
    /// is compact, so the page decides.
    var isFormSheet = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    let summary = scope.day(selection.day)
                    Text(AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale))
                        .font(.system(size: 34, weight: .semibold))
                        .monospacedDigit()
                        .padding(.top, 10)
                    Text("Estimated API cost · \(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if scope.included.count > 1 { byHost }
                    byProgram
                    links
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // An iPhone keeps the page reachable above the sheet; a form sheet
        // floats over it at its full height.
        .presentationDetents(isFormSheet ? [.large] : [.fraction(0.64), .large])
        .presentationBackgroundInteraction(
            isFormSheet ? .disabled : .enabled(upThrough: .fraction(0.64)))
    }

    private var header: some View {
        let index = selection.dates.firstIndex(of: selection.day)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(AgentUsageCalendarDay.date(selection.day)?.formatted(
                    Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt)
                        .weekday(.abbreviated).month(.abbreviated).day()) ?? selection.day)
                    .font(.title2.bold())
                Text(scope.included.count == 1
                    ? "Token Usage on this Host" : "Token Usage on these \(scope.included.count.formatted()) Hosts")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Previous Day", systemImage: "chevron.left") {
                if let index, index > 0 { selection.day = selection.dates[index - 1] }
            }
            .disabled(index.map { $0 == 0 } ?? true)
            Button("Next Day", systemImage: "chevron.right") {
                if let index, index < selection.dates.count - 1 { selection.day = selection.dates[index + 1] }
            }
            .disabled(index.map { $0 >= selection.dates.count - 1 } ?? true)
            Button("Close", systemImage: "xmark") { dismiss() }
                .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .padding(.top, 20)
    }

    private var byHost: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By Host").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(scope.included.enumerated()), id: \.element.id) { index, host in
                    if index > 0 { Divider().padding(.leading, 30) }
                    let summary = AgentUsageScope.sum(host.programs.compactMap { program in
                        program.okTotals == nil ? nil
                            : program.tokenUsage.daily?.first { $0.date == selection.day }?.summary
                    })
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(host.name).font(.subheadline.weight(.medium))
                            Text([AgentUsageCalendarDay.text(selection.day, locale: locale, calendar: calendar,
                                includesYear: false), host.report.timeZone].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(AgentUsageStyle.cost(summary.estimatedCostUSD, locale: locale))
                                .font(.subheadline.weight(.semibold))
                            Text("\(AgentUsageStyle.tokens(summary.tokens.total, locale: locale)) tokens")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .monospacedDigit()
                    }
                    .frame(minHeight: 52)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 16, style: .continuous))
        }
        .padding(.top, 18)
    }

    private var byProgram: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("By program").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(scope.programs) { program in
                let summary = program.daily.first { $0.date == selection.day }?.summary
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(AgentUsageStyle.color(for: program.program)).frame(width: 8, height: 8)
                        Text(program.displayName).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Text(summary.map { AgentUsageStyle.cost($0.estimatedCostUSD, locale: locale) } ?? "–")
                            .font(.subheadline.weight(.semibold))
                        Text(summary.map { "\(AgentUsageStyle.tokens($0.tokens.total, locale: locale)) tokens" } ?? "")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 84, alignment: .trailing)
                    }
                    .monospacedDigit()
                    AgentUsageTokenSplit(tokens: summary?.tokens ?? .zero)
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
            }
            AgentUsageTokenLegend().padding(.top, 10)
        }
        .padding(.top, 16)
    }

    private var links: some View {
        VStack(spacing: 0) {
            ForEach([AgentUsageBreakdown.Kind.models, .directories]) { kind in
                if kind == .directories { Divider() }
                NavigationLink {
                    List { AgentUsageBreakdown(scope: scope, kind: kind, metric: .cost) }
                        .navigationTitle("\(kind.title) · Last 30 days")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    HStack {
                        Text("\(kind.title) · Last 30 days")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 16, style: .continuous))
        .padding(.top, 14)
    }
}

/// Usage Limits grouped by Host, never merged, each Host with its own
/// Claude Code limits consent.
struct AgentUsageLimitsSheet: View {
    let entries: [AgentUsageHostEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                } footer: {
                    Text("Usage Limits are shown per Host. Two Hosts signed in to the same account show the same windows.")
                }
                ForEach(entries) { entry in
                    Section {
                        if case .available(let report) = entry.store.state {
                            ForEach(report.programs ?? [], id: \.program) { program in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 7) {
                                        Circle().fill(AgentUsageStyle.color(for: program.program))
                                            .frame(width: 8, height: 8)
                                        Text(program.displayName).font(.headline)
                                        if let plan = program.usageLimits.plan {
                                            Text(plan.capitalized)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Color(uiColor: .tertiarySystemFill),
                                                    in: .rect(cornerRadius: 5))
                                        }
                                    }
                                    AgentUsageLimitsView(
                                        program: program.program, limits: program.usageLimits, showsTitle: false)
                                }
                                if program.program == "claude" { ClaudeUsageSettings(store: entry.store) }
                            }
                        } else {
                            AgentUsageContent(state: entry.isConnected ? entry.store.state
                                : .failed("Not connected"))
                        }
                    } header: {
                        Label(entry.name, systemImage: "desktopcomputer")
                    }
                }
                Section {
                } footer: {
                    CodexUsageLimitsNote()
                }
            }
            .navigationTitle("Usage Limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}
