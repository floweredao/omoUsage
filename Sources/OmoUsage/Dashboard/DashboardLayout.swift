import OmoUsageCore
import CoreGraphics
import Foundation

enum DashboardLayout {
    static let maximumPanelHeight: CGFloat = 632
    static let footerHeight: CGFloat = 44
    static let contentBottomPadding: CGFloat = 8
    private static let meterValueRowHeight: CGFloat = 15
    private static let meterQuotaTrackHeight: CGFloat = 7
    private static let meterResetRowHeight: CGFloat = 16
    private static let metadataRowHeight: CGFloat = 16

    static func panelHeight(
        for providers: [ProviderUsage]
    ) -> CGFloat {
        let separators = CGFloat(max(0, providers.count - 1)) * 21
        let sections = providers.reduce(CGFloat.zero) {
            $0 + sectionHeight($1)
        }
        let listHeight = 12
            + sections
            + separators
            + contentBottomPadding
        return min(
            maximumPanelHeight,
            max(150, listHeight + footerHeight)
        )
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
