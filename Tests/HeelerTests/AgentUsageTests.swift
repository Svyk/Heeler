import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent usage store")
struct AgentUsageStoreTests {
    @Test func anOldPluginShowsItsRequirementWithoutAUsageRead() async {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(version: "0.6.2")))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]))
        await store.refresh()
        #expect(store.state == .requirement(
            "Usage needs plugin 0.7.0 or newer; this Host has 0.6.2."))
        #expect(await transport.agentUsageReads == 0)
    }
    @Test func windowsIsExplainedWithoutStartingAQuery() async {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.failure(TransportError.hostFeatureUnavailable(feature: "Usage")))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]))
        await store.refresh()
        #expect(store.state == .unsupportedPlatform)
        #expect(await transport.agentUsageReads == 0)
    }

    @Test func aMissingRuntimeAsksForAgentActivity() async throws {
        let (store, transport) = await readyStore()
        await transport.setAgentUsage(.success(try AgentUsageReport.decode(
            Data(#"{"version":1,"runtime":"missing"}"#.utf8))))
        await store.refresh()
        #expect(store.state == .runtimeMissing)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func theSharedNodeVectorShowsNoDataForBothPrograms() async throws {
        let report = try AgentUsageFixture.report()
        let (store, transport) = await readyStore()
        await transport.setAgentUsage(.success(report))
        await store.refresh(timeZone: "Asia/Shanghai")
        #expect(store.state == .available(report))
        #expect(report.programs?.map(\.program) == ["claude", "codex"])
        #expect(report.programs?.map { $0.tokenUsage.state } == ["noData", "noData"])
        #expect(report.scan?.state == "complete")
        #expect(report.refreshing == false)
    }

    @Test func unknownFieldsAreIgnoredButAnUnknownMajorRequiresAnUpdate() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        object["futureField"] = ["anything": true]
        #expect(try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
            == AgentUsageFixture.report())
        object["version"] = 2
        object["programs"] = "a different future shape"
        #expect(throws: AgentUsageError.unsupportedVersion) {
            try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
        }
        let (store, transport) = await readyStore()
        await transport.setAgentUsage(.failure(AgentUsageError.unsupportedVersion))
        await store.refresh()
        #expect(store.state == .updateRequired)
    }

    @Test func aDisabledPluginDoesNotRunUsage() async {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(version: "0.7.0", isEnabled: false)))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]))
        await store.refresh()
        #expect(store.state == .requirement("Enable the Heeler plugin on this Host to read Usage."))
        #expect(await transport.agentUsageReads == 0)
    }

    @Test func anInvalidatedPendingReadCannotRestoreOldHostData() async {
        let (store, transport) = await readyStore()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextHeelerPluginRead(gate)
        let refresh = Task { await store.refresh() }
        await gate.waitForEntry()
        store.invalidate()
        await gate.open()
        await refresh.value
        #expect(store.state == .idle)
        #expect(!store.isLoading)
    }

    private func readyStore() async -> (AgentUsageStore, ScriptedTransport) {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        return (AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport])), transport)
    }

}


enum AgentUsageFixture {
    private final class BundleLocator {}

    static func data() throws -> Data {
        let url = try #require(Bundle(for: BundleLocator.self)
            .url(forResource: "usage-v1", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    static func report() throws -> AgentUsageReport {
        try AgentUsageReport.decode(data())
    }
}
