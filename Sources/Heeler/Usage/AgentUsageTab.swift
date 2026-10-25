import SwiftUI

/// The Usage tab on an iPhone, and in an iPad window too narrow for a
/// sidebar.
struct AgentUsageTabView: View {
    let entries: [AgentUsageHostEntry]
    @Binding var scopeHostID: Host.ID?

    var body: some View {
        NavigationStack {
            AgentUsageDashboard(entries: entries, scopeHostID: $scopeHostID)
                .navigationTitle("Usage")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AgentUsageScopeMenu(entries: entries, scopeHostID: $scopeHostID)
                    }
                }
        }
    }
}

/// All Hosts or one Host. Hosts that cannot report stay listed, disabled,
/// with the reason.
struct AgentUsageScopeMenu: View {
    let entries: [AgentUsageHostEntry]
    @Binding var scopeHostID: Host.ID?
    @Environment(\.locale) private var locale

    var body: some View {
        let scope = AgentUsageScope(readings: entries.map(\.reading))
        Menu {
            Toggle(isOn: choosing(nil)) {
                Label("All Hosts", systemImage: "square.stack.3d.up")
            }
            Section {
                ForEach(scope.included) { host in
                    Toggle(isOn: choosing(host.id)) {
                        Label(host.name, systemImage: "desktopcomputer")
                        Text("\(AgentUsageStyle.cost(host.last30Days.estimatedCostUSD, locale: locale)) est. · 30 days")
                    }
                }
                // Still loading: choosable, with nothing to show yet.
                ForEach(scope.loading) { host in
                    Toggle(isOn: choosing(host.id)) {
                        Label(host.name, systemImage: "desktopcomputer")
                        Text("Loading…")
                    }
                }
            }
            if !scope.excluded.isEmpty {
                Section {
                    ForEach(scope.excluded) { host in
                        Button {} label: {
                            Label(host.name,
                                systemImage: host.reason == "Not connected" ? "wifi.slash" : "desktopcomputer")
                            Text(host.reason)
                        }
                        .disabled(true)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        .accessibilityLabel("Usage scope")
        .accessibilityValue(title)
    }

    /// A menu row's checkmark: on for the current scope, and choosing it
    /// moves the scope there.
    private func choosing(_ id: Host.ID?) -> Binding<Bool> {
        Binding(get: { scopeHostID == id }, set: { if $0 { scopeHostID = id } })
    }

    private var title: String {
        scopeHostID.flatMap { id in entries.first { $0.id == id }?.name } ?? "All Hosts"
    }
}

/// An iPad sidebar's Usage list: All Hosts, then each Host with its
/// 30-day figure. Hosts that cannot report are listed but not chosen.
struct AgentUsageSidebar: View {
    let entries: [AgentUsageHostEntry]
    @Binding var scopeHostID: Host.ID?
    @Environment(\.locale) private var locale

    private static let allHosts = "all"

    var body: some View {
        let scope = AgentUsageScope(readings: entries.map(\.reading))
        List(selection: selection) {
            row(title: "All Hosts", symbol: "square.stack.3d.up",
                subtitle: "\(AgentUsageStyle.tokens(scope.total(.last30Days).tokens.total, locale: locale)) tokens · 30 days",
                value: AgentUsageStyle.shortCost(scope.total(.last30Days).estimatedCostUSD, locale: locale))
                .tag(Self.allHosts)
            Section("Hosts") {
                ForEach(scope.included) { host in
                    row(title: host.name, symbol: "desktopcomputer",
                        subtitle: "\(AgentUsageStyle.tokens(host.last30Days.tokens.total, locale: locale)) tokens · 30 days",
                        value: AgentUsageStyle.shortCost(host.last30Days.estimatedCostUSD, locale: locale))
                        .tag(host.id.uuidString)
                }
                ForEach(scope.loading) { host in
                    row(title: host.name, symbol: "desktopcomputer", subtitle: "Loading…", value: nil)
                        .tag(host.id.uuidString)
                }
                ForEach(scope.excluded) { host in
                    row(title: host.name,
                        symbol: host.reason == "Not connected" ? "wifi.slash" : "desktopcomputer",
                        subtitle: host.reason, value: nil)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { scopeHostID?.uuidString ?? Self.allHosts },
            set: { value in
                guard let value else { return }
                scopeHostID = value == Self.allHosts ? nil : UUID(uuidString: value)
            })
    }

    private func row(title: String, symbol: String, subtitle: String, value: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
