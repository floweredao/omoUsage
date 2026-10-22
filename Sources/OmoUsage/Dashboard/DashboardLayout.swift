import OmoUsageCore
import CoreGraphics
import Foundation

enum DashboardLayout {
    static let panelWidth: CGFloat = 320
    static let maximumPanelHeight: CGFloat = 632
    /// Larger popover text sizes grow the panel only up to this height so it
    /// still fits a 13-inch display; the body scrolls beyond it.
    static let maximumScaledPanelHeight: CGFloat = 800
    static let footerHeight: CGFloat = 44
    static let contentBottomPadding: CGFloat = 8
    private static let meterValueRowHeight: CGFloat = 15
    private static let meterQuotaTrackHeight: CGFloat = 7
    private static let meterResetRowHeight: CGFloat = 16
    private static let metadataRowHeight: CGFloat = 16

    static func panelWidth(scale: CGFloat) -> CGFloat {
        panelWidth * scale
    }

    /// The popover scales every type, icon, and spacing value by the same
    /// factor, so its natural height scales linearly with it.
    static func panelHeight(
        for providers: [ProviderUsage],
        scale: CGFloat
    ) -> CGFloat {
        let height = panelHeight(for: providers)
        guard scale > 1 else { return height }
        let cap = max(
            maximumPanelHeight,
            min(maximumPanelHeight * scale, maximumScaledPanelHeight)
        )
        let natural = providers.isEmpty
            ? height
            : unclampedPanelHeight(for: providers)
        return min(cap, natural * scale)
    }

    static func panelHeight(
        for providers: [ProviderUsage]
    ) -> CGFloat {
        guard !providers.isEmpty else { return 190 }
        return min(
            maximumPanelHeight,
            unclampedPanelHeight(for: providers)
        )
    }

    private static func unclampedPanelHeight(
        for providers: [ProviderUsage]
    ) -> CGFloat {
        let providerCounts = Dictionary(grouping: providers, by: \.provider)
            .mapValues(\.count)
        let separators = CGFloat(max(0, providers.count - 1)) * 21
        let sections = providers.reduce(CGFloat.zero) {
            $0 + sectionHeight(
                $1,
                showsAccountLabel: DashboardAccountIdentityRule.showsAlias(
                    for: $1,
                    sameProviderCount: providerCounts[$1.provider, default: 0]
                )
            )
        }
        let listHeight = 12
            + sections
            + separators
            + contentBottomPadding
        return max(150, listHeight + footerHeight)
    }

    static func showsProviderTimestamp(
        for usage: ProviderUsage
    ) -> Bool {
        guard usage.updatedAt != nil else { return false }
        return !usage.groups
            .flatMap(\.meters)
            .contains { $0.period == .extra && $0.resetText != nil }
    }

    static func freshnessDisplay(
        for usage: ProviderUsage
    ) -> ProviderFreshnessDisplay {
        ProviderFreshnessDisplay.make(
            for: usage,
            includesSuccessRow: showsProviderTimestamp(for: usage)
        )
    }

    static func sectionHeight(
        _ usage: ProviderUsage,
        showsAccountLabel: Bool = false
    ) -> CGFloat {
        let freshness = freshnessDisplay(for: usage)
        let headerHeight: CGFloat = showsAccountLabel ? 33 : 20
        var children: [CGFloat] = [headerHeight]
        if freshness.showsStaleBadge {
            children.append(StaleUsageVisualTokens.badgeRowHeight)
        }
        children.append(
            contentsOf: usage.groups.map(groupHeight)
        )
        children.append(
            contentsOf: repeatElement(
                metadataRowHeight,
                count: freshness.rowCount
            )
        )
        return children.reduce(0, +)
            + CGFloat(max(0, children.count - 1)) * 8
    }

    private static func groupHeight(
        _ group: UsageGroup
    ) -> CGFloat {
        var children: [CGFloat] = []
        if group.title != nil {
            children.append(14)
        }
        children.append(
            contentsOf: group.meters.map(meterHeight)
        )
        if group.creditText != nil {
            children.append(15)
        }
        return children.reduce(0, +)
            + CGFloat(max(0, children.count - 1)) * 7
    }

    private static func meterHeight(
        _ meter: UsageMeter
    ) -> CGFloat {
        let trackHeight: CGFloat = switch meter.metric.kind {
        case .quotaRemaining:
            meter.metric.progressFraction == nil
                ? 0
                : meterQuotaTrackHeight
        case .spend, .credit, .count, .informational:
            0
        }
        let resetHeight =
            meter.resetText == nil && meter.resetsAt == nil
            ? 0
            : meterResetRowHeight
        return meterValueRowHeight + trackHeight + resetHeight
    }
}
