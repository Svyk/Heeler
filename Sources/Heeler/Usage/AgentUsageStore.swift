import Foundation
import Observation

/// One Host's on-demand Usage reading. Connections are borrowed from Console;
/// opening Usage never starts an independent SSH connection.
@MainActor
@Observable
final class AgentUsageStore {
    enum State: Equatable, Sendable {
        case idle
        case loading
        case requirement(String)
        case unsupportedPlatform
        case runtimeMissing
        case updateRequired
        case available(AgentUsageReport)
        case failed(String)
    }

    /// What a visible surface keys its refresh task on: the request it
    /// carries, and a generation the store advances to restart polling.
    struct RefreshKey: Hashable {
        let claudeLimits: Bool
        let generation: Int
    }

    /// The re-query cadence while the plugin's worker is refreshing.
    nonisolated static let pollInterval: Duration = .seconds(3)
    /// A shown report's failed refreshes are retried with a backoff that
    /// doubles from `pollInterval` up to this interval.
    nonisolated static let maximumRetryInterval: Duration = .seconds(30)

    private var snapshotState: State = .idle
    /// Whether the shown report's query asked for Claude Code limits.
    private var snapshotIncludesClaudeLimits = false
    var state: State {
        guard case .available(let report) = snapshotState else { return snapshotState }
        if !claudeLimitsEnabled { return .available(report.hidingClaudeLimits()) }
        // The toggle turned on after this report: its "off" reading is no
        // longer this device's choice while the re-query is underway.
        if !snapshotIncludesClaudeLimits { return .available(report.readingClaudeLimits()) }
        return snapshotState
    }
    /// A refresh is running: a read is in flight or polling continues.
    private(set) var isLoading = false
    /// Why the last refresh failed while the earlier report stays shown.
    private(set) var refreshFailure: String?
    /// Advanced when visible surfaces should start polling again.
    private(set) var refreshGeneration = 0
    var claudeLimitsEnabled: Bool {
        didSet {
            guard oldValue != claudeLimitsEnabled else { return }
            defaults.set(claudeLimitsEnabled, forKey: preferenceKey)
            endRefresh()
        }
    }

    var refreshKey: RefreshKey {
        RefreshKey(claudeLimits: claudeLimitsEnabled, generation: refreshGeneration)
    }

    /// Whether a failed refresh is retried without another pull.
    var isRetryingRefresh: Bool { refreshFailure != nil && pollingInterval != nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let preferenceKey: String
    @ObservationIgnored private let read: @MainActor (String, Bool) async throws -> State
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var pendingPause: Task<Void, any Error>?
    @ObservationIgnored private var readWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    convenience init(hostID: Host.ID, transports: any NotificationTransportProvider,
        defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.init(hostID: hostID, defaults: defaults, sleep: sleep) { timeZone, claudeLimits in
            try await transports.withNotificationTransport(for: hostID) { transport in
                try await Self.read(over: transport, timeZone: timeZone, claudeLimits: claudeLimits)
            }
        }
    }

    /// Console uses a weak capture here so its retained stores cannot keep it alive.
    init(hostID: Host.ID, defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        read: @escaping @MainActor (String, Bool) async throws -> State) {
        self.read = read
        self.sleep = sleep
        self.defaults = defaults
        preferenceKey = Self.claudeLimitsPreferenceKey(for: hostID)
        claudeLimitsEnabled = defaults.bool(forKey: preferenceKey)
    }

    /// The device-local Claude Code limits consent for one Host.
    nonisolated static func claudeLimitsPreferenceKey(for hostID: Host.ID) -> String {
        "usage.claude-limits.\(hostID.uuidString)"
    }

    /// Reads, then keeps reading while the plugin's worker is refreshing or
    /// a failed refresh of a shown report is retried. A newer refresh
    /// supersedes this one; cancelling the caller stops it.
    func refresh(timeZone: String = TimeZone.current.identifier) async {
        let claudeLimits = claudeLimitsEnabled
        guard !Task.isCancelled else { return }
        let id = beginRefresh()
        defer { finishRefresh(id) }
        // A restarted loop keeps the polling cadence instead of reading
        // again right after the read that restarted it.
        if refreshFailure == nil, let interval = pollingInterval, let lastRead {
            let remaining = interval - lastRead.duration(to: .now)
            if remaining > .zero { await pause(for: remaining) }
        }
        while request == id && !Task.isCancelled {
            guard await readOnce(id: id, timeZone: timeZone, claudeLimits: claudeLimits),
                let interval = pollingInterval
            else { return }
            await pause(for: interval)
        }
    }

    /// Pull to refresh ends after one read; the inline Refreshing state
    /// covers the rest of the worker's run. A running refresh reads at once
    /// and keeps polling. Otherwise this pull reads, and a refreshing answer
    /// restarts the visible surfaces' polling.
    func pullToRefresh(timeZone: String = TimeZone.current.identifier) async {
        if request != nil {
            pendingPause?.cancel()
            await waitForNextRead()
            return
        }
        let claudeLimits = claudeLimitsEnabled
        guard !Task.isCancelled else { return }
        let id = beginRefresh()
        defer { finishRefresh(id) }
        guard await readOnce(id: id, timeZone: timeZone, claudeLimits: claudeLimits) else { return }
        if pollingInterval != nil { refreshGeneration += 1 }
    }

    /// The Host's connection is usable again: retry a failed refresh now
    /// instead of at the end of its backoff.
    func connectionBecameUsable() {
        let failed: Bool
        if case .failed = snapshotState { failed = true } else { failed = refreshFailure != nil }
        guard failed else { return }
        lastRead = nil
        if request != nil {
            pendingPause?.cancel()
        } else {
            refreshGeneration += 1
        }
    }

    func invalidate() {
        endRefresh()
        snapshotState = .idle
        snapshotIncludesClaudeLimits = false
        refreshFailure = nil
        consecutiveFailures = 0
    }

    nonisolated static func read(
        over transport: any Transport, timeZone: String, claudeLimits: Bool
    ) async throws -> State {
        // The read's only plugin listing: the query runs the installation
        // it resolved.
        guard let plugin = try await transport.readHeelerPlugin() else {
            return .requirement("Usage needs the Heeler plugin 0.7.0 or newer on this Host.")
        }
        guard let version = plugin.parsedVersion else {
            return .requirement("Could not verify the plugin version. Usage needs plugin 0.7.0 or newer.")
        }
        guard HeelerPluginFeature.usage.isSupported(by: version) else {
            return .requirement(HeelerPluginFeature.usage.requirementNote(installed: version))
        }
        guard plugin.isEnabled else {
            return .requirement("Enable the Heeler plugin on this Host to read Usage.")
        }
        guard let pluginRoot = plugin.pluginRoot else {
            return .requirement(
                "herdr did not report where the Heeler plugin is installed. Update herdr on this Host to read Usage.")
        }
        let report = try await transport.readAgentUsage(
            timeZone: timeZone, claudeLimits: claudeLimits, pluginRoot: pluginRoot)
        return report.runtime == "missing" ? .runtimeMissing : .available(report)
    }

    /// Link failures ask the user to check the connection. A Host that
    /// answered, but not with a readable report, would answer the same way
    /// over any connection, so its copy does not blame the link.
    nonisolated static func state(for error: any Error) -> State {
        switch error {
        case AgentUsageError.unsupportedVersion: .updateRequired
        case TransportError.hostFeatureUnavailable: .unsupportedPlatform
        case TransportError.hostFileTimedOut: .failed(timeoutMessage)
        case AgentUsageError.invalidReport, is DecodingError,
            TransportError.malformedResponse, TransportError.apiRejected:
            .failed(pluginFailureMessage)
        default: .failed(connectionFailureMessage)
        }
    }

    nonisolated static let connectionFailureMessage =
        "Could not read Usage. Check the Host connection and try again."
    nonisolated static let pluginFailureMessage =
        "The Heeler plugin on this Host could not report Usage. Try again, or update the plugin."
    nonisolated static let timeoutMessage =
        "The Host took too long to report Usage. Try again in a moment."

    /// Polling continues while the shown report is refreshing; a failed
    /// refresh backs off. nil stops polling.
    private var pollingInterval: Duration? {
        guard case .available(let report) = snapshotState, report.refreshing == true else { return nil }
        guard refreshFailure != nil else { return Self.pollInterval }
        let doublings = min(max(consecutiveFailures - 1, 0), 4)
        return min(Self.pollInterval * (1 << doublings), Self.maximumRetryInterval)
    }

    private func beginRefresh() -> UUID {
        let id = UUID()
        request = id
        isLoading = true
        if snapshotState == .idle { snapshotState = .loading }
        return id
    }

    private func finishRefresh(_ id: UUID) {
        guard request == id else { return }
        request = nil
        isLoading = false
        resumeReadWaiters()
    }

    private func endRefresh() {
        request = nil
        isLoading = false
        lastRead = nil
        pendingPause?.cancel()
        resumeReadWaiters()
    }

    /// One read, applied unless a newer request or the caller's cancellation
    /// superseded it. false stops the caller's loop.
    private func readOnce(id: UUID, timeZone: String, claudeLimits: Bool) async -> Bool {
        let next: State
        do {
            next = try await read(timeZone, claudeLimits)
        } catch {
            next = Self.state(for: error)
        }
        guard request == id else { return false }
        guard !Task.isCancelled else {
            if snapshotState == .loading { snapshotState = .idle }
            return false
        }
        lastRead = .now
        if case .failed(let message) = next, case .available = snapshotState {
            // A transient failure must not discard the report on screen.
            refreshFailure = message
            consecutiveFailures += 1
        } else {
            snapshotState = next
            snapshotIncludesClaudeLimits = claudeLimits
            refreshFailure = nil
            consecutiveFailures = 0
        }
        resumeReadWaiters()
        return true
    }

    /// Sleeps for `delay` unless a pull, a reconnect, or cancellation ends
    /// the pause first.
    private func pause(for delay: Duration) async {
        let sleep = self.sleep
        let pause = Task { try await sleep(delay) }
        pendingPause = pause
        await withTaskCancellationHandler {
            _ = await pause.result
        } onCancel: {
            pause.cancel()
        }
        if pendingPause == pause { pendingPause = nil }
    }

    private func waitForNextRead() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    readWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.readWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    private func resumeReadWaiters() {
        let waiters = readWaiters.values
        readWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
