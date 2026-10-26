import Foundation
import WidgetKit

/// One Host as the app last read it, for the widgets' snapshot.
struct AgentUsageWidgetReading: Equatable {
    let id: Host.ID
    let name: String
    let state: AgentUsageStore.State
    let readAt: Date?
    let isConnected: Bool
}

/// Keeps the widgets' snapshot in step with the app's Usage readings and
/// asks WidgetKit to redraw when it changes.
@MainActor
final class AgentUsageWidgetPublisher {
    private let store: UsageWidgetSnapshotStore
    private let reloadTimelines: @MainActor () -> Void
    private lazy var published: UsageWidgetSnapshot? = store.read()

    init(
        store: UsageWidgetSnapshotStore = UsageWidgetSnapshotStore(),
        reloadTimelines: @escaping @MainActor () -> Void = {
            WidgetCenter.shared.reloadTimelines(ofKind: UsageWidgetSnapshotStore.usageKind)
            WidgetCenter.shared.reloadTimelines(ofKind: UsageWidgetSnapshotStore.limitsKind)
        }
    ) {
        self.store = store
        self.reloadTimelines = reloadTimelines
    }

    func publish(_ readings: [AgentUsageWidgetReading], now: Date = .now) {
        let next = UsageWidgetSnapshot(readings: readings, previous: published, now: now)
        guard next != published else { return }
        published = next
        store.write(next)
        reloadTimelines()
    }
}

extension UsageWidgetSnapshot {
    /// The snapshot after `readings`, in their order. A Host the app has no
    /// newer report for keeps the one `previous` holds, so a launch or a
    /// dropped connection does not empty the widgets; a Host that answered
    /// it cannot report loses its figures.
    init(readings: [AgentUsageWidgetReading], previous: UsageWidgetSnapshot?, now: Date) {
        self.init(hosts: readings.map { reading in
            switch reading.state {
            case .available(let report):
                return Host(id: reading.id, name: reading.name, report: report, readAt: reading.readAt ?? now)
            case .requirement, .unsupportedPlatform, .runtimeMissing, .updateRequired:
                return Host(id: reading.id, name: reading.name, excludedReason: AgentUsageScope.reason(for: reading.state))
            case .idle, .loading, .failed:
                if var kept = previous?.host(reading.id), kept.reports {
                    kept.name = reading.name
                    return kept
                }
                let reason = if !reading.isConnected {
                    "Not connected"
                } else if case .failed = reading.state {
                    AgentUsageScope.reason(for: reading.state)
                } else {
                    "Not read yet"
                }
                return Host(id: reading.id, name: reading.name, excludedReason: reason)
            }
        })
    }
}

extension UsageWidgetSnapshot.Host {
    init(id: UUID, name: String, excludedReason: String) {
        self.init(id: id, name: name, readAt: nil, excludedReason: excludedReason, timeZone: nil,
            programs: [], limits: [])
    }

    init(id: UUID, name: String, report: AgentUsageReport, readAt: Date) {
        let programs = report.programs ?? []
        self.init(
            id: id, name: name, readAt: readAt, excludedReason: nil, timeZone: report.timeZone,
            programs: programs.compactMap { program in
                guard let totals = program.okTotals else { return nil }
                return UsageWidgetSnapshot.Program(
                    program: program.program, name: program.displayName,
                    today: .init(totals.today), last7Days: .init(totals.last7Days),
                    last30Days: .init(totals.last30Days),
                    days: (program.tokenUsage.daily ?? []).map { .init(date: $0.date, summary: .init($0.summary)) })
            },
            limits: programs.map(UsageWidgetSnapshot.Limits.init))
    }
}

extension UsageWidgetSnapshot.Summary {
    init(_ summary: AgentUsageReport.Summary) {
        self.init(cost: summary.estimatedCostUSD, tokens: summary.tokens.total)
    }
}

extension UsageWidgetSnapshot.Limits {
    init(_ program: AgentUsageReport.Program) {
        let limits = program.usageLimits
        let shown = limits.state == "ok" || limits.state == "throttled"
        let windows = shown ? limits.windows ?? [] : []
        let message: String? = if shown {
            windows.isEmpty ? "No Usage Limits windows reported." : nil
        } else if limits.state == "unavailable" && limits.reason == "notReadYet" {
            "Open Heeler to read Usage Limits."
        } else {
            AgentUsageLimitsView.unavailableMessage(limits, program: program.program)
        }
        self.init(
            program: program.program, name: program.displayName, message: message,
            isLastReading: limits.state == "throttled",
            source: shown ? (limits.source == "lastSession" ? .lastSession : .program) : nil,
            observedAt: AgentUsageLimitsView.date(limits.observedAt),
            windows: windows.map { window in
                UsageWidgetSnapshot.Window(
                    id: window.id, name: AgentUsageLimitsView.windowName(window, program: program.program),
                    usedPercent: window.usedPercent, resetsAt: AgentUsageLimitsView.date(window.resetsAt),
                    expired: window.expired)
            })
    }
}
