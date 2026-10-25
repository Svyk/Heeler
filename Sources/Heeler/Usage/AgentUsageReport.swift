import Foundation

/// The plugin's small `usage` v1 response. Unknown fields are deliberately
/// ignored so newer plugins can add data without breaking older apps.
struct AgentUsageReport: Decodable, Equatable, Sendable {
    struct Scan: Decodable, Equatable, Sendable {
        let state: String
        let coveredFrom: String?
        let coveredThrough: String?
        let skippedArchives: Int
        /// Transcripts or folders the last run could not read; the plugin
        /// retries them. Optional so a report without the count still decodes.
        let unreadableFiles: Int?
    }

    struct Tokens: Decodable, Equatable, Sendable {
        let input: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let output: Int64
        /// Informative only: already included in output for programs that report it.
        let reasoning: Int64
        let total: Int64
    }

    struct Summary: Decodable, Equatable, Sendable {
        let tokens: Tokens
        let estimatedCostUSD: Double?
        let unpricedTokens: Int64?
    }

    struct Totals: Decodable, Equatable, Sendable {
        let today: Summary
        let last7Days: Summary
        let last30Days: Summary
    }

    struct Daily: Decodable, Equatable, Sendable {
        let date: String
        let tokens: Tokens
        let estimatedCostUSD: Double?
        let unpricedTokens: Int64?
    }

    struct Model: Decodable, Equatable, Sendable {
        let model: String
        let priced: Bool
        let tokens: Tokens
        let estimatedCostUSD: Double?
        let unpricedTokens: Int64
    }

    struct Directory: Decodable, Equatable, Sendable {
        let path: String
        let tokens: Tokens
        let estimatedCostUSD: Double?
        let unpricedTokens: Int64
    }

    struct Program: Decodable, Equatable, Sendable {
        struct TokenUsage: Decodable, Equatable, Sendable {
            let state: String
            let reason: String?
            let totals: Totals?
            let daily: [Daily]?
            let models: [Model]?
            let directories: [Directory]?
        }
        struct UsageLimits: Decodable, Equatable, Sendable {
            struct Window: Decodable, Equatable, Sendable, Identifiable {
                let id: String
                let label: String?
                let durationMinutes: Int?
                let usedPercent: Double?
                let resetsAt: String?
                let expired: Bool
            }

            let state: String
            let reason: String?
            let source: String?
            let observedAt: String?
            let retryAt: String?
            let plan: String?
            let windows: [Window]?
        }
        let program: String
        let tokenUsage: TokenUsage
        var usageLimits: UsageLimits

        var displayName: String { Self.displayName(for: program) }

        /// A program a newer plugin adds keeps its own id rather than
        /// borrowing a known program's name.
        static func displayName(for program: String) -> String {
            switch program {
            case "claude": "Claude Code"
            case "codex": "Codex"
            default: program
            }
        }
    }

    let version: Int
    let runtime: String
    let generatedAt: String?
    let timeZone: String?
    let refreshing: Bool?
    let pricingVersion: String?
    let scan: Scan?
    var programs: [Program]?

    /// A device that opted out must never show a reading cached by another query.
    func hidingClaudeLimits() -> Self {
        replacingClaudeLimits(state: "disabled", reason: nil)
    }

    /// Right after the toggle turns on, this report's query did not ask for
    /// Claude Code limits; they read as not read yet, not as off.
    func readingClaudeLimits() -> Self {
        replacingClaudeLimits(state: "unavailable", reason: "notReadYet")
    }

    /// The query that would have read Claude Code limits after the toggle
    /// turned on failed; they read as failed, not as still being read.
    func failedClaudeLimits() -> Self {
        replacingClaudeLimits(state: "error", reason: "requestFailed")
    }

    private func replacingClaudeLimits(state: String, reason: String?) -> Self {
        var report = self
        report.programs = programs?.map { program in
            guard program.program == "claude" else { return program }
            var replaced = program
            replaced.usageLimits = .init(state: state, reason: reason, source: nil,
                observedAt: nil, retryAt: nil, plan: nil, windows: nil)
            return replaced
        }
        return report
    }

    static func decode(_ data: Data) throws -> Self {
        // Check the envelope before interpreting any version-specific fields.
        struct Envelope: Decodable { let version: Int }
        let decoder = JSONDecoder()
        guard try decoder.decode(Envelope.self, from: data).version == 1 else {
            throw AgentUsageError.unsupportedVersion
        }
        let report = try decoder.decode(Self.self, from: data)
        guard report.runtime == "missing" || (
            report.runtime == "recorded" && report.generatedAt != nil
                && report.timeZone != nil && report.refreshing != nil
                && report.scan != nil && report.programs != nil)
        else { throw AgentUsageError.invalidReport }
        return report
    }
}

/// The plugin's `YYYY-MM-DD` days are already folded into the report's time
/// zone, so they are parsed and formatted in UTC and never shift a second
/// time on a phone in another zone.
enum AgentUsageCalendarDay {
    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let dayOfMonth = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = DateComponents(year: year, month: month, day: dayOfMonth)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// The day in the reader's locale and calendar, or the plugin's text
    /// when it is not a date.
    static func text(
        _ day: String, locale: Locale, calendar: Calendar, includesYear: Bool, includesWeekday: Bool = false
    ) -> String {
        guard let date = date(day) else { return day }
        var calendar = calendar
        calendar.timeZone = .gmt
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).month(.abbreviated).day()
        if includesYear { style = style.year() }
        if includesWeekday { style = style.weekday(.abbreviated) }
        return date.formatted(style)
    }
}

enum AgentUsageError: Error, Equatable {
    case unsupportedVersion
    case invalidReport
}
