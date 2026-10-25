import SwiftUI

/// What the Usage tab's figures count.
enum AgentUsageMetric: String, CaseIterable, Identifiable, Sendable {
    case cost
    case tokens

    var id: Self { self }

    var title: String {
        switch self {
        case .cost: "Est. Cost"
        case .tokens: "Tokens"
        }
    }

    func value(of summary: AgentUsageReport.Summary) -> Double {
        switch self {
        case .cost: summary.estimatedCostUSD ?? 0
        case .tokens: Double(summary.tokens.total)
        }
    }
}

/// Colors and number formats every Usage surface shares.
enum AgentUsageStyle {
    static func color(for program: String) -> Color {
        switch program {
        case "claude":
            Color(light: UIColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1),
                dark: UIColor(red: 0.878, green: 0.541, blue: 0.427, alpha: 1))
        case "codex":
            Color(light: UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1),
                dark: UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1))
        default:
            Color(uiColor: .systemGray)
        }
    }

    /// The token types a split bar shows, darkest last.
    @MainActor static let tokenTypes: [(label: String, keyPath: KeyPath<AgentUsageReport.Tokens, Int64>, color: Color)] = [
        ("Input", \.input, Color(light: UIColor(white: 0.42, alpha: 1), dark: UIColor(white: 0.63, alpha: 1))),
        ("Cache read", \.cacheRead, Color(light: UIColor(white: 0.71, alpha: 1), dark: UIColor(white: 0.36, alpha: 1))),
        ("Cache write", \.cacheWrite, Color(light: UIColor(white: 0.28, alpha: 1), dark: UIColor(white: 0.79, alpha: 1))),
        ("Output", \.output, Color(light: UIColor(white: 0.12, alpha: 1), dark: UIColor(white: 0.95, alpha: 1))),
    ]

    static func cost(_ value: Double?, locale: Locale) -> String {
        guard let value else { return "Unpriced" }
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD").locale(locale)
        if value > 0 && value < 0.01 { return "< \(0.01.formatted(style))" }
        return value.formatted(style)
    }

    /// Whole dollars once a figure is large enough that cents are noise.
    static func shortCost(_ value: Double?, locale: Locale) -> String {
        guard let value else { return "Unpriced" }
        guard value >= 1_000 else { return cost(value, locale: locale) }
        return value.formatted(
            FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0)).locale(locale))
    }

    static func tokens(_ value: Int64, locale: Locale) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(locale))
    }

    static func share(_ part: Double, of whole: Double, locale: Locale) -> String {
        guard whole > 0 else { return 0.0.formatted(.percent.locale(locale)) }
        return (part / whole).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// The figure for one summary in the chosen metric.
    static func value(
        _ summary: AgentUsageReport.Summary, metric: AgentUsageMetric, locale: Locale
    ) -> String {
        switch metric {
        case .cost: cost(summary.estimatedCostUSD, locale: locale)
        case .tokens: "\(tokens(summary.tokens.total, locale: locale)) tokens"
        }
    }
}

extension Color {
    fileprivate init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}
