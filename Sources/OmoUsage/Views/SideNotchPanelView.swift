import OmoUsageCore
import AppKit
import SwiftUI

struct SideNotchPanelView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    let localization: LocalizationController
    @Bindable var state: SideNotchPanelState
    let onSelectionIntent: (SideNotchSelectionIntent, Bool) -> Void
    let onKeyboardFocusTarget: (AccountProviderID) -> Void
    let onProviderCountChange: (Int) -> Void
    let onPointerEntered: (CGFloat?) -> Void
    let onPointerExited: () -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @State private var rowMidYs: [AccountProviderID: CGFloat] = [:]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if state.mode == .hidden {
                    SideNotchHiddenHandleView(
                        onReveal: {
                            onPointerEntered(nil)
                        }
                    )
                    .frame(width: SideNotchPanelLayout.hiddenWidth)
                    .frame(maxHeight: .infinity)
                } else {
                    if state.selection != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelectionIntent(
                                    .collapse,
                                    !reduceMotion
                                )
                            }
                    }

                    ZStack(alignment: .topTrailing) {
                        if let usage = selectedUsage {
                            let showsAccountLabel =
                                DashboardAccountIdentityRule.showsAlias(
                                    for: usage,
                                    sameProviderCount:
                                        viewModel.snapshot.providers.count {
                                            $0.provider == usage.provider
                                        }
                                )
                            let detailHeight = SideNotchPanelLayout
                                .detailHeight(
                                    for: usage,
                                    showsAccountLabel: showsAccountLabel,
                                    language: localization.language
                                )
                            let detailTop = SideNotchPanelLayout.detailTop(
                                rowMidY: rowMidY(for: usage),
                                detailHeight: detailHeight,
                                containerHeight: geometry.size.height
                            )
                            SideNotchDetailView(
                                usage: usage,
                                showsAccountLabel: showsAccountLabel,
                                tailCenterY:
                                    SideNotchBubbleTokens.tailCenterY(
                                        rowMidY: rowMidY(for: usage),
                                        cardTop: detailTop,
                                        cardHeight: detailHeight
                                    )
                            )
                                .frame(
                                    width:
                                        SideNotchPanelLayout.detailWidth
                                )
                                .position(
                                    x: geometry.size.width
                                        - SideNotchPanelLayout.collapsedWidth
                                        - SideNotchPanelLayout.detailSpacing
                                        - SideNotchPanelLayout.detailWidth / 2,
                                    y: detailTop + detailHeight / 2
                                )
                                .transition(.opacity)
                        }

                        SideNotchRailView(
                            providers: viewModel.snapshot.providers,
                            isRefreshing: viewModel.isRefreshing,
                            onSelect: { target in
                                onSelectionIntent(.commit(target), true)
                            },
                            onHoverTarget: { target in
                                onSelectionIntent(.hover(target), true)
                            },
                            onKeyboardFocusTarget:
                                onKeyboardFocusTarget,
                            onRowMidY: { target, midY in
                                rowMidYs[target] = midY
                            },
                            onRefresh: onRefresh,
                            onSettings: onSettings,
                            onQuit: onQuit
                        )
                        .frame(
                            width:
                                SideNotchPanelLayout.collapsedWidth,
                            height:
                                SideNotchPanelLayout.railContentHeight(
                                    providerCount:
                                        viewModel.snapshot.providers
                                        .count,
                                    containerHeight:
                                        geometry.size.height
                                ),
                            alignment: .top
                        )
                    }
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height,
                        alignment: .topTrailing
                    )
                    .coordinateSpace(
                        .named(SideNotchPanelLayout.coordinateSpaceName)
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topTrailing
            )
        }
        .background {
            SideNotchTrackingSurface(
                onEntered: { screenY in
                    onPointerEntered(screenY)
                },
                onExited: onPointerExited
            )
        }
        .environment(\.appLocalization, localization.context)
        .onChange(
            of: viewModel.snapshot.providers,
            initial: true
        ) { _, providers in
            onProviderCountChange(providers.count)
            onSelectionIntent(
                .reconcile(providers.map(\.accountProviderID)),
                false
            )
        }
        .onExitCommand {
            onSelectionIntent(.collapse, !reduceMotion)
        }
    }

    private var selectedUsage: ProviderUsage? {
        guard let target = state.selectedTarget else {
            return nil
        }
        return viewModel.snapshot.providers.first {
            $0.accountProviderID == target
        }
    }

    private func rowMidY(for usage: ProviderUsage) -> CGFloat {
        if let measured = rowMidYs[usage.accountProviderID] {
            return measured
        }
        let index = viewModel.snapshot.providers.firstIndex {
            $0.accountProviderID == usage.accountProviderID
        } ?? 0
        return SideNotchPanelLayout.providerRowMidY(at: index)
    }
}

private struct SideNotchHiddenHandleView: View {
    let onReveal: () -> Void
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(localization.text(.aiUsage))
            .accessibilityHint(
                localization.text(.sideNotchShowDetails)
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onReveal()
            }
    }
}

private struct SideNotchTrackingSurface: NSViewRepresentable {
    let onEntered: (CGFloat) -> Void
    let onExited: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(
            onEntered: onEntered,
            onExited: onExited
        )
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onEntered = onEntered
        nsView.onExited = onExited
    }

    final class TrackingView: NSView {
        var onEntered: (CGFloat) -> Void
        var onExited: () -> Void
        private var trackingArea: NSTrackingArea?

        init(
            onEntered: @escaping (CGFloat) -> Void,
            onExited: @escaping () -> Void
        ) {
            self.onEntered = onEntered
            self.onExited = onExited
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func updateTrackingAreas() {
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [
                    .activeAlways,
                    .mouseEnteredAndExited,
                    .inVisibleRect
                ],
                owner: self
            )
            addTrackingArea(trackingArea)
            self.trackingArea = trackingArea
            super.updateTrackingAreas()
        }

        override func mouseEntered(with event: NSEvent) {
            guard let window else { return }
            onEntered(
                window.convertPoint(
                    toScreen: event.locationInWindow
                ).y
            )
        }

        override func mouseExited(with event: NSEvent) {
            guard let window else { return }
            let eventPointer = window.convertPoint(
                toScreen: event.locationInWindow
            )
            guard
                SideNotchTrackingExitPolicy.shouldForward(
                    eventPointer: eventPointer,
                    livePointer: NSEvent.mouseLocation,
                    panelFrame: window.frame
                )
            else {
                return
            }
            onExited()
        }
    }
}

private struct SideNotchRailView: View {
    let providers: [ProviderUsage]
    let isRefreshing: Bool
    let onSelect: (AccountProviderID) -> Void
    let onHoverTarget: (AccountProviderID) -> Void
    let onKeyboardFocusTarget: (AccountProviderID) -> Void
    let onRowMidY: (AccountProviderID, CGFloat) -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.appLocalization)
    private var localization
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @State private var isMenuHovered = false

    var body: some View {
        let providerCounts = Dictionary(
            grouping: providers,
            by: \.provider
        ).mapValues(\.count)
        VStack(spacing: 0) {
            if providers.isEmpty {
                if isRefreshing {
                    VStack(spacing: 8) {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(.system(size: 22, weight: .medium))
                        Text(localization.text(.checking))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(
                                SideNotchRailVisualTokens.emptyStateForeground
                            )
                    }
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                } else {
                    Button(action: onSettings) {
                        VStack(spacing: 8) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18, weight: .medium))
                            Text(localization.text(.openSettings))
                                .font(.system(size: 10.5, weight: .medium))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // The nonactivating panel renders .secondary permanently
                    // dimmed, so the only action on the rail stays primary.
                    .foregroundStyle(.primary)
                    .help(localization.text(.dashboardEmptyTitle))
                    .accessibilityLabel(localization.text(.openSettings))
                    .accessibilityIdentifier("side-notch-open-settings")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Keyed by account AND provider so two accounts on one
                        // provider are two distinct rows.
                        ForEach(
                            providers,
                            id: \.accountProviderID
                        ) { usage in
                            SideNotchProviderButton(
                                usage: usage,
                                showsAccountLabel:
                                    DashboardAccountIdentityRule.showsAlias(
                                        for: usage,
                                        sameProviderCount: providerCounts[
                                            usage.provider,
                                            default: 0
                                        ]
                                    ),
                                action: {
                                    onSelect(usage.accountProviderID)
                                },
                                onHoverTarget: {
                                    onHoverTarget(usage.accountProviderID)
                                },
                                onKeyboardFocus: {
                                    onKeyboardFocusTarget(
                                        usage.accountProviderID
                                    )
                                }
                            )
                            .frame(
                                height:
                                    SideNotchPanelLayout.providerRowHeight
                            )
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(
                                    in: .named(
                                        SideNotchPanelLayout
                                            .coordinateSpaceName
                                    )
                                ).midY
                            } action: { midY in
                                onRowMidY(usage.accountProviderID, midY)
                            }
                        }
                    }
                    .padding(.vertical, 7)
                    .dashboardOverlayScrollers()
                }
                .scrollIndicators(.automatic)
            }

            VStack(spacing: 2) {
                refreshButton
                    .frame(
                        width: SideNotchPanelLayout.collapsedWidth,
                        height: SideNotchPanelLayout.footerControlHeight,
                        alignment: .center
                    )

                Menu {
                    Button(
                        localization.text(.settings),
                        action: onSettings
                    )
                    Divider()
                    Button(
                        localization.text(.quit),
                        action: onQuit
                    )
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .frame(
                            width:
                                SideNotchPanelLayout.footerControlHeight,
                            height:
                                SideNotchPanelLayout.footerControlHeight
                        )
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                // A borderless menu keeps only its label's image, so the
                // hover tint Refresh gets from its button style is drawn on
                // the same 28 pt slot around the menu instead.
                .frame(
                    width: SideNotchPanelLayout.footerControlHeight,
                    height: SideNotchPanelLayout.footerControlHeight
                )
                .background(
                    Color.primary.opacity(
                        InteractiveControlVisualState(
                            isHovered: isMenuHovered,
                            isPressed: false,
                            reduceMotion: reduceMotion
                        ).backgroundOpacity
                    ),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(
                        reduceMotion ? nil : .easeOut(duration: 0.12)
                    ) {
                        isMenuHovered = hovering
                    }
                }
                .frame(
                    width: SideNotchPanelLayout.collapsedWidth,
                    height: SideNotchPanelLayout.footerControlHeight,
                    alignment: .center
                )
                .help(localization.text(.moreActions))
                .accessibilityLabel(localization.text(.moreActions))
            }
            .frame(height: SideNotchPanelLayout.footerHeight)
            .padding(.top, SideNotchPanelLayout.footerClearance)
            .overlay(alignment: .top) {
                Divider()
            }
        }
        .padding(.vertical, SideNotchPanelLayout.notchFilletRadius)
        .environment(\.dashboardPalette, .sideNotch)
        .background(
            SideNotchNeutralVisualTokens.surface,
            in: SideNotchRailShape(
                cornerRadius: SideNotchPanelLayout.railCornerRadius,
                filletRadius: SideNotchPanelLayout.notchFilletRadius
            )
        )
        .overlay {
            SideNotchRailShape(
                cornerRadius: SideNotchPanelLayout.railCornerRadius,
                filletRadius: SideNotchPanelLayout.notchFilletRadius
            )
            .stroke(
                Color(nsColor: .separatorColor),
                lineWidth: 0.5
            )
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if SideNotchRefreshAnimationPolicy.shouldSpin(
            isRefreshing: isRefreshing,
            reduceMotion: reduceMotion
        ) {
            SpinningRefreshButton(
                accessibilityLabel: localization.text(.refresh),
                hitTargetSize: SideNotchPanelLayout.footerControlHeight
            )
        } else {
            InteractiveIconButton(
                symbol: "arrow.clockwise",
                accessibilityLabel: localization.text(.refresh),
                isActive: isRefreshing,
                isDisabled: isRefreshing,
                dimsWhenDisabled: false,
                hitTargetSize: SideNotchPanelLayout.footerControlHeight,
                action: onRefresh
            )
        }
    }
}

enum SideNotchRefreshAnimationPolicy {
    static func shouldSpin(
        isRefreshing: Bool,
        reduceMotion: Bool
    ) -> Bool {
        isRefreshing && !reduceMotion
    }
}

/// The refresh control's dedicated active subtree, shared by the popover
/// footer and the Side Notch rail. It exists only while a refresh spins, so
/// returning to idle builds a fresh zero-rotation button and no
/// repeat-forever transaction outlives the refresh.
struct SpinningRefreshButton: View {
    let accessibilityLabel: String
    let hitTargetSize: CGFloat
    @State private var rotation = 0.0

    var body: some View {
        InteractiveIconButton(
            symbol: "arrow.clockwise",
            accessibilityLabel: accessibilityLabel,
            isActive: true,
            isDisabled: true,
            dimsWhenDisabled: false,
            hitTargetSize: hitTargetSize,
            action: {}
        )
        .rotationEffect(.degrees(rotation))
        .onAppear {
            rotation = 360
        }
        .animation(
            .linear(duration: 0.7).repeatForever(
                autoreverses: false
            ),
            value: rotation
        )
    }
}

private struct SideNotchProviderButton: View {
    let usage: ProviderUsage
    let showsAccountLabel: Bool
    let action: () -> Void
    let onHoverTarget: () -> Void
    let onKeyboardFocus: () -> Void

    @Environment(\.appLocalization)
    private var localization
    @FocusState private var isKeyboardFocused: Bool
    @State private var hasRequestedHoverPreview = false

    var body: some View {
        let accountLabel = AccountLabel.sanitized(usage.accountLabel)
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    // Track, arc, and badge all take the provider's icon
                    // color; only a remaining quota adds the arc.
                    Circle()
                        .stroke(
                            accent.opacity(
                                UsageMeterVisualTokens.trackOpacity
                            ),
                            lineWidth: SideNotchPanelLayout.ringLineWidth
                        )
                    if
                        summaryMeter.metric.kind == .quotaRemaining,
                        let fraction = summaryMeter.metric.progressFraction
                    {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(
                                accent,
                                style: StrokeStyle(
                                    lineWidth:
                                        SideNotchPanelLayout.ringLineWidth,
                                    lineCap: .round
                                )
                            )
                            .rotationEffect(.degrees(-90))
                    }

                    ProviderIcon(provider: usage.provider)
                        .frame(
                            width: SideNotchPanelLayout.providerIconSize,
                            height: SideNotchPanelLayout.providerIconSize
                        )
                        .clipShape(Circle())

                    if
                        showsAccountLabel,
                        let badge = SideNotchAccountIdentity.badgeText(
                            for: accountLabel
                        )
                    {
                        Text(badge)
                            .font(
                                .system(
                                    size: SideNotchAccountBadgeTokens.fontSize,
                                    weight: SideNotchAccountBadgeTokens.fontWeight,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(
                                SideNotchAccountBadgeTokens.foreground(
                                    for: usage.provider
                                )
                            )
                            .frame(
                                width: SideNotchAccountBadgeTokens.diameter,
                                height: SideNotchAccountBadgeTokens.diameter
                            )
                            .background(
                                SideNotchAccountBadgeTokens.fill(
                                    for: usage.provider
                                ),
                                in: Circle()
                            )
                            // A surface-colored halo separates the badge
                            // from the same-colored provider plate and ring.
                            .background(
                                Circle()
                                    .fill(SideNotchNeutralVisualTokens.surface)
                                    .padding(
                                        -SideNotchAccountBadgeTokens.haloWidth
                                    )
                            )
                            .offset(
                                x: SideNotchAccountBadgeTokens.offset,
                                y: SideNotchAccountBadgeTokens.offset
                            )
                    }

                    if SideNotchFreshnessPolicy.showsFailureMarker(
                        for: usage
                    ) {
                        Image(
                            systemName: StaleUsageVisualTokens.symbolName
                        )
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(SideNotchNeutralVisualTokens.ink)
                            .background(
                                SideNotchNeutralVisualTokens.surface,
                                in: Circle()
                            )
                            .offset(x: 14, y: -14)
                    }
                }
                .frame(
                    width: SideNotchPanelLayout.ringDiameter,
                    height: SideNotchPanelLayout.ringDiameter
                )

                SideNotchRailCaption(
                    text: compactMetricValue,
                    isRunningLow: SideNotchUsageRisk.level(
                        for: summaryMeter.metric
                    ) == .critical
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($isKeyboardFocused)
        .onChange(of: isKeyboardFocused) { _, focused in
            guard focused else { return }
            onKeyboardFocus()
        }
        .onKeyPress(keys: [.return, .space]) { _ in
            action()
            return .handled
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard
                    !hasRequestedHoverPreview,
                    let screen = NSScreen.screens.first(
                        where: {
                            NSMouseInRect(
                                NSEvent.mouseLocation,
                                $0.frame,
                                false
                            )
                        }
                    ),
                    SideNotchProviderInteractionPolicy.shouldPreview(
                        pointerScreenX: NSEvent.mouseLocation.x,
                        visibleFrame: screen.visibleFrame
                    )
                else {
                    return
                }
                hasRequestedHoverPreview = true
                onHoverTarget()
            case .ended:
                hasRequestedHoverPreview = false
            }
        }
        .help(
            SideNotchAccountIdentity.accessibleName(
                providerName: usage.provider.displayName,
                accountLabel: showsAccountLabel ? accountLabel : nil
            )
        )
        .accessibilityLabel(
            SideNotchAccountIdentity.accessibleName(
                providerName: usage.provider.displayName,
                accountLabel: showsAccountLabel ? accountLabel : nil
            )
        )
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(localization.text(.sideNotchShowDetails))
    }

    private var accent: Color {
        SideNotchBrandVisualTokens.accent(for: usage.provider)
    }

    private var compactMetricValue: String {
        SideNotchMetricPresentation.compactValue(
            for: summaryMeter.metric,
            localizedValue: localization.metricValue(summaryMeter.metric)
        )
    }

    private var summaryMeter: UsageMeter {
        SideNotchSummaryMeterPolicy.select(
            from: usage.groups.flatMap(\.meters)
        )
            ?? UsageMeter(
                id: "unavailable",
                title: "",
                period: .session,
                percentRemaining: 0
            )
    }

    private var accessibilityValue: String {
        // The label already names the provider, so the value starts with the
        // usage itself.
        var value = localization.metricValue(summaryMeter.metric)
        // Ring color is never the only signal: a critical ring is also
        // spoken.
        if SideNotchUsageRisk.level(for: summaryMeter.metric) == .critical {
            value += ", \(localization.text(.sideNotchRunningLow))"
        }
        if usage.isWaitingForRetry {
            return "\(value), \(localization.rateLimitRetryNoticeText())"
        }
        guard usage.freshness == .stale else { return value }
        return "\(value), \(localization.staleBadgeText())"
    }
}

enum SideNotchSummaryMeterPolicy {
    static func select(from meters: [UsageMeter]) -> UsageMeter? {
        meters.first {
            $0.metric.kind == .quotaRemaining && $0.period == .session
        } ?? meters.first {
            $0.metric.kind == .quotaRemaining && $0.period != .extra
        } ?? meters.first {
            $0.metric.kind == .quotaRemaining
        } ?? meters.first
    }
}

enum SideNotchMetricPresentation {
    static func compactValue(
        for metric: UsageMetric,
        localizedValue: String
    ) -> String {
        switch metric {
        case .quotaRemaining(let percent):
            "\(percent)%"
        case .spend, .credit, .count, .informational:
            localizedValue
        }
    }
}

/// The rail shows only a compact ring, so retained-but-stale usage needs the
/// same failure marker a hard failure gets.
enum SideNotchFreshnessPolicy {
    static func showsFailureMarker(for usage: ProviderUsage) -> Bool {
        usage.freshness == .stale || usage.availability == .failed
    }
}

enum SideNotchProviderInteractionPolicy {
    static func hitFrame(for rowSize: CGSize) -> CGRect {
        CGRect(origin: .zero, size: rowSize)
    }

    static func shouldPreview(
        pointerScreenX: CGFloat,
        visibleFrame: NSRect
    ) -> Bool {
        pointerScreenX <= visibleFrame.maxX
            && visibleFrame.maxX - pointerScreenX
                > SideNotchPanelLayout.hiddenTrackingWidth
    }
}

/// Elevation for the side-notch detail card.
///
/// The card sits on the desktop rather than inside a window, so its shadow
/// is the only thing separating it from the backdrop. A wide blur reads as
/// an omnidirectional bloom instead of a lit edge, so the blur stays within
/// twice the downward offset and the color stays dark in both appearances:
/// elevation may darken the backdrop, never lighten it.
enum SideNotchDetailElevationTokens {
    static let shadowColor = Color(nsColor: .shadowColor)
    static let shadowOpacity = 0.12
    static let shadowRadius: CGFloat = 4
    static let shadowOffsetY: CGFloat = 2
}

struct SideNotchDetailView: View {
    let usage: ProviderUsage
    let showsAccountLabel: Bool
    /// Vertical center of the bubble tail in the card's own coordinates.
    var tailCenterY: CGFloat?
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        let bubble = SideNotchBubbleShape(
            cornerRadius: SideNotchBubbleTokens.cornerRadius,
            tailCenterY: tailCenterY,
            tailHalfHeight: SideNotchBubbleTokens.tailHalfHeight,
            tailLength: SideNotchBubbleTokens.tailLength
        )
        ProviderSectionView(
            usage: usage,
            showsAccountLabel: showsAccountLabel,
            usesCircularProviderIcon: true
        )
        .environment(\.dashboardPalette, .sideNotch)
        .environment(\.sideNotchAccentProvider, usage.provider)
        .padding(SideNotchPanelLayout.detailContentPadding)
        .frame(
            height: SideNotchPanelLayout.detailHeight(
                for: usage,
                showsAccountLabel: showsAccountLabel,
                language: localization.language
            )
        )
        .background(SideNotchNeutralVisualTokens.surface, in: bubble)
        .overlay {
            bubble.stroke(
                Color(nsColor: .separatorColor),
                lineWidth: 0.5
            )
        }
        .shadow(
            color: SideNotchDetailElevationTokens.shadowColor.opacity(
                SideNotchDetailElevationTokens.shadowOpacity
            ),
            radius: SideNotchDetailElevationTokens.shadowRadius,
            y: SideNotchDetailElevationTokens.shadowOffsetY
        )
    }
}

/// Rail text that is not part of a provider section. The panel never becomes
/// key, so system `.secondary` renders permanently dimmed there; the caption
/// reads the same primary-derived foreground as provider metadata.
enum SideNotchRailVisualTokens {
    static let emptyStateForegroundRole =
        ProviderMetadataForegroundRole.primaryDerived

    static var emptyStateForeground: Color {
        ProviderMetadataVisualTokens.foreground
    }
}

/// The account initial on a rail ring. An 8 pt glyph beside the 4 pt ring
/// stroke was illegible, so the badge is a solid plate in the provider's
/// accent with a black or white glyph, whichever keeps 4.5:1, ringed by a
/// surface halo.
enum SideNotchAccountBadgeTokens {
    static let fontSize: CGFloat = 9
    static let fontWeight = Font.Weight.semibold
    static let diameter: CGFloat = 16
    static let offset: CGFloat = 14
    static let haloWidth: CGFloat = 1.5

    static func fill(for provider: ProviderID) -> Color {
        SideNotchBrandVisualTokens.accent(for: provider)
    }

    static func foreground(for provider: ProviderID) -> Color {
        SideNotchBrandVisualTokens.onAccent(for: provider)
    }
}

/// A rail caption. Below 20% remaining it becomes an ink pill, so running
/// low reads without changing the provider's color.
private struct SideNotchRailCaption: View {
    let text: String
    let isRunningLow: Bool

    var body: some View {
        Text(text)
            .font(
                .system(
                    size: 10.5,
                    weight: isRunningLow ? .bold : .semibold
                )
            )
            .monospacedDigit()
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .multilineTextAlignment(.center)
            .foregroundStyle(
                isRunningLow
                    ? SideNotchNeutralVisualTokens.onInk
                    : SideNotchNeutralVisualTokens.ink
            )
            .padding(.horizontal, isRunningLow ? 5 : 0)
            .background {
                if isRunningLow {
                    Capsule().fill(SideNotchNeutralVisualTokens.ink)
                }
            }
    }
}

/// The Side Notch's neutral, for the surface, the stale marker, and the
/// running-low caption pill. Provider color comes from
/// `SideNotchBrandVisualTokens`. The rail and card sit on an opaque
/// semantic surface rather than translucent material, so the wallpaper never
/// muddies the provider colors; it still follows light, dark, and Increase
/// Contrast because it is the system window background.
enum SideNotchNeutralVisualTokens {
    static let ink = Color.primary
    static let onInk = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .windowBackgroundColor)
}

enum SideNotchAccountIdentity {
    static func badgeText(
        for accountLabel: String
    ) -> String? {
        AccountLabel.sanitized(accountLabel)
            .split(whereSeparator: \.isWhitespace)
            .last?
            .first
            .map { String($0).uppercased() }
    }

    static func accessibleName(
        providerName: String,
        accountLabel: String?
    ) -> String {
        guard let accountLabel else { return providerName }
        return "\(providerName), \(AccountLabel.sanitized(accountLabel))"
    }
}

/// How close a remaining-quota meter is to running out. Rings and bars keep
/// the provider's color, so a critical level is shown as an ink caption pill
/// on the rail and spoken in the ring's accessibility value instead.
enum SideNotchUsageRisk: Equatable, Sendable {
    case comfortable
    case low
    case critical

    /// Remaining percentages below these bounds are low and critical.
    static let lowBelowPercent = 50
    static let criticalBelowPercent = 20

    static func level(percentRemaining: Int) -> SideNotchUsageRisk {
        if percentRemaining < criticalBelowPercent { return .critical }
        if percentRemaining < lowBelowPercent { return .low }
        return .comfortable
    }

    /// `nil` for metrics that are not a remaining quota.
    static func level(for metric: UsageMetric) -> SideNotchUsageRisk? {
        guard case .quotaRemaining(let percent) = metric else { return nil }
        return level(percentRemaining: percent)
    }
}

/// Each provider's Side Notch color is its icon's brand color: the rail
/// ring, its track, the account badge, and the detail bars all use it, so one
/// provider reads as one color. Black-tile brands (Cursor, Copilot, Grok,
/// OpenCode) use the neutral ink. Gradient brands take their tile's
/// dominant hue; the light value is deepened and the dark value lifted only as
/// far as each needs to keep 3:1 against the window background. Each value is
/// muted to 80% of its brand chroma (OKLCH, same hue and lightness) so the rail
/// reads calmer than the icon tile beside it.
enum SideNotchBrandVisualTokens {
    /// `nil` means the provider's tile is black, so it draws in ink.
    static func lightRGB(for provider: ProviderID) -> VisualRGB? {
        switch provider {
        case .claude: VisualRGB(red: 0xCA, green: 0x59, blue: 0x35)
        case .codex: VisualRGB(red: 0x5A, green: 0x5E, blue: 0xC1)
        case .antigravity: VisualRGB(red: 0x3E, green: 0x73, blue: 0xCB)
        case .devin: VisualRGB(red: 0xA7, green: 0x61, blue: 0xCD)
        case .kiro: VisualRGB(red: 0x6B, green: 0x4A, blue: 0xB4)
        case .openrouter: VisualRGB(red: 0xD6, green: 0x42, blue: 0x4E)
        case .zai: VisualRGB(red: 0x33, green: 0x7F, blue: 0xE6)
        case .cursor, .copilot, .grok, .opencode: nil
        }
    }

    static func darkRGB(for provider: ProviderID) -> VisualRGB? {
        switch provider {
        case .claude: VisualRGB(red: 0xEF, green: 0x7C, blue: 0x56)
        case .codex: VisualRGB(red: 0x7A, green: 0x7B, blue: 0xCD)
        case .antigravity: VisualRGB(red: 0x53, green: 0x88, blue: 0xDF)
        case .devin: VisualRGB(red: 0xB6, green: 0x6A, blue: 0xDF)
        case .kiro: VisualRGB(red: 0x90, green: 0x74, blue: 0xC6)
        case .openrouter: VisualRGB(red: 0xEC, green: 0x51, blue: 0x62)
        case .zai: VisualRGB(red: 0x39, green: 0x87, blue: 0xE8)
        case .cursor, .copilot, .grok, .opencode: nil
        }
    }

    static func accent(for provider: ProviderID) -> Color {
        guard lightRGB(for: provider) != nil else {
            return SideNotchNeutralVisualTokens.ink
        }
        return dynamicColor { isDark in
            let rgb = isDark ? darkRGB(for: provider) : lightRGB(for: provider)
            return rgb.map(nsColor) ?? .labelColor
        }
    }

    /// Black or white, whichever reads better on the accent.
    static func onAccent(for provider: ProviderID) -> Color {
        guard lightRGB(for: provider) != nil else {
            return SideNotchNeutralVisualTokens.onInk
        }
        return dynamicColor { isDark in
            guard
                let rgb = isDark
                    ? darkRGB(for: provider) : lightRGB(for: provider)
            else {
                return .windowBackgroundColor
            }
            let luminance = relativeLuminance(rgb)
            // Contrast with black beats contrast with white above ~0.18.
            return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
                ? .black : .white
        }
    }

    static func relativeLuminance(_ rgb: VisualRGB) -> Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.red)
            + 0.7152 * channel(rgb.green)
            + 0.0722 * channel(rgb.blue)
    }

    private static func nsColor(_ rgb: VisualRGB) -> NSColor {
        NSColor(
            srgbRed: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: 1
        )
    }

    private static func dynamicColor(
        _ resolve: @escaping @Sendable (Bool) -> NSColor
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                resolve(
                    appearance.bestMatch(from: [.aqua, .darkAqua])
                        == .darkAqua
                )
            }
        )
    }
}

/// The revealed rail: rounded leading corners and concave fillets where its
/// top and bottom edges flow into the screen edge, like a notch grown out of
/// the display. The fillets occupy their own `filletRadius` bands at the top
/// and bottom of the rect.
struct SideNotchRailShape: Shape {
    var cornerRadius: CGFloat
    var filletRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let fillet = max(0, min(filletRadius, rect.height / 4, rect.width / 2))
        let top = rect.minY + fillet
        let bottom = rect.maxY - fillet
        let radius = max(
            0,
            min(cornerRadius, (bottom - top) / 2, rect.width - fillet)
        )
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: top),
            tangent2End: CGPoint(x: rect.minX, y: top),
            radius: fillet
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: top),
            tangent2End: CGPoint(x: rect.minX, y: bottom),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: bottom),
            tangent2End: CGPoint(x: rect.maxX, y: bottom),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: bottom),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: fillet
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The detail card's speech-bubble geometry. The tail spans the gap
/// between card and rail, so the card reads as speaking from the selected
/// row.
enum SideNotchBubbleTokens {
    static let cornerRadius: CGFloat = 16
    static let tailLength: CGFloat = SideNotchPanelLayout.detailSpacing
    static let tailHalfHeight: CGFloat = 10
    static let tailTipRadius: CGFloat = 1.5

    /// Tail center in card coordinates: on the row's center, but never
    /// into the rounded corners.
    static func tailCenterY(
        rowMidY: CGFloat,
        cardTop: CGFloat,
        cardHeight: CGFloat
    ) -> CGFloat {
        let lowest = cornerRadius + tailHalfHeight
        let highest = cardHeight - cornerRadius - tailHalfHeight
        guard highest >= lowest else { return cardHeight / 2 }
        return min(max(rowMidY - cardTop, lowest), highest)
    }
}

/// A rounded card with a soft tail on its trailing edge. The tail is drawn
/// outside `rect`, into the gap toward the rail.
struct SideNotchBubbleShape: Shape {
    var cornerRadius: CGFloat
    var tailCenterY: CGFloat?
    var tailHalfHeight: CGFloat
    var tailLength: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: radius
        )
        let lowest = rect.minY + radius + tailHalfHeight
        let highest = rect.maxY - radius - tailHalfHeight
        if let tailCenterY, highest >= lowest {
            let center = min(max(rect.minY + tailCenterY, lowest), highest)
            let tipX = rect.maxX + tailLength
            let tip = SideNotchBubbleTokens.tailTipRadius
            path.addLine(
                to: CGPoint(x: rect.maxX, y: center - tailHalfHeight)
            )
            path.addLine(to: CGPoint(x: tipX - tip, y: center - tip))
            path.addQuadCurve(
                to: CGPoint(x: tipX - tip, y: center + tip),
                control: CGPoint(x: tipX, y: center)
            )
            path.addLine(
                to: CGPoint(x: rect.maxX, y: center + tailHalfHeight)
            )
        }
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: radius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: radius
        )
        path.closeSubpath()
        return path
    }
}
