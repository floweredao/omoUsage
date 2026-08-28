import SwiftUI

struct SideNotchPanelView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    let localization: LocalizationController
    @Bindable var state: SideNotchPanelState
    let onSelectionChange: (ProviderID?, Bool) -> Void
    let onProviderCountChange: (Int) -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if state.selectedProvider != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectionChange(nil, !reduceMotion)
                        }
                }

                HStack(alignment: .top, spacing: 8) {
                    if let usage = selectedUsage {
                        SideNotchDetailView(usage: usage)
                            .frame(width: 320)
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
                    .frame(width: SideNotchPanelLayout.collapsedWidth)
                    .frame(maxHeight: .infinity)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .trailing
                )
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .trailing
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
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 2) {
                InteractiveIconButton(
                    symbol: "arrow.clockwise",
                    accessibilityLabel: localization.text(.refresh),
                    isActive: isRefreshing,
                    isDisabled: isRefreshing,
                    dimsWhenDisabled: false,
                    action: onRefresh
                )
                .rotationEffect(
                    .degrees(
                        isRefreshing && !reduceMotion ? 360 : 0
                    )
                )
                .animation(
                    isRefreshing && !reduceMotion
                        ? .linear(duration: 0.7).repeatForever(
                            autoreverses: false
                        )
                        : nil,
                    value: isRefreshing
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
                        .frame(width: 32, height: 32)
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
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
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
                            Color.primary.opacity(0.12),
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
                        .frame(width: 26, height: 26)

                    if usage.availability == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.orange)
                            .background(.regularMaterial, in: Circle())
                            .offset(x: 14, y: -14)
                    }
                }
                .frame(width: 42, height: 42)

                Text("\(summaryMeter.percentRemaining)%")
                    .font(.system(size: 12, weight: .semibold))
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
        .padding(.horizontal, 8)
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
