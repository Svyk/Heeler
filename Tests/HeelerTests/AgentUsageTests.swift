import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent usage store", .timeLimit(.minutes(1)))
struct AgentUsageStoreTests {
    @Test func theSharedVectorCarriesVersionedEstimatedAPICost() throws {
        let object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        #expect(object["pricingVersion"] is String)
        let programs = try #require(object["programs"] as? [[String: Any]])
        for program in programs {
            let usage = try #require(program["tokenUsage"] as? [String: Any])
            let totals = try #require(usage["totals"] as? [String: Any])
            let today = try #require(totals["today"] as? [String: Any])
            #expect(today["estimatedCostUSD"] != nil)
            #expect(today["unpricedTokens"] is Int)
        }
        let report = try AgentUsageFixture.report()
        #expect(report.pricingVersion == "2026-10-23")
        for program in report.programs ?? [] {
            #expect(program.tokenUsage.totals?.today.estimatedCostUSD != nil)
            #expect(program.tokenUsage.totals?.today.unpricedTokens == 0)
            #expect(program.tokenUsage.daily?.last?.estimatedCostUSD != nil)
        }
        let claudeCost = try #require(report.programs?.first { $0.program == "claude" }?
            .tokenUsage.totals?.today.estimatedCostUSD)
        let codexCost = try #require(report.programs?.first { $0.program == "codex" }?
            .tokenUsage.totals?.today.estimatedCostUSD)
        #expect(abs(claudeCost - 0.92225) < 0.000000001)
        #expect(abs(codexCost - 0.000742) < 0.000000001)
    }

    @Test func nullEstimatedCostDoesNotBecomeZeroAndUnpricedTokensRemainVisible() throws {
        let report = try AgentUsageFixture.costReport(cost: nil, unpriced: 882_000)
        let today = try #require(report.programs?.first?.tokenUsage.totals?.today)
        #expect(today.estimatedCostUSD == nil)
        #expect(today.unpricedTokens == 882_000)
        let mixed = try AgentUsageFixture.costReport(cost: 1.92, unpriced: 250)
        #expect(mixed.programs?.first?.tokenUsage.totals?.last30Days.estimatedCostUSD == 1.92)
        #expect(mixed.programs?.first?.tokenUsage.totals?.last30Days.unpricedTokens == 250)
        #expect(mixed.programs?.first?.tokenUsage.daily?.last?.estimatedCostUSD == 1.92)
    }

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

    @Test func aHostWithoutRecordedTokenUsageReportsNoDataForEachProgram() async throws {
        let (store, transport) = await readyStore()
        let report = try AgentUsageFixture.noDataReport()
        await transport.setAgentUsage(.success(report))
        await store.refresh()
        #expect(store.state == .available(report.hidingClaudeLimits()))
        #expect(report.programs?.map(\.program) == ["claude", "codex"])
        #expect(report.programs?.allSatisfy { $0.tokenUsage.state == "noData" && $0.tokenUsage.totals == nil } == true)
        #expect(!store.isLoading)
    }

    @Test func aMissingRuntimeAsksForAgentActivity() async throws {
        let (store, transport) = await readyStore()
        await transport.setAgentUsage(.success(try AgentUsageReport.decode(
            Data(#"{"version":1,"runtime":"missing"}"#.utf8))))
        await store.refresh()
        #expect(store.state == .runtimeMissing)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func theSharedNodeVectorIncludesBothProgramsTokenUsage() async throws {
        let report = try AgentUsageFixture.report()
        let (store, transport) = await readyStore()
        await transport.setAgentUsage(.success(report))
        await store.refresh(timeZone: "Asia/Shanghai")
        #expect(store.state == .available(report))
        #expect(report.programs?.map(\.program) == ["claude", "codex"])
        #expect(report.programs?.map { $0.tokenUsage.state } == ["ok", "ok"])
        #expect(report.programs?.first?.tokenUsage.totals?.today.tokens.total == 882_000)
        #expect(report.programs?.first?.tokenUsage.daily?.count == 30)
        let codex = try #require(report.programs?.first { $0.program == "codex" }?.tokenUsage)
        let today = try #require(codex.totals?.today.tokens)
        #expect(today.input == 120)
        #expect(today.cacheRead == 40)
        #expect(today.cacheWrite == 60)
        #expect(today.output == 30)
        #expect(today.reasoning == 10)
        #expect(today.total == 250)
        #expect(codex.totals?.last7Days.tokens.total == 250)
        #expect(codex.totals?.last30Days.tokens.total == 250)
        #expect(codex.daily?.count == 30)
        #expect(codex.daily?.last?.tokens.total == 250)
        #expect(report.scan?.skippedArchives == 0)
        #expect(report.scan?.state == "complete")
        #expect(report.refreshing == false)
    }

    @Test func unknownFieldsAreIgnoredButAnUnknownMajorRequiresAnUpdate() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        object["futureField"] = ["anything": true]
        #expect(try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
            == AgentUsageReport.decode(AgentUsageFixture.data()))
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

    @Test(arguments: ["Asia/Kolkata", "US/Pacific"])
    func theDeviceTimeZoneReachesTheTransportUnchanged(timeZone: String) async throws {
        let (store, transport) = await readyStore()
        let report = try AgentUsageFixture.report()
        await transport.setAgentUsage(.success(report))
        await store.refresh(timeZone: timeZone)
        #expect(store.state == .available(report))
        #expect(await transport.agentUsageTimeZones == [timeZone])
    }

    @Test func oneReadListsPluginsOnceAndRunsTheInstallationItResolved() async throws {
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/opt/heeler plugin", version: "0.7.0")))
        let report = try AgentUsageFixture.report()
        await transport.setAgentUsage(.success(report))
        let state = try await AgentUsageStore.read(over: transport, timeZone: "US/Pacific", claudeLimits: true)
        #expect(state == .available(report))
        #expect(await transport.heelerPluginReads == 1)
        #expect(await transport.agentUsageReads == 1)
        #expect(await transport.agentUsageTimeZones == ["US/Pacific"])
        #expect(await transport.agentUsageClaudeLimits == [true])
        #expect(await transport.agentUsagePluginRoots == ["/opt/heeler plugin"])
    }

    @Test func theProductionReadGatesThePluginBeforeAnyQuery() async throws {
        let cases: [(HeelerPluginInstallation?, AgentUsageStore.State)] = [
            (nil, .requirement("Usage needs the Heeler plugin 0.7.0 or newer on this Host.")),
            (.init(pluginRoot: "/plugins/heeler", version: "0.6.2"),
             .requirement("Usage needs plugin 0.7.0 or newer; this Host has 0.6.2.")),
            (.init(pluginRoot: "/plugins/heeler", version: "seven"),
             .requirement("Could not verify the plugin version. Usage needs plugin 0.7.0 or newer.")),
            (.init(pluginRoot: "/plugins/heeler", version: "0.7.0", isEnabled: false),
             .requirement("Enable the Heeler plugin on this Host to read Usage.")),
            (.init(version: "0.7.0"),
             .requirement("herdr did not report where the Heeler plugin is installed. Update herdr on this Host to read Usage.")),
        ]
        for (plugin, expected) in cases {
            let transport = ScriptedTransport()
            await transport.setHeelerPlugin(.success(plugin))
            await transport.setAgentUsage(.success(try AgentUsageFixture.report()))
            let state = try await AgentUsageStore.read(over: transport, timeZone: "UTC", claudeLimits: false)
            #expect(state == expected)
            #expect(await transport.heelerPluginReads == 1)
            #expect(await transport.agentUsageReads == 0)
        }
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

    @Test func tokenTotalsAndDailyBucketsDecodeWithoutCountingReasoningTwice() throws {
        let report = try AgentUsageFixture.tokenReport(refreshing: false)
        let usage = try #require(report.programs?.first?.tokenUsage)
        #expect(usage.totals?.today.tokens.input == 1_200)
        #expect(usage.totals?.today.tokens.cacheRead == 830_000)
        #expect(usage.totals?.today.tokens.cacheWrite == 41_000)
        #expect(usage.totals?.today.tokens.output == 9_800)
        #expect(usage.totals?.today.tokens.total == 882_000)
        #expect(usage.totals?.last30Days.tokens.total == 1_764_000)
        #expect(usage.daily?.first?.date == "2026-10-23")
        #expect(usage.daily?.first?.tokens.total == 882_000)
    }

    @Test func refreshingReportsAreQueriedAgainAfterThreeSecondsAndThenStop() async throws {
        let (store, transport) = await readyStore()
        let partial = try AgentUsageFixture.report(refreshing: true)
        let complete = try AgentUsageFixture.report(refreshing: false)
        await transport.setAgentUsage(.success(partial))
        let started = ContinuousClock.now
        let refresh = Task { await store.refresh(timeZone: "Asia/Kathmandu") }
        while await transport.agentUsageReads == 0 { await Task.yield() }
        await transport.setAgentUsage(.success(complete))
        await refresh.value
        #expect(started.duration(to: .now) >= .seconds(3))
        #expect(await transport.agentUsageReads == 2)
        #expect(store.state == .available(complete))
        #expect(!store.isLoading)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.agentUsageReads == 2)
    }

    @Test func cancellingAVisibleRefreshStopsPollingWithoutDiscardingItsLastSnapshot() async throws {
        let (store, transport) = await readyStore()
        let partial = try AgentUsageFixture.tokenReport(refreshing: true)
        await transport.setAgentUsage(.success(partial))
        let refresh = Task { await store.refresh() }
        while store.state != .available(partial) { await Task.yield() }
        refresh.cancel()
        await refresh.value
        #expect(store.state == .available(partial))
        #expect(!store.isLoading)
        try await Task.sleep(for: .milliseconds(3_100))
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func invalidatingAHostDuringThePollingDelayPreventsAnotherRead() async throws {
        let (store, transport) = await readyStore()
        let partial = try AgentUsageFixture.tokenReport(refreshing: true)
        await transport.setAgentUsage(.success(partial))
        let refresh = Task { await store.refresh() }
        while store.state != .available(partial) { await Task.yield() }
        store.invalidate()
        await refresh.value
        #expect(store.state == .idle)
        #expect(!store.isLoading)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func aFailedRefreshKeepsTheShownReportAndRetriesWithABoundedBackoff() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        let complete = try AgentUsageFixture.report(refreshing: false)
        let link = TransportError.sshUnreachable(detail: "The Host is not connected.")
        var results: [Result<AgentUsageStore.State, any Error>] =
            [.success(.available(partial))] + Array(repeating: .failure(link), count: 7)
            + [.success(.available(complete))]
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            try results.removeFirst().get()
        }
        let refresh = Task { await store.refresh() }
        for pauses in 1...8 {
            while await sleeper.durations.count < pauses { await Task.yield() }
            #expect(store.state == .available(partial))
            #expect(store.isLoading)
            if pauses > 1 {
                #expect(store.refreshFailure == "Could not read Usage. Check the Host connection and try again.")
                #expect(store.isRetryingRefresh)
            }
            await sleeper.fireAll()
        }
        await refresh.value
        #expect(await sleeper.durations == [3, 3, 6, 12, 24, 30, 30, 30].map { Duration.seconds($0) })
        #expect(results.isEmpty)
        #expect(store.state == .available(complete))
        #expect(store.refreshFailure == nil)
        #expect(!store.isLoading)
    }

    @Test func failuresTheHostRepeatsDoNotBlameTheConnection() throws {
        let decoding = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentUsageReport.self, from: Data("{}".utf8))
        }
        let cases: [(any Error, AgentUsageStore.State)] = [
            (TransportError.sshUnreachable(detail: "gone"), .failed(AgentUsageStore.connectionFailureMessage)),
            (TransportError.timedOut, .failed(AgentUsageStore.connectionFailureMessage)),
            (TransportError.channelFailed(detail: "closed"), .failed(AgentUsageStore.connectionFailureMessage)),
            (TransportError.hostFileTimedOut, .failed(AgentUsageStore.timeoutMessage)),
            (TransportError.malformedResponse("The Host did not finish its Usage response."),
             .failed(AgentUsageStore.pluginFailureMessage)),
            (TransportError.apiRejected(code: "plugin_error", message: "boom"),
             .failed(AgentUsageStore.pluginFailureMessage)),
            (AgentUsageError.invalidReport, .failed(AgentUsageStore.pluginFailureMessage)),
            (decoding, .failed(AgentUsageStore.pluginFailureMessage)),
            (AgentUsageError.unsupportedVersion, .updateRequired),
            (TransportError.hostFeatureUnavailable(feature: "Usage"), .unsupportedPlatform),
        ]
        for (error, expected) in cases {
            #expect(AgentUsageStore.state(for: error) == expected, "\(error)")
        }
        for message in [AgentUsageStore.pluginFailureMessage, AgentUsageStore.timeoutMessage] {
            #expect(!message.contains("connection"))
        }
    }

    @Test func aFirstReadThatFailsStillShowsTheFailure() async {
        let store = AgentUsageStore(hostID: UUID()) { _, _ in
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        await store.refresh()
        #expect(store.state == .failed("Could not read Usage. Check the Host connection and try again."))
        #expect(store.refreshFailure == nil)
        #expect(!store.isLoading)
    }

    @Test func aFailedRefreshOfACompleteReportWaitsForThePull() async throws {
        let complete = try AgentUsageFixture.report(refreshing: false)
        var results: [Result<AgentUsageStore.State, any Error>] = [
            .success(.available(complete)), .failure(TransportError.timedOut), .success(.available(complete)),
        ]
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            try results.removeFirst().get()
        }
        await store.refresh()
        await store.pullToRefresh()
        #expect(store.state == .available(complete))
        #expect(store.refreshFailure != nil)
        #expect(!store.isRetryingRefresh)
        #expect(!store.isLoading)
        #expect(await sleeper.durations.isEmpty)
        await store.pullToRefresh()
        #expect(store.refreshFailure == nil)
        #expect(results.isEmpty)
    }

    @Test func aUsableConnectionEndsTheRetryBackoffAtOnce() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        let complete = try AgentUsageFixture.report(refreshing: false)
        var results: [Result<AgentUsageStore.State, any Error>] = [
            .success(.available(partial)), .failure(TransportError.timedOut), .failure(TransportError.timedOut),
            .success(.available(complete)),
        ]
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            try results.removeFirst().get()
        }
        let generation = store.refreshGeneration
        store.connectionBecameUsable()
        #expect(store.refreshGeneration == generation, "Nothing failed, so nothing resumes.")
        let refresh = Task { await store.refresh() }
        for pauses in 1...3 {
            while await sleeper.durations.count < pauses { await Task.yield() }
            if pauses < 3 { await sleeper.fireAll() }
        }
        #expect(store.refreshFailure != nil)
        store.connectionBecameUsable()
        await refresh.value
        #expect(store.state == .available(complete))
        #expect(await sleeper.durations.count == 3)
        #expect(results.isEmpty)
    }

    @Test func aUsableConnectionRestartsTheSurfacesAfterAFailedFirstRead() async {
        let store = AgentUsageStore(hostID: UUID()) { _, _ in throw TransportError.timedOut }
        await store.refresh()
        let key = store.refreshKey
        store.connectionBecameUsable()
        #expect(store.refreshKey != key)
    }

    @Test func pullToRefreshEndsAfterOneReadAndHandsPollingToTheSurfaces() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        var reads = 0
        let store = AgentUsageStore(hostID: UUID()) { _, _ in
            reads += 1
            return .available(partial)
        }
        let key = store.refreshKey
        await store.pullToRefresh()
        #expect(reads == 1)
        #expect(store.state == .available(partial))
        #expect(!store.isLoading)
        #expect(store.refreshKey != key, "A refreshing answer restarts the visible surfaces' polling.")
    }

    @Test func pullToRefreshDuringPollingReadsOnceAndLeavesPollingRunning() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        let complete = try AgentUsageFixture.report(refreshing: false)
        var results: [AgentUsageStore.State] = [.available(partial), .available(partial), .available(complete)]
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            results.removeFirst()
        }
        let refresh = Task { await store.refresh() }
        while await sleeper.durations.count < 1 { await Task.yield() }
        let key = store.refreshKey
        await store.pullToRefresh()
        #expect(results.count == 1)
        #expect(store.isLoading)
        #expect(store.refreshKey == key)
        while await sleeper.durations.count < 2 { await Task.yield() }
        await sleeper.fireAll()
        await refresh.value
        #expect(results.isEmpty)
        #expect(store.state == .available(complete))
    }

    @Test func anAlreadyCancelledRefreshDoesNotLeaveTheHostLoading() async {
        let (store, transport) = await readyStore()
        let refresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refresh()
        }
        await refresh.value
        #expect(store.state == .idle)
        #expect(!store.isLoading)
        #expect(await transport.agentUsageReads == 0)
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

    static func noDataReport() throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        for index in programs.indices { programs[index]["tokenUsage"] = ["state": "noData"] }
        object["programs"] = programs
        object["refreshing"] = false
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    static func costReport(cost: Double?, unpriced: Int64) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        var program = try #require((object["programs"] as? [[String: Any]])?.first)
        var usage = try #require(program["tokenUsage"] as? [String: Any])
        var totals = try #require(usage["totals"] as? [String: Any])
        for name in ["today", "last7Days", "last30Days"] {
            var summary = try #require(totals[name] as? [String: Any])
            summary["estimatedCostUSD"] = cost.map { $0 as Any } ?? NSNull()
            summary["unpricedTokens"] = unpriced
            totals[name] = summary
        }
        var daily = try #require(usage["daily"] as? [[String: Any]])
        for index in daily.indices {
            daily[index]["estimatedCostUSD"] = cost.map { $0 as Any } ?? NSNull()
            daily[index]["unpricedTokens"] = unpriced
        }
        usage["totals"] = totals
        usage["daily"] = daily
        program["tokenUsage"] = usage
        object["programs"] = [program]
        object["pricingVersion"] = "2026-10-24"
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    static func tokenReport(refreshing: Bool) throws -> AgentUsageReport {
        let json = """
        {"version":1,"runtime":"recorded","generatedAt":"2026-10-23T12:34:56Z",
         "timeZone":"Asia/Shanghai","refreshing":\(refreshing),
         "scan":{"state":"\(refreshing ? "partial" : "complete")","coveredFrom":"2026-10-23",
           "coveredThrough":"2026-10-23T12:34:00Z","skippedArchives":0},
         "programs":[{"program":"claude","usageLimits":{"state":"disabled"},
           "tokenUsage":{"state":"ok","totals":{
             "today":{"tokens":{"input":1200,"cacheRead":830000,"cacheWrite":41000,"output":9800,"reasoning":0,"total":882000}},
             "last7Days":{"tokens":{"input":1200,"cacheRead":830000,"cacheWrite":41000,"output":9800,"reasoning":0,"total":882000}},
             "last30Days":{"tokens":{"input":2400,"cacheRead":1660000,"cacheWrite":82000,"output":19600,"reasoning":0,"total":1764000}}},
             "daily":[{"date":"2026-10-23","tokens":{"input":1200,"cacheRead":830000,"cacheWrite":41000,"output":9800,"reasoning":0,"total":882000}}]}},
           {"program":"codex","tokenUsage":{"state":"noData"},"usageLimits":{"state":"unavailable","reason":"programMissing"}}]}
        """
        return try AgentUsageReport.decode(Data(json.utf8))
    }

    static func report(refreshing: Bool) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        object["refreshing"] = refreshing
        var programs = try #require(object["programs"] as? [[String: Any]])
        programs[0]["usageLimits"] = ["state": "disabled"]
        object["programs"] = programs
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    static func report() throws -> AgentUsageReport {
        try report(refreshing: false)
    }
}


@MainActor
@Suite("Claude usage preference", .timeLimit(.minutes(1)))
struct ClaudeUsagePreferenceTests {
    @Test func disablingImmediatelyHidesCachedLimitsAndRejectsAnInFlightOptedInResponse() async throws {
        let name = "claude-cancel-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let hostID = UUID()
        let transport = ScriptedTransport()
        let report = try ClaudeUsageFixture.report()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(report))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]), defaults: defaults)
        store.claudeLimitsEnabled = true
        await store.refresh()
        let gate = ScriptedTransportCallGate()
        await transport.setAgentUsage(.success(try AgentUsageFixture.costReport(cost: 9.99, unpriced: 0)))
        await transport.gateNextAgentUsageRead(gate)
        let refresh = Task { await store.refresh() }
        await gate.waitForEntry()
        store.claudeLimitsEnabled = false
        guard case .available(let hidden) = store.state else {
            await gate.open()
            await refresh.value
            Issue.record("Turning off Claude limits must retain Token Usage.")
            return
        }
        #expect(hidden.programs?.first?.usageLimits.state == "disabled")
        #expect(hidden.programs?.first?.tokenUsage == report.programs?.first?.tokenUsage)
        #expect(hidden.programs?.last == report.programs?.last)
        #expect(!store.isLoading)
        await gate.open()
        await refresh.value
        #expect(store.state == .available(hidden))
        #expect(await transport.agentUsageClaudeLimits == [true, true])
        await store.refresh()
        #expect(await transport.agentUsageClaudeLimits == [true, true, false])
        guard case .available(let afterRefresh) = store.state else { Issue.record("Missing snapshot"); return }
        #expect(afterRefresh.programs?.first?.usageLimits.state == "disabled")
    }

    @Test func thePerHostTogglePersistsOnThisDeviceAndReachesTransport() async throws {
        let name = "claude-usage-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let hostID = UUID()
        let otherID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(try ClaudeUsageFixture.report()))
        let provider = ScriptedTransportProvider(transports: [hostID: transport, otherID: transport])
        let store = AgentUsageStore(hostID: hostID, transports: provider, defaults: defaults)
        #expect(!store.claudeLimitsEnabled)
        await store.refresh()
        store.claudeLimitsEnabled = true
        await store.refresh()
        let reopened = AgentUsageStore(hostID: hostID, transports: provider, defaults: defaults)
        #expect(reopened.claudeLimitsEnabled)
        await reopened.refresh()
        let other = AgentUsageStore(hostID: otherID, transports: provider, defaults: defaults)
        #expect(!other.claudeLimitsEnabled)
        await other.refresh()
        #expect(await transport.agentUsageClaudeLimits == [false, true, true, false])
        reopened.claudeLimitsEnabled = false
        #expect(!AgentUsageStore(hostID: hostID, transports: provider, defaults: defaults).claudeLimitsEnabled)
    }
}

#if DEBUG && targetEnvironment(simulator)
    @MainActor
    @Suite("Demo Usage")
    struct DemoUsageTests {
        @Test func demoHostsShowSampleUsageInsteadOfAPlatformNote() async throws {
            let host = try #require(DemoScreenshotFixture.hosts.first)
            let transport = try DemoScreenshotFixture.transport(for: host)
            for claudeLimits in [false, true] {
                let state = try await AgentUsageStore.read(
                    over: transport, timeZone: "Asia/Kolkata", claudeLimits: claudeLimits)
                guard case .available(let report) = state else {
                    Issue.record("Demo Usage must be sample data, not \(state)")
                    return
                }
                #expect(report.programs?.map(\.program) == ["claude", "codex"])
                #expect(report.timeZone == "Asia/Kolkata")
                #expect(report.programs?.first?.usageLimits.state == (claudeLimits ? "ok" : "disabled"))
                #expect(report.programs?.last?.usageLimits.windows?.allSatisfy { !$0.expired } == true)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
                let today = calendar.dateComponents([.year, .month, .day], from: Date())
                let todayText = String(
                    format: "%04d-%02d-%02d", today.year ?? 0, today.month ?? 0, today.day ?? 0)
                for program in report.programs ?? [] {
                    let usage = program.tokenUsage
                    let daily = try #require(usage.daily)
                    #expect(usage.state == "ok")
                    #expect(daily.count == 30)
                    #expect(daily.last?.date == todayText)
                    #expect(usage.totals?.today.tokens.total == daily.last?.tokens.total)
                    #expect(usage.totals?.last7Days.tokens.total
                        == daily.suffix(7).reduce(0) { $0 + $1.tokens.total })
                    #expect(usage.totals?.last30Days.tokens.total
                        == daily.reduce(0) { $0 + $1.tokens.total })
                }
            }
        }
    }
#endif
