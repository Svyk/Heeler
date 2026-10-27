import Foundation
import Observation

/// The Console Agent-list presentations. Flat remains the default so
/// introducing grouped-list support does not change the existing surface
/// until the UI explicitly selects it.
enum ConsoleListPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case flat
    case grouped
    case byWorkspace

    var id: Self { self }

    /// Toolbar / picker label for the presentation switcher.
    var title: String {
        switch self {
        case .flat: "All Agents"
        case .grouped: "By Host"
        case .byWorkspace: "By Workspace"
        }
    }

    /// Beside the title in the picker, and alone on the toolbar button so
    /// it shows the current choice.
    var systemImage: String {
        switch self {
        case .flat: "list.bullet"
        case .grouped: "list.bullet.indent"
        case .byWorkspace: "rectangle.3.group"
        }
    }
}

/// Workspace identity includes the Host: pane and Workspace ids are local
/// to one herdr session, and labels can be shared or renamed.
struct ConsoleWorkspaceSection: Identifiable, Equatable {
    struct ID: Hashable, Codable {
        let hostID: Host.ID
        let workspaceID: String
    }

    let id: ID
    let title: String
    let hostName: String
    let agents: [ConsoleAgent]
    let isCollapsed: Bool
    /// The main-checkout section this linked-worktree section nests under;
    /// nil for a top-level section.
    var parentID: ID?
    /// Agents of the sections nested under this one, so a collapsed parent
    /// still shows who needs the user.
    var descendantAgents: [ConsoleAgent] = []
    /// True while the parent is collapsed: the section is not drawn.
    var isHidden = false

    var isNested: Bool { parentID != nil }
    /// A collapsed parent counts its nested sections' Agents too.
    var headerAgentCount: Int { isCollapsed ? agents.count + descendantAgents.count : agents.count }
    var statusCounts: ConsoleHostAgentStatusCounts { .init(agents: isCollapsed ? agents + descendantAgents : agents) }
    var visibleAgentIDs: [ConsoleAgent.ID] { isCollapsed || isHidden ? [] : agents.map(\.id) }
    var accessibilityValue: String {
        let count = headerAgentCount == 1 ? "1 Agent" : "\(headerAgentCount) Agents"
        return [count, isCollapsed ? "Collapsed" : "Expanded",
                ConsoleHostSectionHeaderPresentation.statusText(items: statusCounts.items)]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// One Host section projected from the Host catalog and the Console's
/// already-sorted Agent sequence. The section carries the inputs a header
/// needs to present connection and Agent Inventory readiness honestly.
struct ConsoleHostSection: Identifiable, Equatable {
    let hostID: Host.ID
    let hostDisplayName: String
    let connectionStatus: EventsSessionStatus?
    let isAwaitingSnapshot: Bool
    let statusPresentation: ConsoleHostStatusPresentation?
    let agents: [ConsoleAgent]
    let isCollapsed: Bool
    let statusCounts: ConsoleHostAgentStatusCounts

    var id: Host.ID { hostID }
}

/// The Live Activity-eligible Agent statuses shown in a collapsed Host
/// section. Keeping the same order and labels as the Live Activity makes the
/// two summaries directly comparable.
struct ConsoleHostAgentStatusCounts: Equatable {
    let blocked: Int
    let working: Int
    let done: Int

    init(blocked: Int = 0, working: Int = 0, done: Int = 0) {
        self.blocked = blocked
        self.working = working
        self.done = done
    }

    init(agents: [ConsoleAgent]) {
        blocked = agents.count { $0.agent.status == .blocked }
        working = agents.count { $0.agent.status == .working }
        done = agents.count { $0.agent.status == .done }
    }

    var items: [ConsoleHostAgentStatusCount] {
        var items: [ConsoleHostAgentStatusCount] = []
        if blocked > 0 { items.append(.init(status: .blocked, count: blocked)) }
        if working > 0 { items.append(.init(status: .working, count: working)) }
        if done > 0 { items.append(.init(status: .done, count: done)) }
        return items
    }
}

struct ConsoleHostAgentStatusCount: Identifiable, Equatable {
    let status: AgentStatus
    let count: Int

    var id: String { status.rawValue }
}

/// Persists the Console presentation choice and Host/Workspace collapse state,
/// and projects grouped sections without taking ownership of Agent sorting.
/// Collapsed Host ids are deliberately retained when a Host disconnects or
/// leaves the catalog so a reconnect or later return restores the choice.
@MainActor
@Observable
final class ConsoleListPresentationStore {
    /// Hosts follow catalog order; Workspaces follow their first Agent in
    /// the supplied priority order. Grouping never re-sorts Agents or pins.
    func workspaceSections(
        hosts: [Host], agents: [ConsoleAgent],
        filteredHostID: Host.ID? = nil, searchQuery: String = ""
    ) -> [ConsoleWorkspaceSection] {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return sections(
            hosts: hosts, agents: agents, filteredHostID: filteredHostID, searchQuery: searchQuery
        ).flatMap { host in
            let buckets = Dictionary(grouping: host.agents, by: \.agent.workspaceID)
            var order: [String] = []
            for agent in host.agents where !order.contains(agent.agent.workspaceID) {
                order.append(agent.agent.workspaceID)
            }

            // Nesting is decided on every Agent of the Host, so a search
            // that matches only a worktree still finds its main checkout.
            // Workspaces exist here only through their Agents: an agentless
            // main checkout is not projected and cannot be a parent.
            let everyAgent = agents.filter { $0.hostID == host.id }
            let allBuckets = Dictionary(grouping: everyAgent, by: \.agent.workspaceID)
            var allOrder: [String] = []
            for agent in everyAgent where !allOrder.contains(agent.agent.workspaceID) {
                allOrder.append(agent.agent.workspaceID)
            }
            func checkout(_ workspaceID: String) -> RepositoryCheckout? {
                allBuckets[workspaceID]?.compactMap(\.repositoryCheckout).first
            }
            func mainCheckouts(_ repoKey: String, in ids: [String]) -> [String] {
                ids.filter {
                    let info = checkout($0)
                    return info?.repoKey == repoKey && info?.isLinkedWorktree == false
                }
            }
            var parentOf: [String: String] = [:]
            for workspaceID in order {
                guard let info = checkout(workspaceID), info.isLinkedWorktree else { continue }
                let parent =
                    mainCheckouts(info.repoKey, in: order).first
                    ?? mainCheckouts(info.repoKey, in: allOrder).first
                if let parent { parentOf[workspaceID] = parent }
            }
            var childrenOf: [String: [String]] = [:]
            for workspaceID in order {
                if let parent = parentOf[workspaceID] { childrenOf[parent, default: []].append(workspaceID) }
            }

            func members(_ workspaceID: String) -> [ConsoleAgent] { buckets[workspaceID] ?? [] }
            func section(_ workspaceID: String) -> ConsoleWorkspaceSection {
                let label = (allBuckets[workspaceID] ?? []).compactMap(\.workspaceLabel).first {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                let id = ConsoleWorkspaceSection.ID(hostID: host.id, workspaceID: workspaceID)
                let parentID = parentOf[workspaceID].map {
                    ConsoleWorkspaceSection.ID(hostID: host.id, workspaceID: $0)
                }
                var section = ConsoleWorkspaceSection(
                    id: id, title: label ?? (workspaceID.isEmpty ? "Unknown Workspace" : workspaceID),
                    hostName: host.hostDisplayName, agents: members(workspaceID),
                    isCollapsed: !isSearching && collapsedWorkspaceIDs.contains(id),
                    parentID: parentID)
                section.descendantAgents = (childrenOf[workspaceID] ?? []).flatMap(members)
                section.isHidden =
                    !isSearching && parentID.map(collapsedWorkspaceIDs.contains) == true
                return section
            }

            var emitted: Set<String> = []
            var result: [ConsoleWorkspaceSection] = []
            func emit(_ workspaceID: String) {
                guard emitted.insert(workspaceID).inserted else { return }
                result.append(section(workspaceID))
            }
            for workspaceID in order {
                let top = parentOf[workspaceID] ?? workspaceID
                emit(top)
                for child in childrenOf[top] ?? [] { emit(child) }
            }
            return result
        }
    }

    func toggleWorkspace(_ id: ConsoleWorkspaceSection.ID) {
        if !collapsedWorkspaceIDs.insert(id).inserted {
            collapsedWorkspaceIDs.remove(id)
        }
        let sorted = collapsedWorkspaceIDs.sorted {
            ($0.hostID.uuidString, $0.workspaceID) < ($1.hostID.uuidString, $1.workspaceID)
        }
        defaults.set(try? JSONEncoder().encode(sorted), forKey: Self.collapsedWorkspacesDefaultsKey)
    }

    private static let modeDefaultsKey = "console-list.presentation-mode"
    private static let collapsedHostsDefaultsKey = "console-list.collapsed-hosts"
    private static let collapsedWorkspacesDefaultsKey = "console-list.collapsed-workspaces"

    private(set) var mode: ConsoleListPresentationMode
    private var collapsedHostIDs: Set<Host.ID>
    private var collapsedWorkspaceIDs: Set<ConsoleWorkspaceSection.ID>
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode =
            defaults.string(forKey: Self.modeDefaultsKey)
            .flatMap(ConsoleListPresentationMode.init(rawValue:)) ?? .flat
        collapsedHostIDs = Set(
            (defaults.stringArray(forKey: Self.collapsedHostsDefaultsKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
        collapsedWorkspaceIDs = Set(
            defaults.data(forKey: Self.collapsedWorkspacesDefaultsKey)
                .flatMap { try? JSONDecoder().decode([ConsoleWorkspaceSection.ID].self, from: $0) } ?? [])
    }

    func select(_ mode: ConsoleListPresentationMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
    }

    func isCollapsed(_ hostID: Host.ID) -> Bool {
        collapsedHostIDs.contains(hostID)
    }

    func setCollapsed(_ collapsed: Bool, for hostID: Host.ID) {
        let changed: Bool
        if collapsed {
            changed = collapsedHostIDs.insert(hostID).inserted
        } else {
            changed = collapsedHostIDs.remove(hostID) != nil
        }
        guard changed else { return }
        persistCollapsedHostIDs()
    }

    func toggleCollapsed(_ hostID: Host.ID) {
        setCollapsed(!isCollapsed(hostID), for: hostID)
    }

    /// Convenience contract for the Console UI. Reading these observable
    /// inputs on each render makes status, inventory, and membership changes
    /// re-project without a second cache to reconcile.
    func sections(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostID: Host.ID? = nil,
        searchQuery: String = ""
    ) -> [ConsoleHostSection] {
        sections(
            hosts: hosts,
            agents: console.chatDisplayAgents,
            hostStatuses: console.hostStatuses,
            hostStandingFailures: console.hostStandingFailures,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostSyncErrors: console.hostSyncErrors,
            filteredHostID: filteredHostID,
            searchQuery: searchQuery)
    }

    /// Reads the same inventory as `sections(hosts:console:)`, so saved Chat
    /// entry points of an unproven Host appear By Workspace too.
    func workspaceSections(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostID: Host.ID? = nil,
        searchQuery: String = ""
    ) -> [ConsoleWorkspaceSection] {
        workspaceSections(
            hosts: hosts, agents: console.chatDisplayAgents,
            filteredHostID: filteredHostID, searchQuery: searchQuery)
    }

    /// Projects one section per catalog Host, in catalog order. `agents` is
    /// already sorted by ConsoleStore; filtering it in-place keeps
    /// that exact relative order within every Host section.
    func sections(
        hosts: [Host],
        agents: [ConsoleAgent],
        hostStatuses: [Host.ID: EventsSessionStatus] = [:],
        hostStandingFailures: [Host.ID: TransportError] = [:],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostSyncErrors: [Host.ID: String] = [:],
        filteredHostID: Host.ID? = nil,
        searchQuery: String = ""
    ) -> [ConsoleHostSection] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchedAgents = trimmedQuery.isEmpty ? agents : agents.filter { $0.matchesAgentSearch(trimmedQuery) }
        let agentsByHost = Dictionary(grouping: searchedAgents, by: \.hostID)
        var projectedHostIDs: Set<Host.ID> = []

        return hosts.compactMap { host in
            guard filteredHostID == nil || host.id == filteredHostID else { return nil }
            guard projectedHostIDs.insert(host.id).inserted else { return nil }

            let hostAgents = agentsByHost[host.id] ?? []
            let isAwaitingSnapshot = hostsAwaitingSnapshot.contains(host.id)
            let statusPresentation = ConsoleHostStatusPresentation(
                host: host,
                status: hostStatuses[host.id],
                standingFailure: hostStandingFailures[host.id],
                isAwaitingSnapshot: isAwaitingSnapshot,
                syncError: hostSyncErrors[host.id])
            // While searching, a section without a match leaves the list
            // whatever its Host's state (#292, #316): a query asks for Agents,
            // and Hosts that cannot answer only bury the matches. Without a
            // query every catalog Host stays visible, including empty ones.
            if !trimmedQuery.isEmpty && hostAgents.isEmpty { return nil }
            return ConsoleHostSection(
                hostID: host.id,
                hostDisplayName: host.displayName,
                connectionStatus: hostStatuses[host.id],
                isAwaitingSnapshot: isAwaitingSnapshot,
                statusPresentation: statusPresentation,
                agents: hostAgents,
                // A match is never hidden behind a collapsed Host.
                isCollapsed: trimmedQuery.isEmpty && isCollapsed(host.id),
                statusCounts: ConsoleHostAgentStatusCounts(agents: hostAgents))
        }
    }

    private func persistCollapsedHostIDs() {
        defaults.set(
            collapsedHostIDs.map(\.uuidString).sorted(),
            forKey: Self.collapsedHostsDefaultsKey)
    }
}
