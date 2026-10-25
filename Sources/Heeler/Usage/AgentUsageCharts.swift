import Charts
import SwiftUI

/// The Usage tab's daily chart: one curve per program. Touch and hold to
/// read a day; the selection is the plugin's day text.
struct AgentUsageDailyChart: View {
    let scope: AgentUsageScope
    let metric: AgentUsageMetric
    /// The newest days shown; Today keeps a week for context.
    let dates: [String]
    @Binding var selection: String?
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private struct Point: Identifiable {
        let program: String
        let date: Date
        let value: Double
        var id: String { "\(program)\(date.timeIntervalSince1970)" }
    }

    private var points: [Point] {
        scope.programs.flatMap { program in
            dates.compactMap { day -> Point? in
                guard let date = AgentUsageCalendarDay.date(day) else { return nil }
                let summary = program.daily.first { $0.date == day }?.summary
                return Point(
                    program: program.displayName, date: date,
                    value: summary.map(metric.value(of:)) ?? 0)
            }
        }
    }

    private var programNames: [String] { scope.programs.map(\.displayName) }
    private var programColors: [Color] { scope.programs.map { AgentUsageStyle.color(for: $0.program) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ForEach(scope.programs) { program in
                    HStack(spacing: 6) {
                        Circle().fill(AgentUsageStyle.color(for: program.program)).frame(width: 8, height: 8)
                        Text(program.displayName)
                    }
                }
                Spacer(minLength: 8)
                Text("Hold to read a day").foregroundStyle(.secondary)
            }
            .font(.footnote)
            .lineLimit(1)
            .accessibilityHidden(true)
            Chart {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value(metric.title, point.value),
                        stacking: .unstacked)
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Program", point.program))
                        .opacity(0.18)
                    LineMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value(metric.title, point.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Program", point.program))
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    if let selectedDate, Calendar.gmt.isDate(selectedDate, inSameDayAs: point.date) {
                        PointMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value(metric.title, point.value))
                            .foregroundStyle(by: .value("Program", point.program))
                            .symbolSize(30)
                    }
                }
                if let selectedDate, let selection {
                    RuleMark(x: .value("Day", selectedDate, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .top, spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            AgentUsageDayReadout(scope: scope, day: selection)
                        }
                }
            }
            .chartForegroundStyleScale(domain: programNames, range: programColors)
            .chartLegend(.hidden)
            .chartXSelection(value: selectionBinding)
            .chartXAxis {
                AxisMarks(values: axisDates) { value in
                    // The ends stay inside the plot's width.
                    AxisValueLabel(anchor: value.index == axisDates.count - 1 ? .topTrailing
                        : value.index == 0 ? .topLeading : .top) {
                        if let date = value.as(Date.self) { Text(axisText(date)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(axisValue(number)) }
                    }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Daily \(metric == .cost ? "estimated API cost" : "tokens")")
        }
    }

    private var selectedDate: Date? { selection.flatMap(AgentUsageCalendarDay.date) }

    private var selectionBinding: Binding<Date?> {
        Binding(
            get: { selectedDate },
            set: { date in selection = date.map(Self.day(of:)) })
    }

    /// Four labels, the newest always named.
    private var axisDates: [Date] {
        let all = dates.compactMap(AgentUsageCalendarDay.date)
        guard all.count > 4 else { return all }
        let step = max((all.count - 1) / 3, 1)
        return stride(from: all.count - 1, through: 0, by: -step).map { all[$0] }.reversed()
    }

    private func axisText(_ date: Date) -> String {
        AgentUsageCalendarDay.text(Self.day(of: date), locale: locale, calendar: calendar,
            includesYear: false)
    }

    private func axisValue(_ value: Double) -> String {
        switch metric {
        case .cost:
            // Cents only for ticks between whole dollars, so $0.50 is not
            // shown as $0.
            value.formatted(.currency(code: "USD")
                .precision(.fractionLength(value.rounded() == value ? 0 : 2)).locale(locale))
        case .tokens:
            value.formatted(.number.notation(.compactName).locale(locale))
        }
    }

    static func day(of date: Date) -> String {
        let parts = Calendar.gmt.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// One day's figures while the chart is held: each program, then each Host.
struct AgentUsageDayReadout: View {
    let scope: AgentUsageScope
    let day: String
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(AgentUsageCalendarDay.text(day, locale: locale, calendar: calendar, includesYear: false))
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 8)
                Text("Est. cost").fixedSize().frame(minWidth: 52, alignment: .trailing)
                Text("Tokens").frame(width: 44, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ForEach(scope.programs) { program in
                row(program.displayName,
                    summary: program.daily.first { $0.date == day }?.summary) {
                    Circle().fill(AgentUsageStyle.color(for: program.program)).frame(width: 7, height: 7)
                }
            }
            if scope.included.count > 1 {
                Divider().padding(.vertical, 2)
                ForEach(scope.included) { host in
                    row(host.name, summary: AgentUsageScope.sum(host.programs.compactMap { program in
                        program.okTotals == nil ? nil
                            : program.tokenUsage.daily?.first { $0.date == day }?.summary
                    })) {
                        Image(systemName: "desktopcomputer").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 256)
        // A material renders as a dark slab inside a chart annotation.
        .background(Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func row(
        _ name: String, summary: AgentUsageReport.Summary?, @ViewBuilder mark: () -> some View
    ) -> some View {
        HStack(spacing: 6) {
            mark().frame(width: 10)
            Text(name).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 4)
            Text(summary.map { AgentUsageStyle.cost($0.estimatedCostUSD, locale: locale) } ?? "–")
                .fontWeight(.semibold)
                .fixedSize()
                .frame(minWidth: 52, alignment: .trailing)
            Text(summary.map { AgentUsageStyle.tokens($0.tokens.total, locale: locale) } ?? "–")
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}

/// The last 30 days as a month grid, tinted by each day's figure. Days
/// before the earliest coverage are hatched; tapping a day selects it.
struct AgentUsageCalendar: View {
    let values: [String: Double]
    /// The newest reported day.
    let today: String
    let coveredFrom: String?
    let select: (String) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var colorScheme

    private struct Cell: Identifiable {
        let day: String
        let number: String
        let level: Int?
        let isToday: Bool
        let isFuture: Bool
        let isUncovered: Bool
        var id: String { day }
    }

    var body: some View {
        let cells = self.cells
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<(cells.count / 7), id: \.self) { row in
                    GridRow {
                        ForEach(cells[(row * 7)..<(row * 7 + 7)]) { cell in
                            cellView(cell)
                        }
                    }
                }
            }
            legend
        }
    }

    private func cellView(_ cell: Cell) -> some View {
        let fill = cell.level.map(Self.ramp) ?? .clear
        let isDark = (cell.level ?? 0) >= 3
        return Button {
            select(cell.day)
        } label: {
            Text(cell.number)
                .font(.footnote.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(isDark ? Color(uiColor: .systemBackground)
                    : cell.isFuture || cell.isUncovered ? Color(uiColor: .tertiaryLabel) : .primary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(cell.isUncovered ? Color.clear : fill)
                        .overlay {
                            if cell.isUncovered { Hatch().clipShape(.rect(cornerRadius: 8, style: .continuous)) }
                        }
                }
                .overlay {
                    if cell.isToday {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(cell.isFuture || cell.isUncovered)
        .accessibilityLabel(AgentUsageCalendarDay.text(cell.day, locale: locale, calendar: calendar,
            includesYear: false))
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less")
            ForEach(0..<5) { level in
                RoundedRectangle(cornerRadius: 2.5).fill(Self.ramp(level)).frame(width: 10, height: 10)
            }
            Text("More")
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: 10, height: 10)
            Text("Today")
            Hatch().frame(width: 10, height: 10).clipShape(.rect(cornerRadius: 2.5))
                .padding(.leading, 6)
            Text("Not recorded")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }

    /// A neutral ramp from barely there to near black (near white in dark).
    static func ramp(_ level: Int) -> Color {
        let opacities = [0.06, 0.16, 0.30, 0.55, 0.85]
        return Color.primary.opacity(opacities[min(max(level, 0), 4)])
    }

    /// Monday first.
    private var weekdaySymbols: [String] {
        var calendar = calendar
        calendar.locale = locale
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return Array(symbols[1...]) + [symbols[0]]
    }

    private var cells: [Cell] {
        guard let end = AgentUsageCalendarDay.date(today),
            let start = Calendar.gmt.date(byAdding: .day, value: -29, to: end)
        else { return [] }
        // Monday of the first week through Sunday of the last.
        let leading = (Calendar.gmt.component(.weekday, from: start) + 5) % 7
        let trailing = 6 - (Calendar.gmt.component(.weekday, from: end) + 5) % 7
        let first = Calendar.gmt.date(byAdding: .day, value: -leading, to: start) ?? start
        let count = leading + 30 + trailing
        let maximum = values.values.max() ?? 0
        let covered = coveredFrom.flatMap(AgentUsageCalendarDay.date)
        return (0..<count).compactMap { offset in
            guard let date = Calendar.gmt.date(byAdding: .day, value: offset, to: first) else { return nil }
            let day = AgentUsageDailyChart.day(of: date)
            let dayOfMonth = Calendar.gmt.component(.day, from: date)
            let number = dayOfMonth == 1 || offset == leading
                ? AgentUsageCalendarDay.text(day, locale: locale, calendar: calendar, includesYear: false)
                : dayOfMonth.formatted()
            let value = values[day] ?? 0
            let level = maximum > 0 ? Int((value / maximum * 4).rounded(.up)) : 0
            return Cell(
                day: day, number: number, level: level, isToday: day == today, isFuture: date > end,
                isUncovered: date < start || covered.map { date < $0 } == true)
        }
    }
}

/// Diagonal hairlines for days nothing was recorded on.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4
            }
            context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// A token-type split, as one thin bar.
struct AgentUsageTokenSplit: View {
    let tokens: AgentUsageReport.Tokens

    var body: some View {
        GeometryReader { proxy in
            let total = max(Double(AgentUsageStyle.tokenTypes.reduce(Int64(0)) { $0 + tokens[keyPath: $1.keyPath] }), 1)
            let gaps = CGFloat(AgentUsageStyle.tokenTypes.count - 1) * 1.5
            HStack(spacing: 1.5) {
                ForEach(AgentUsageStyle.tokenTypes, id: \.label) { type in
                    type.color.frame(width: max((proxy.size.width - gaps)
                        * Double(tokens[keyPath: type.keyPath]) / total, 0))
                }
            }
        }
        .frame(height: 8)
        .clipShape(.rect(cornerRadius: 2))
        .accessibilityHidden(true)
    }
}

struct AgentUsageTokenLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(AgentUsageStyle.tokenTypes, id: \.label) { type in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2.5).fill(type.color).frame(width: 10, height: 10)
                    Text(type.label)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityHidden(true)
    }
}

extension Calendar {
    /// The plugin's days are already in the report's time zone.
    static let gmt: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
