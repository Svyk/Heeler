import SwiftUI

/// Floating controls over an Agent or terminal. Separate glass pieces float
/// over the terminal: Back at the leading end, the Agent's title beside it,
/// and at the far end a More menu that stays put. The room between them is
/// left to the terminal, and folding leaves only the menu, so the header can
/// cover almost no output.
///
/// Back is the way out of a detail pushed over the list, on an iPhone or in
/// a compact iPad window, which the edge swipe alone never showed (#396).
/// Beside an iPad's sidebar there is nothing to go back to, so the header
/// keeps only its menu.
///
/// The menu holds the screen's actions and the item that folds or unfolds
/// the header, each titled in one word. Actions are plain values rather than
/// views, so a screen can leave out the ones it cannot offer.
///
/// An Agent that has Chat also shows a button for the surface it is not
/// showing, Chat or its terminal, sharing the menu's capsule in both states,
/// so the other surface stays one tap away while the header is folded.
struct AgentDetailHeader: View {
    static let controlSize: CGFloat = 44
    /// How much of the glass shows, the rest letting output through.
    static let glassOpacity: Double = 0.8
    /// Buttons sharing a capsule sit closer than standalone ones.
    private static let capsuleButtonWidth: CGFloat = 36
    private static let capsuleInset: CGFloat = (controlSize - capsuleButtonWidth) / 2

    /// Where the header's top edge sits. Beside an iPad's sidebar it lines
    /// up with the detail column's bar, level with the sidebar's buttons and
    /// Show Sidebar, even while output starts below the bar; elsewhere it
    /// rides just below the output's top. A bar's buttons fill a control's
    /// height from its top edge, with the bar's remaining height below
    /// them, so the header starts at that edge rather than centering.
    static func top(outputTop: CGFloat, barRow: NavigationBarBand?) -> CGFloat {
        guard let barRow, barRow.bottom - barRow.top >= controlSize else { return outputTop + 4 }
        return barRow.top
    }

    let palette: TerminalThemePalette
    @Binding var isExpanded: Bool
    /// Nil where the detail stands beside the list rather than over it.
    let onBack: (() -> Void)?
    var actions: [AgentDetailHeaderAction] = []
    /// Nil for a screen with one surface, such as a shell terminal.
    var surfaceSwitch: AgentDetailSurfaceSwitch?
    /// Nil for a screen that names nothing, such as a shell terminal.
    var title: AgentDetailHeaderTitle?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// The expanded title's height, which the grip under it resizes.
    @State private var titleHeight: CGFloat = AgentDetailHeader.controlSize
    /// Set while a grip drag is under way, so the drag measures from where it began.
    @State private var titleHeightAtDragStart: CGFloat?
    /// The width of the trailing controls, measured so the leading slot can match it.
    @State private var trailingWidth: CGFloat = 0
    /// The trailing safe inset, which a floating tab bar takes. The row starts
    /// this far in too, so the title centres on the content, not the row.
    @State private var trailingSafeInset: CGFloat = 0

    /// How tall the expanded title may grow, so it never covers most of the output.
    static let titleHeightRange: ClosedRange<CGFloat> = controlSize...240

    /// Both side slots are this wide while expanded, so the title sits at the
    /// header's centre rather than between controls of different widths.
    private var slotWidth: CGFloat { max(trailingWidth, Self.controlSize) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leadingSlot
            if isExpanded, let title {
                titlePill(title)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Spacer(minLength: 0)
            }
            trailingControls
                .frame(width: isExpanded ? slotWidth : nil, alignment: .trailing)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: {
            trailingSafeInset = $0
        }
        .padding(.leading, trailingSafeInset)
        .foregroundStyle(palette.foreground)
    }

    /// Back while expanded, on a slot as wide as the trailing controls. Empty
    /// and absent while folded, so the folded header is unchanged.
    @ViewBuilder
    private var leadingSlot: some View {
        if isExpanded {
            if let onBack {
                AgentDetailHeaderButton("Back", systemImage: "chevron.left", action: onBack)
                    .headerGlass(in: .circle)
                    .frame(width: slotWidth, alignment: .leading)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Color.clear.frame(width: slotWidth)
            }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        if let surfaceSwitch {
            HStack(spacing: 0) {
                surfaceButton(surfaceSwitch)
                Rectangle()
                    .fill(palette.foreground.opacity(0.25))
                    .frame(width: 1 / max(displayScale, 1), height: 20)
                    .padding(.horizontal, 2)
                moreMenu(width: Self.capsuleButtonWidth)
            }
            .padding(.horizontal, Self.capsuleInset)
            .fixedSize()
            .headerGlass(in: .capsule)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                trailingWidth = $0
            }
        } else {
            moreMenu(width: Self.controlSize)
                .headerGlass(in: .circle)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    trailingWidth = $0
                }
        }
    }

    /// Fills the room up to the trailing capsule, so the gaps on either side
    /// match, truncating the title at its end and the directory at its
    /// start, so the folder the Agent works in stays readable.
    private func titlePill(_ title: AgentDetailHeaderTitle) -> some View {
        VStack(spacing: 1) {
            // One line at rest; the task title wraps into the room a resize adds.
            Text(title.title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(titleHeight > Self.controlSize ? nil : 1)
            HStack(spacing: 4) {
                Text(title.harness)
                    .layoutPriority(1)
                if let directory = title.directory {
                    Text(verbatim: "·")
                        .layoutPriority(1)
                    Text(directory)
                        .truncationMode(.head)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.foreground.opacity(0.6))
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, minHeight: Self.controlSize)
        .frame(height: titleHeight)
        .headerGlass(in: .capsule)
        .overlay(alignment: .bottom) { resizeGrip }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// A grip under the expanded title. Dragging it resizes the title, and
    /// VoiceOver adjusts it up or down.
    private var resizeGrip: some View {
        Capsule()
            .fill(palette.foreground.opacity(0.35))
            .frame(width: 36, height: 4)
            .padding(.vertical, 6)
            .padding(.horizontal, 24)
            .contentShape(.rect)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = titleHeightAtDragStart ?? titleHeight
                        titleHeightAtDragStart = start
                        titleHeight = Self.clampedTitleHeight(start + value.translation.height)
                    }
                    .onEnded { _ in titleHeightAtDragStart = nil })
            .accessibilityLabel("Resize title")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: titleHeight = Self.clampedTitleHeight(titleHeight + 24)
                case .decrement: titleHeight = Self.clampedTitleHeight(titleHeight - 24)
                @unknown default: break
                }
            }
    }

    private static func clampedTitleHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, titleHeightRange.lowerBound), titleHeightRange.upperBound)
    }

    /// Swaps to the surface not showing, drawn with that surface's glyph.
    private func surfaceButton(_ control: AgentDetailSurfaceSwitch) -> some View {
        let target = control.other
        return Button {
            control.select(target)
        } label: {
            Image(systemName: target.showSystemImage)
                .font(.system(size: Self.surfacePointSize(target), weight: .semibold))
                .frame(width: Self.capsuleButtonWidth, height: Self.controlSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(target.showTitle)
        .accessibilityHint(target.showAccessibilityHint)
    }

    /// The two-bubble glyph draws wider than the terminal's at one size, so
    /// it gets a smaller one to sit evenly beside the More menu.
    private static func surfacePointSize(_ surface: AgentDetailSurface) -> CGFloat {
        switch surface {
        case .chat: 15
        case .terminal: 17
        }
    }

    /// Stays at the far end in both states: the screen's actions, then the
    /// item that folds or unfolds the header.
    private func moreMenu(width: CGFloat) -> some View {
        Menu {
            ForEach(actions) { @Sendable action in
                MainActorContent {
                    Button(action.title, systemImage: action.systemImage, action: action.perform)
                }
            }
            Button(
                isExpanded ? "Collapse" : "Expand",
                // A window's top bar, which is what this shows and hides: put
                // away while it is out, filled in while it is folded.
                systemImage: isExpanded
                    ? "menubar.arrow.up.rectangle" : "inset.filled.topthird.rectangle"
            ) {
                withAnimation(reduceMotion ? nil : .snappy) {
                    isExpanded.toggle()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .frame(width: width, height: Self.controlSize)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("More")
    }
}

/// What `AgentDetailHeader` names: the Agent's task on the first line, and
/// its harness and directory on the second.
struct AgentDetailHeaderTitle: Equatable {
    let title: String
    let harness: String
    let directory: String?
}

extension AgentDetailHeaderTitle {
    /// The task title as the Console list shows it, the harness by its
    /// product name rather than a custom Agent name, and the launch
    /// directory with the Host account's home shortened to `~`.
    init(_ agent: ConsoleAgent) {
        self.init(
            title: AgentTerminalView.displayTitle(for: agent),
            harness: SupportedAgentKind(rawValue: agent.agent.kind)?.displayName
                ?? agent.agent.kind,
            directory: agent.displayCwd.isEmpty ? nil : agent.displayCwd)
    }
}

/// The surface an Agent detail shows, and how to swap it, for
/// `AgentDetailHeader`'s surface button. Main-actor isolated, and so
/// Sendable, for the same reason as `AgentDetailHeaderAction`.
@MainActor
struct AgentDetailSurfaceSwitch {
    let current: AgentDetailSurface
    let select: (AgentDetailSurface) -> Void

    /// The surface the header's button brings up.
    var other: AgentDetailSurface {
        switch current {
        case .chat: .terminal
        case .terminal: .chat
        }
    }
}

/// One of the actions in `AgentDetailHeader`'s More menu. Isolated to the
/// main actor, which makes it Sendable: the menu's `ForEach` content is
/// `@Sendable` and hands each action to `MainActorContent` (#471).
@MainActor
struct AgentDetailHeaderAction: Identifiable {
    let title: LocalizedStringKey
    let systemImage: String
    let perform: () -> Void

    nonisolated var id: String { systemImage }
}

/// An icon button inside `AgentDetailHeader`. It has no surface of its own:
/// the header puts it on a glass circle.
struct AgentDetailHeaderButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: AgentDetailHeader.controlSize, height: AgentDetailHeader.controlSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// Liquid Glass where the system has it, a blur before that. The glass
    /// sits behind the icons at part strength, so the output under the
    /// buttons still shows through while the icons stay solid. Chat's
    /// floating buttons share it at their own strength.
    func headerGlass(
        in shape: some Shape, opacity: Double = AgentDetailHeader.glassOpacity
    ) -> some View {
        background {
            Group {
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .opacity(opacity)
        }
        .contentShape(shape)
    }
}
