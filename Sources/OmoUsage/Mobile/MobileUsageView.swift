#if os(iOS)
import SwiftUI

struct MobileUsageView: View {
    @Bindable var viewModel: MobileUsageViewModel
    let localization: LocalizationController

    var body: some View {
        NavigationStack {
            Group {
                if
                    let snapshot = viewModel.snapshot,
                    !snapshot.providers.isEmpty
                {
                    usageContent(snapshot)
                } else {
                    stateContent
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(localization.text(.aiUsage))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.reload()
                    } label: {
                        if viewModel.loadState == .loading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel(localization.text(.refresh))
                    .disabled(viewModel.loadState == .loading)
                }
            }
        }
        .environment(\.appLocalization, localization.context)
        .task {
            viewModel.reload()
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView(localization.text(.inProgress))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label(
                    localization.text(.mobileNoDataTitle),
                    systemImage: "icloud.slash"
                )
            } description: {
                Text(localization.text(.mobileNoDataDescription))
            } actions: {
                Button(localization.text(.retry)) {
                    viewModel.reload()
                }
                .buttonStyle(.borderedProminent)
            }
        case .failed:
            ContentUnavailableView {
                Label(
                    localization.text(.mobileSyncFailed),
                    systemImage: "exclamationmark.icloud"
                )
            } actions: {
                Button(localization.text(.retry)) {
                    viewModel.reload()
                }
                .buttonStyle(.borderedProminent)
            }
        case .content:
            EmptyView()
        }
    }

    private func usageContent(
        _ snapshot: DashboardSnapshot
    ) -> some View {
        let providerCounts = Dictionary(
            grouping: snapshot.providers,
            by: \.provider
        ).mapValues(\.count)
        return ScrollView {
            LazyVStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(
                        systemName: viewModel.loadState == .failed
                            ? "exclamationmark.icloud"
                            : "icloud.fill"
                    )
                    Text(
                        localization.text(
                            viewModel.loadState == .failed
                                ? .mobileSyncFailed
                                : .syncedThroughICloud
                        )
                    )
                    Spacer()
                    Text(
                        snapshot.refreshedAt,
                        format: .dateTime
                            .hour()
                            .minute()
                    )
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)

                ForEach(snapshot.providers) { usage in
                    MobileProviderCard(
                        usage: usage,
                        showsAccountLabel:
                            DashboardAccountIdentityRule.showsAlias(
                                for: usage,
                                sameProviderCount: providerCounts[
                                    usage.provider,
                                    default: 0
                                ]
                            )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            viewModel.reload()
        }
    }
}

private struct MobileProviderCard: View {
    let usage: ProviderUsage
    let showsAccountLabel: Bool
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        let iconStyle = ProviderVisualStyle.style(for: usage.provider)
        let freshness = ProviderFreshnessDisplay.make(
            for: usage,
            includesSuccessRow: false
        )
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(usage.provider.monogram)
                    .font(.subheadline.weight(.bold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(iconStyle.foreground)
                    .background(
                        iconStyle.background,
                        in: RoundedRectangle(
                            cornerRadius: 8,
                            style: .continuous
                        )
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(usage.provider.displayName)
                        .font(.headline)

                    if showsAccountLabel {
                        Text(AccountLabel.sanitized(usage.accountLabel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if !usage.planName.isEmpty {
                        Text(usage.planName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Color.primary.opacity(0.06),
                                in: Capsule()
                            )
                    }
                }

                Spacer(minLength: 0)

                if freshness.showsStaleBadge {
                    MobileStaleUsageBadge()
                }
            }

            ForEach(usage.groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    if let title = group.title {
                        Text(localization.providerText(title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(group.meters) { meter in
                        MobileUsageMeter(meter: meter)
                    }

                    if let creditText = group.creditText {
                        Text(localization.providerText(creditText))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if freshness.rowCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    if let successAt = freshness.successAt {
                        Text(
                            localization.format(
                                .asOf,
                                MobileClockText.string(from: successAt)
                            )
                        )
                    }
                    if let attemptAt = freshness.attemptAt {
                        Text(
                            localization.format(
                                .lastRefreshAttempt,
                                MobileClockText.string(from: attemptAt)
                            )
                        )
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct MobileStaleUsageBadge: View {
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        HStack(spacing: StaleUsageVisualTokens.badgeSpacing) {
            Image(systemName: StaleUsageVisualTokens.symbolName)
                .imageScale(.small)
            Text(localization.staleBadgeText())
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(StaleUsageVisualTokens.accent.color)
        .padding(
            .horizontal,
            StaleUsageVisualTokens.badgeHorizontalPadding
        )
        .padding(.vertical, StaleUsageVisualTokens.badgeVerticalPadding)
        .background(
            StaleUsageVisualTokens.accent.color.opacity(
                StaleUsageVisualTokens.badgeBackgroundOpacity
            ),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    StaleUsageVisualTokens.accent.color.opacity(
                        StaleUsageVisualTokens.badgeBorderOpacity
                    ),
                    lineWidth: 0.5
                )
        }
        .accessibilityElement(children: .combine)
    }
}

enum MobileClockText {
    static func string(from date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

private struct MobileUsageMeter: View {
    let meter: UsageMeter
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    meterTitle
                    Spacer()
                    remainingValue
                }
                VStack(alignment: .leading, spacing: 2) {
                    meterTitle
                    remainingValue
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.16))
                    Capsule()
                        .fill(meterColor)
                        .frame(
                            width: geometry.size.width
                                * Double(meter.percentRemaining) / 100
                        )
                }
            }
            .frame(height: 6)

            Text(resetDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(localization.providerText(meter.title)), "
                + "\(localization.format(.remaining, meter.percentRemaining)), "
                + resetDescription
        )
    }

    private var meterTitle: some View {
        Text(localization.providerText(meter.title))
            .font(.subheadline.weight(.medium))
    }

    private var remainingValue: some View {
        Text(
            localization.format(
                .remaining,
                meter.percentRemaining
            )
        )
        .font(.subheadline.weight(.semibold))
    }

    private var meterColor: Color {
        if meter.period == .extra {
            return Color(red: 0xB7 / 255, green: 0x79 / 255, blue: 0x3F / 255)
        }
        return Color(red: 0x4C / 255, green: 0x85 / 255, blue: 0x77 / 255)
    }

    private var resetDescription: String {
        if let resetText = meter.resetText {
            return localization.providerText(resetText)
        }
        guard let resetsAt = meter.resetsAt else {
            return localization.text(.noResetInfo)
        }
        let seconds = max(0, Int(resetsAt.timeIntervalSinceNow))
        if seconds < 3_600 {
            return localization.format(
                .resetMinutes,
                max(1, seconds / 60)
            )
        }
        if seconds < 86_400 {
            return localization.format(
                .resetHoursMinutes,
                seconds / 3_600,
                seconds % 3_600 / 60
            )
        }
        return localization.format(.resetDays, seconds / 86_400)
    }
}
#endif
