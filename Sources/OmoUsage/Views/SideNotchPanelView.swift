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

                    HStack(
                        alignment: .top,
                        spacing: SideNotchPanelLayout.detailSpacing
                    ) {
                        if let usage = selectedUsage {
                            SideNotchDetailView(
                                usage: usage,
                                showsAccountLabel:
                                    DashboardAccountIdentityRule.showsAlias(
                                        for: usage,
                                        sameProviderCount:
                                            viewModel.snapshot.providers.count {
                                                $0.provider == usage.provider
                                            }
                                    )
                            )
                                .frame(
                                    width:
                                        SideNotchPanelLayout.detailWidth
                                )
                                .padding(
                                    .top,
                                    detailTop(in: geometry.size.height)
                                )
                                .transition(.opacity)
                        }

                        SideNotchRailView(
                            providers: viewModel.snapshot.providers,
                            selectedTarget: state.selectedTarget,
                            isRefreshing: viewModel.isRefreshing,
                            onSelect: { target in
                                onSelectionIntent(.commit(target), true)
                            },
                            onHoverTarget: { target in
                                onSelectionIntent(.hover(target), true)
                            },
                            onKeyboardFocusTarget:
                                onKeyboardFocusTarget,
                            onRefresh: onRefresh,
                            onSettings: onSettings,
                            onQuit: onQuit
                        )
                        .frame(
                            width:
                                SideNotchPanelLayout.collapsedWidth
                        )
                        .frame(maxHeight: .infinity)
                    }
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .trailing
                    )
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .trailing
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

    private func detailTop(in containerHeight: CGFloat) -> CGFloat {
        guard
            let target = state.selectedTarget,
            let index = viewModel.snapshot.providers.firstIndex(
                where: { $0.accountProviderID == target }
            )
        else {
            return SideNotchPanelLayout.detailCardMargin
        }
        let rowCenter = SideNotchPanelLayout.detailCardMargin
            + CGFloat(index) * SideNotchPanelLayout.providerRowHeight
            + SideNotchPanelLayout.providerRowHeight / 2
        let desiredTop = rowCenter - 24
        let maximumTop = max(
            SideNotchPanelLayout.detailCardMargin,
            containerHeight
                - SideNotchPanelLayout.detailHeight(
                    for: viewModel.snapshot.providers[index]
                )
                - SideNotchPanelLayout.detailCardMargin
        )
        return min(
            max(SideNotchPanelLayout.detailCardMargin, desiredTop),
            maximumTop
        )
    }

    private var selectedUsage: ProviderUsage? {
        guard let target = state.selectedTarget else {
            return nil
        }
        return viewModel.snapshot.providers.first {
            $0.accountProviderID == target
        }
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
            let screenPoint = window.convertPoint(
                toScreen: event.locationInWindow
            )
            guard !window.frame.contains(screenPoint) else {
                return
            }
            onExited()
        }
    }
}

private struct SideNotchRailView: View {
    let providers: [ProviderUsage]
    let selectedTarget: AccountProviderID?
    let isRefreshing: Bool
    let onSelect: (AccountProviderID) -> Void
    let onHoverTarget: (AccountProviderID) -> Void
    let onKeyboardFocusTarget: (AccountProviderID) -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.appLocalization)
    private var localization
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        let providerCounts = Dictionary(
            grouping: providers,
            by: \.provider
        ).mapValues(\.count)
        VStack(spacing: 0) {
            if providers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.system(size: 22, weight: .medium))
                    Text(localization.text(.checking))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
                .accessibilityElement(children: .combine)
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
                                isSelected:
                                    selectedTarget
                                    == usage.accountProviderID,
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
                        }
                    }
                    .padding(.vertical, 7)
                }
                .scrollIndicators(.hidden)
            }

            VStack(spacing: 2) {
                refreshButton

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
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(localization.text(.settings))
                .accessibilityLabel(localization.text(.settings))
            }
            .frame(height: SideNotchPanelLayout.footerHeight)
            .padding(.top, SideNotchPanelLayout.footerClearance)
            .overlay(alignment: .top) {
                Divider()
            }
        }
        .background(
            .regularMaterial,
            in: UnevenRoundedRectangle(
                topLeadingRadius: SideNotchPanelLayout.railCornerRadius,
                bottomLeadingRadius: SideNotchPanelLayout.railCornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: SideNotchPanelLayout.railCornerRadius,
                bottomLeadingRadius: SideNotchPanelLayout.railCornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
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
            SideNotchSpinningRefreshButton(
                accessibilityLabel: localization.text(.refresh)
            )
        } else {
            InteractiveIconButton(
                symbol: "arrow.clockwise",
                accessibilityLabel: localization.text(.refresh),
                isActive: isRefreshing,
                isDisabled: isRefreshing,
                dimsWhenDisabled: false,
                hitTargetSize: 28,
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

private struct SideNotchSpinningRefreshButton: View {
    let accessibilityLabel: String
    @State private var rotation = 0.0

    var body: some View {
        InteractiveIconButton(
            symbol: "arrow.clockwise",
            accessibilityLabel: accessibilityLabel,
            isActive: true,
            isDisabled: true,
            dimsWhenDisabled: false,
            hitTargetSize: 28,
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
    let isSelected: Bool
    let action: () -> Void
    let onHoverTarget: () -> Void
    let onKeyboardFocus: () -> Void

    @Environment(\.appLocalization)
    private var localization
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @FocusState private var isKeyboardFocused: Bool
    @State private var isHovered = false
    @State private var hasRequestedHoverPreview = false

    var body: some View {
        let accountLabel = AccountLabel.sanitized(usage.accountLabel)
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(
                            Color.primary.opacity(
                                UsageMeterVisualTokens.trackOpacity
                            ),
                            lineWidth: 4
                        )
                    Circle()
                        .trim(
                            from: 0,
                            to: Double(summaryMeter.percentRemaining) / 100
                        )
                        .stroke(
                            UsageMeterVisualTokens.fillRGB(
                                for: summaryMeter.period
                            ).color,
                            style: StrokeStyle(
                                lineWidth: 4,
                                lineCap: .round
                            )
                        )
                        .rotationEffect(.degrees(-90))

                    ProviderIcon(provider: usage.provider)
                        .frame(
                            width: SideNotchPanelLayout.providerIconSize,
                            height: SideNotchPanelLayout.providerIconSize
                        )

                    if
                        showsAccountLabel,
                        let badge = SideNotchAccountIdentity.badgeText(
                            for: accountLabel
                        )
                    {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 14, height: 14)
                            .background(.regularMaterial, in: Circle())
                            .overlay {
                                Circle()
                                    .stroke(
                                        Color(nsColor: .separatorColor),
                                        lineWidth: 0.5
                                    )
                            }
                            .offset(x: 14, y: 14)
                    }

                    if SideNotchFreshnessPolicy.showsFailureMarker(
                        for: usage
                    ) {
                        Image(
                            systemName: StaleUsageVisualTokens.symbolName
                        )
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(
                                StaleUsageVisualTokens.accent.color
                            )
                            .background(.regularMaterial, in: Circle())
                            .offset(x: 14, y: -14)
                    }
                }
                .frame(
                    width: SideNotchPanelLayout.ringDiameter,
                    height: SideNotchPanelLayout.ringDiameter
                )

                Text("\(summaryMeter.percentRemaining)%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Color.primary.opacity(
                    isSelected ? 0.14 : isHovered ? 0.08 : 0
                ),
                in: RoundedRectangle(
                    cornerRadius: 16,
                    style: .continuous
                )
            )
            .overlay {
                if isSelected || isHovered {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .stroke(
                        Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1 : 0.5
                    )
                }
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable()
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
                withAnimation(
                    reduceMotion ? nil : .easeOut(duration: 0.12)
                ) {
                    isHovered = true
                }
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
                withAnimation(
                    reduceMotion ? nil : .easeOut(duration: 0.12)
                ) {
                    isHovered = false
                }
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

    private var summaryMeter: UsageMeter {
        let meters = usage.groups.flatMap(\.meters)
        return meters.first(where: { $0.period != .extra })
            ?? meters.first
            ?? UsageMeter(
                id: "unavailable",
                title: "",
                period: .session,
                percentRemaining: 0
            )
    }

    private var accessibilityValue: String {
        let value = "\(usage.provider.displayName), "
            + localization.format(
                .remaining,
                summaryMeter.percentRemaining
            )
        guard usage.freshness == .stale else { return value }
        return "\(value), \(localization.staleBadgeText())"
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

private struct SideNotchDetailView: View {
    let usage: ProviderUsage
    let showsAccountLabel: Bool

    var body: some View {
        ScrollView {
            ProviderSectionView(
                usage: usage,
                showsAccountLabel: showsAccountLabel
            )
                .padding(SideNotchPanelLayout.detailContentPadding)
        }
        .scrollIndicators(.hidden)
        .frame(height: SideNotchPanelLayout.detailHeight(for: usage))
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 16,
                style: .continuous
            )
            .stroke(
                Color(nsColor: .separatorColor),
                lineWidth: 0.5
            )
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
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
