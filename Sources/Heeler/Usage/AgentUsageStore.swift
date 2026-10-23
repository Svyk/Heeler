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

    private(set) var state: State = .idle
    private(set) var isLoading = false
    @ObservationIgnored private let read: @MainActor (String, Bool) async throws -> State
    @ObservationIgnored private var request: UUID?

    init(hostID: Host.ID, transports: any NotificationTransportProvider) {
        read = { timeZone, claudeLimits in
            try await transports.withNotificationTransport(for: hostID) { transport in
                try await Self.read(over: transport, timeZone: timeZone, claudeLimits: claudeLimits)
            }
        }
    }

    /// Console uses a weak capture here so its retained stores cannot keep it alive.
    init(read: @escaping @MainActor (String, Bool) async throws -> State) {
        self.read = read
    }

    func refresh(timeZone: String = TimeZone.current.identifier, claudeLimits: Bool = false) async {
        let id = UUID()
        request = id
        isLoading = true
        if state == .idle { state = .loading }
        let next: State
        do {
            next = try await read(timeZone, claudeLimits)
        } catch AgentUsageError.unsupportedVersion {
            next = .updateRequired
        } catch TransportError.hostFeatureUnavailable {
            next = .unsupportedPlatform
        } catch {
            next = .failed("Could not read Usage. Check the Host connection and try again.")
        }
        guard request == id else { return }
        isLoading = false
        request = nil
        guard !Task.isCancelled else {
            if state == .loading { state = .idle }
            return
        }
        state = next
    }

    func invalidate() {
        request = nil
        isLoading = false
        state = .idle
    }

    nonisolated static func read(
        over transport: any Transport, timeZone: String, claudeLimits: Bool
    ) async throws -> State {
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
        let report = try await transport.readAgentUsage(timeZone: timeZone, claudeLimits: claudeLimits)
        return report.runtime == "missing" ? .runtimeMissing : .available(report)
    }
}
