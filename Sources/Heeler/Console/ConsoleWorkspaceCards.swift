import SwiftUI
import UIKit

/// The Agents list's By Workspace cards. The plain list keeps the other
/// presentations' background and has no cards of its own, so each row draws
/// its slice of one, as the Terminals list's By Host cards do.
enum ConsoleWorkspaceCardMetrics {
    /// From the screen edge to the card, as the Terminals cards.
    static let margin: CGFloat = 16
    /// From the card's edge to its icons.
    static let padding: CGFloat = 14
    static let iconWidth: CGFloat = 20
    static let iconSpacing: CGFloat = 10
    /// From the card's edge to its text, past the icon column.
    static let textInset = padding + iconWidth + iconSpacing
    static let radius: CGFloat = 18
    /// Between cards.
    static let gap: CGFloat = 12

    /// A quiet gray card on the list's own background. Beside the sidebar's
    /// glass, the Terminals cards' fill.
    static func fill(inSidebar: Bool) -> Color {
        inSidebar ? ListCard.fill(inSidebar: true) : Color(uiColor: .secondarySystemBackground)
    }
}

/// One row's slice of its card: the first rounds the top and keeps the gap
/// above the card, the last rounds the bottom, and a row's rule sits on top.
struct ConsoleWorkspaceCardSlice: ViewModifier {
    let placed: ConsoleWorkspaceCard.Placed
    /// From the card's edge to the row's content: its icon, or its text for
    /// an Agent listed under a header.
    let leading: CGFloat
    let top: CGFloat
    let bottom: CGFloat
    var isSelected = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    private typealias Metrics = ConsoleWorkspaceCardMetrics

    func body(content: Content) -> some View {
        let gap = placed.isFirst ? Metrics.gap : 0
        let topRadius = placed.isFirst ? Metrics.radius : 0
        let bottomRadius = placed.isLast ? Metrics.radius : 0
        let slice = UnevenRoundedRectangle(
            topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
            style: .continuous)
        content
            .listRowInsets(
                EdgeInsets(
                    top: gap + top, leading: Metrics.margin + leading, bottom: bottom,
                    trailing: Metrics.margin + Metrics.padding))
            .listRowSeparator(.hidden)
            .listRowBackground(
                slice
                    .fill(Metrics.fill(inSidebar: isSidebarColumn))
                    .background { if isSidebarColumn { ListRowFocusHalo(shape: slice) } }
                    .overlay {
                        if isSelected { slice.fill(ConsoleRowSelection.fill) }
                    }
                    .overlay(alignment: .top) { rule }
                    .padding(.top, gap)
                    .padding(.horizontal, Metrics.margin))
    }

    @ViewBuilder
    private var rule: some View {
        if placed.rule != .none {
            let isInset = placed.rule == .inset
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / displayScale)
                .padding(.leading, isInset ? Metrics.textInset : 0)
                .padding(.trailing, isInset ? Metrics.padding : 0)
        }
    }
}

/// The card's icon column: a folder for what expands, a closed book for a
/// repository's main checkout, and a branch for a linked worktree.
struct ConsoleWorkspaceCardIcon: View {
    let systemName: String

    static let folder = "folder"

    init(systemName: String) {
        self.systemName = systemName
    }

    init(checkout: RepositoryCheckout?) {
        systemName = checkout?.isLinkedWorktree == true ? "arrow.triangle.branch" : "book.closed"
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: ConsoleWorkspaceCardMetrics.iconWidth)
            .accessibilityHidden(true)
    }
}

/// A checkout's title, then its branch or state in a quieter face; the
/// branch truncates first.
struct ConsoleCheckoutTitleText: View {
    let title: ConsoleCheckoutTitle
    let font: Font
    var detailFont: Font = .footnote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: title.title)
                .font(font)
                .foregroundStyle(title.isPending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .layoutPriority(1)
            if let detail = title.detail {
                Text(verbatim: detail)
                    .font(detailFont)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

/// One checkout in a collapsed repository's summary.
struct ConsoleCheckoutSummary: Identifiable, Sendable {
    let id: ConsoleWorkspaceSection.ID
    let title: ConsoleCheckoutTitle
    let checkout: RepositoryCheckout?
    let statuses: [AgentStatus]
}

/// A card's header: what it holds, where, how many Agents, and the chevron
/// that collapses it. Collapsed, it says who needs the user and, for a
/// repository, in which checkout.
struct ConsoleWorkspaceCardHeader: View {
    let card: ConsoleWorkspaceCard
    let title: String
    let subtitle: String
    let checkouts: [ConsoleCheckoutSummary]
    let onToggle: () -> Void

    private typealias Metrics = ConsoleWorkspaceCardMetrics

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.iconSpacing) {
                    ConsoleWorkspaceCardIcon(systemName: ConsoleWorkspaceCardIcon.folder)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(card.agents.count)")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    Image(systemName: card.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 12)
                }
                if card.isCollapsed {
                    summary
                        .padding(.leading, Metrics.iconWidth + Metrics.iconSpacing)
                }
            }
            .lineLimit(1)
            // From the top, so the title stays put as the summary comes and goes.
            .frame(minHeight: 44, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(subtitle)"))
        .accessibilityValue(card.accessibilityValue)
        .accessibilityHint(card.isCollapsed ? "Expands this Workspace." : "Collapses this Workspace.")
        .accessibilityAddTraits(.isHeader)
        .textCase(nil)
    }

    @ViewBuilder
    private var summary: some View {
        let items = ConsoleHostAgentStatusCounts(agents: card.agents).items
        VStack(alignment: .leading, spacing: 6) {
            if !items.isEmpty {
                ConsoleHostStatusCountPills(items: items)
            }
            ForEach(checkouts) { @Sendable checkout in
                MainActorContent { ConsoleCheckoutSummaryLine(summary: checkout) }
            }
        }
    }
}

private struct ConsoleCheckoutSummaryLine: View {
    let summary: ConsoleCheckoutSummary

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: ConsoleWorkspaceCardIcon(checkout: summary.checkout).systemName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            ConsoleCheckoutTitleText(title: summary.title, font: .footnote, detailFont: .caption)
            Spacer(minLength: 8)
            ConsoleAgentStatusDots(statuses: summary.statuses)
        }
    }
}

/// One dot per Agent in its status's ink, for a checkout whose rows are
/// folded away.
private struct ConsoleAgentStatusDots: View {
    let statuses: [AgentStatus]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { @Sendable _, status in
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A checkout with several Agents inside a repository's card. A worktree
/// collapses on its own; the main checkout folds with its card.
struct ConsoleCheckoutHeader: View {
    let section: ConsoleWorkspaceSection
    let title: ConsoleCheckoutTitle
    let onToggle: (() -> Void)?

    var body: some View {
        if let onToggle {
            Button(action: onToggle) { label }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: title.accessibilityLabel))
                .accessibilityValue(section.accessibilityValue)
                .accessibilityHint(
                    section.isCollapsed ? "Expands this worktree." : "Collapses this worktree.")
                .accessibilityAddTraits(.isHeader)
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: title.accessibilityLabel))
                .accessibilityValue(
                    section.agents.count == 1 ? "1 Agent" : "\(section.agents.count) Agents")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: ConsoleWorkspaceCardMetrics.iconSpacing) {
            ConsoleWorkspaceCardIcon(checkout: section.checkout)
            ConsoleCheckoutTitleText(title: title, font: .subheadline.weight(.semibold))
            Spacer(minLength: 8)
            if section.isCollapsed {
                ConsoleAgentStatusDots(statuses: section.agents.map(\.agent.status))
                    // Centered on the count's digits rather than sitting
                    // on their baseline.
                    .alignmentGuide(.firstTextBaseline) { $0.height + 1 }
            }
            Text("\(section.agents.count)")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            if onToggle != nil {
                Image(systemName: section.isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 12)
            }
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }
}
