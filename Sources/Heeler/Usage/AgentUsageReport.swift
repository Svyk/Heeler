import Foundation

/// The plugin's small `usage` v1 response. Unknown fields are deliberately
/// ignored so newer plugins can add data without breaking older apps.
struct AgentUsageReport: Decodable, Equatable, Sendable {
    struct Scan: Decodable, Equatable, Sendable {
        let state: String
        let coveredFrom: String?
        let coveredThrough: String?
        let skippedArchives: Int
    }

    struct Program: Decodable, Equatable, Sendable {
        struct TokenUsage: Decodable, Equatable, Sendable {
            let state: String
            let reason: String?
        }
        struct UsageLimits: Decodable, Equatable, Sendable {
            let state: String
            let reason: String?
        }
        let program: String
        let tokenUsage: TokenUsage
        let usageLimits: UsageLimits
    }

    let version: Int
    let runtime: String
    let generatedAt: String?
    let timeZone: String?
    let refreshing: Bool?
    let scan: Scan?
    let programs: [Program]?

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

enum AgentUsageError: Error, Equatable {
    case unsupportedVersion
    case invalidReport
}
