import OmoUsageCore
import CoreGraphics
import Foundation

enum DashboardLayout {
    static let maximumPanelHeight: CGFloat = 632
    static let footerHeight: CGFloat = 44
    static let contentBottomPadding: CGFloat = 8

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
        _ usage: ProviderUsage
    ) -> CGFloat {
        let freshness = freshnessDisplay(for: usage)
        var children: [CGFloat] = [20]
        if freshness.showsStaleBadge {
            children.append(StaleUsageVisualTokens.badgeRowHeight)
        }
        children.append(
            contentsOf: usage.groups.map(groupHeight)
        )
        children.append(
            contentsOf: repeatElement(
                CGFloat(14),
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
            contentsOf: repeatElement(
                CGFloat(40),
                count: group.meters.count
            )
        )
        if group.creditText != nil {
            children.append(15)
        }
        return children.reduce(0, +)
            + CGFloat(max(0, children.count - 1)) * 7
    }
}
