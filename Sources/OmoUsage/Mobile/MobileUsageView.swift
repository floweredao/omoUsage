import OmoUsageCore
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
                    .accessibilityLabel(localization.text(.checkICloud))
                    .accessibilityHint(
                        localization.text(.mobileICloudCheckExplanation)
                    )
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
                if let freshness = viewModel.freshnessPresentation {
                    MobileSyncStatusHeader(freshness: freshness)
                }

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
                    MobileFreshnessBadge(
                        symbolName: StaleUsageVisualTokens.symbolName,
                        text: localization.staleBadgeText(),
                        accent: StaleUsageVisualTokens.accent
                    )
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

/// States what mobile actually knows: when the Mac last checked, whether that
/// snapshot has aged out, whether the last iCloud read failed, and that a pull
/// only re-reads iCloud.
private struct MobileSyncStatusHeader: View {
    let freshness: MobileFreshnessPresentation
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        let clockText = MobileClockText.string(
            from: freshness.macLastCheckedAt
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(
                    systemName: freshness.hasSyncIssue
                        ? "exclamationmark.icloud"
                        : "icloud.fill"
                )
                Text(localization.text(.syncedThroughICloud))
                Spacer(minLength: 0)
                Text(
                    freshness.statusText(
                        localization,
                        clockText: clockText
                    )
                )
            }
            .font(.footnote.weight(.medium))

            if freshness.isStale {
                MobileFreshnessBadge(
                    symbolName: MobileFreshnessVisualTokens.symbolName,
                    text: localization.snapshotAgeBadgeText(),
                    accent: MobileFreshnessVisualTokens.accent
                )
            }

            if freshness.hasSyncIssue {
                Text(localization.text(.mobileRetainedAfterSyncFailure))
                    .font(.caption)
            }

            Text(localization.text(.mobileICloudCheckExplanation))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            freshness.accessibilityLabel(
                localization,
                clockText: clockText
            )
        )
        .accessibilityHint(
            localization.text(.mobileICloudCheckExplanation)
        )
    }
}

/// One badge primitive for both freshness facts, so retained provider usage
/// and an aged-out snapshot share spacing, shape, and accent tokens while
/// keeping distinct symbols and text.
private struct MobileFreshnessBadge: View {
    let symbolName: String
    let text: String
    let accent: VisualRGB

    var body: some View {
        HStack(spacing: StaleUsageVisualTokens.badgeSpacing) {
            Image(systemName: symbolName)
                .imageScale(.small)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(accent.color)
        .padding(
            .horizontal,
            StaleUsageVisualTokens.badgeHorizontalPadding
        )
        .padding(.vertical, StaleUsageVisualTokens.badgeVerticalPadding)
        .background(
            accent.color.opacity(
                StaleUsageVisualTokens.badgeBackgroundOpacity
            ),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    accent.color.opacity(
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

            switch meter.metric.kind {
            case .quotaRemaining:
                if let fraction = meter.metric.progressFraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.16))
                            Capsule()
                                .fill(meterColor)
                                .frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(height: 6)
                }
            case .spend, .credit, .count, .informational:
                EmptyView()
            }

            if meter.resetText != nil || meter.resetsAt != nil {
                Text(resetDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            localization.metricAccessibilityLabel(
                title: meter.title,
                metric: meter.metric
            ) + resetAccessibilitySuffix
        )
    }

    private var meterTitle: some View {
        Text(localization.providerText(meter.title))
            .font(.subheadline.weight(.medium))
    }

    private var remainingValue: some View {
        Text(localization.metricValue(meter.metric))
            .font(.subheadline.weight(.semibold))
    }

    private var resetAccessibilitySuffix: String {
        meter.resetText != nil || meter.resetsAt != nil
            ? ", \(resetDescription)"
            : ""
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
        return localization.resetDescription(until: resetsAt)
    }
}
#endif
