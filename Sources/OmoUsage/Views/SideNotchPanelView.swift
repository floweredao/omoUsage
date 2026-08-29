import SwiftUI

struct SideNotchPanelView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    let localization: LocalizationController
    @Bindable var state: SideNotchPanelState
    let onSelectionChange: (ProviderID?, Bool) -> Void
    let onProviderCountChange: (Int) -> Void
    let onPointerEntered: () -> Void
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
                        onReveal: onPointerEntered
                    )
                    .frame(width: SideNotchPanelLayout.hiddenWidth)
                    .frame(maxHeight: .infinity)
                } else if state.selectedProvider != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectionChange(nil, !reduceMotion)
                        }
                }

                if state.mode != .hidden {
                    HStack(
                        alignment: .top,
                        spacing: SideNotchPanelLayout.detailSpacing
                    ) {
                        if let usage = selectedUsage {
                            SideNotchDetailView(usage: usage)
                                .frame(
                                    width:
                                        SideNotchPanelLayout.detailWidth
                                )
                                .padding(
                                    .top,
                                    detailTop(in: geometry.size.height)
                                )
                                .transition(
                                    .asymmetric(
                                        insertion: .opacity.combined(
                                            with: .move(edge: .trailing)
                                        ),
                                        removal: .opacity
                                    )
                                )
                        }

                        SideNotchRailView(
                            providers: viewModel.snapshot.providers,
                            selectedProvider: state.selectedProvider,
                            isRefreshing: viewModel.isRefreshing,
                            onSelect: { provider in
                                let selection =
                                    state.selectedProvider == provider
                                        ? nil
                                        : provider
                                onSelectionChange(selection, true)
                            },
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
                onEntered: onPointerEntered,
                onExited: onPointerExited
            )
        }
        .environment(\.appLocalization, localization.context)
        .onChange(
            of: viewModel.snapshot.providers,
            initial: true
        ) { _, providers in
            onProviderCountChange(providers.count)
            guard
                let selectedProvider = state.selectedProvider,
                !providers.contains(where: {
                    $0.provider == selectedProvider
                })
            else {
                return
            }
            onSelectionChange(nil, false)
        }
        .onExitCommand {
            onSelectionChange(nil, !reduceMotion)
        }
    }

    private func detailTop(in containerHeight: CGFloat) -> CGFloat {
        guard
            let selectedProvider = state.selectedProvider,
            let index = viewModel.snapshot.providers.firstIndex(
                where: { $0.provider == selectedProvider }
            )
        else {
            return 12
        }
        let rowCenter = 12
            + CGFloat(index) * SideNotchPanelLayout.providerRowHeight
            + SideNotchPanelLayout.providerRowHeight / 2
        let desiredTop = rowCenter - 24
        let maximumTop = max(
            12,
            containerHeight
                - SideNotchPanelLayout.detailHeight(
                    for: viewModel.snapshot.providers[index]
                )
                - 12
        )
        return min(max(12, desiredTop), maximumTop)
    }

    private var selectedUsage: ProviderUsage? {
        guard let provider = state.selectedProvider else {
            return nil
        }
        return viewModel.snapshot.providers.first {
            $0.provider == provider
        }
    }
}

private struct SideNotchHiddenHandleView: View {
    let onReveal: () -> Void
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.primary.opacity(0.24))
            .frame(width: 4, height: 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let onEntered: () -> Void
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
        var onEntered: () -> Void
        var onExited: () -> Void
        private var trackingArea: NSTrackingArea?

        init(
            onEntered: @escaping () -> Void,
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
            onEntered()
        }

        override func mouseExited(with event: NSEvent) {
            onExited()
        }
    }
}

private struct SideNotchRailView: View {
    let providers: [ProviderUsage]
    let selectedProvider: ProviderID?
    let isRefreshing: Bool
    let onSelect: (ProviderID) -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.appLocalization)
    private var localization
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
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
                        ForEach(providers) { usage in
                            SideNotchProviderButton(
                                usage: usage,
                                isSelected:
                                    selectedProvider == usage.provider,
                                action: {
                                    onSelect(usage.provider)
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
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appLocalization)
    private var localization
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @State private var isHovered = false

    var body: some View {
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

                    if usage.availability == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering in
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.12)
            ) {
                isHovered = hovering
            }
        }
        .help(accessibilityValue)
        .accessibilityLabel(usage.provider.displayName)
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
        "\(usage.provider.displayName), "
            + localization.format(
                .remaining,
                summaryMeter.percentRemaining
            )
    }
}

private struct SideNotchDetailView: View {
    let usage: ProviderUsage

    var body: some View {
        ScrollView {
            ProviderSectionView(usage: usage)
                .padding(14)
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
