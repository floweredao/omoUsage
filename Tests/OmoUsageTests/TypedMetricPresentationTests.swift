import Foundation
import Testing
@testable import OmoUsage

@Suite
@MainActor
struct TypedMetricPresentationTests {
    @Test
    func onlyQuotaUsesRemainingLanguageAndProgress() {
        let localization = LocalizationContext(language: .english)
        let cases: [(UsageMetric, String, Bool)] = [
            (.quotaRemaining(percent: 72), "72% remaining", true),
            (.spend(amount: 3, currency: .usd), "$3.00 spent", false),
            (.credit(balance: 12, unit: .credits), "12 credits balance", false),
            (.credit(balance: 75, unit: .usd), "$75.00 balance", false),
            (.count(value: 500, unit: .requests), "500 requests", false),
            (.informational(value: "Manual renewal"), "Manual renewal", false)
        ]

        for (metric, expected, showsProgress) in cases {
            #expect(localization.metricValue(metric) == expected)
            #expect(metric.presentation.showsProgress == showsProgress)
            if metric.kind != .quotaRemaining {
                #expect(!localization.metricValue(metric).contains("%"))
                #expect(!localization.metricValue(metric).contains("remaining"))
            }
        }
    }

    @Test
    func voiceOverLabelsStateEachMetricSemantics() {
        let localization = LocalizationContext(language: .english)
        let labels = [
            localization.metricAccessibilityLabel(
                title: "Weekly",
                metric: .quotaRemaining(percent: 72)
            ),
            localization.metricAccessibilityLabel(
                title: "Last 30 days",
                metric: .spend(amount: 3, currency: .usd)
            ),
            localization.metricAccessibilityLabel(
                title: "Balance",
                metric: .credit(balance: 12, unit: .credits)
            ),
            localization.metricAccessibilityLabel(
                title: "Requests",
                metric: .count(value: 500, unit: .requests)
            ),
            localization.metricAccessibilityLabel(
                title: "Billing",
                metric: .informational(value: "Manual renewal")
            )
        ]

        #expect(labels == [
            "Weekly, 72% remaining",
            "Last 30 days, $3.00 spent",
            "Balance, 12 credits balance",
            "Requests, 500 requests",
            "Billing, Manual renewal"
        ])
    }

    @Test
    func sideNotchRailKeepsQuotaCompactWithoutChangingOtherSemantics() {
        #expect(
            SideNotchMetricPresentation.compactValue(
                for: .quotaRemaining(percent: 72),
                localizedValue: "72% remaining"
            ) == "72%"
        )
        #expect(
            SideNotchMetricPresentation.compactValue(
                for: .credit(balance: 12, unit: .credits),
                localizedValue: "12 credits balance"
            ) == "12 credits balance"
        )
    }

    @Test
    func everyShippedSurfaceBranchesOnMetricKind() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "Sources/OmoUsage/Views/UsageMeterView.swift",
            "Sources/OmoUsage/Views/SideNotchPanelView.swift",
            "Sources/OmoUsage/Mobile/MobileUsageView.swift",
            "Sources/OmoUsage/Resources/WebDashboard/index.html"
        ]

        for path in paths {
            let source = try String(
                contentsOf: root.appending(path: path),
                encoding: .utf8
            )
            #expect(source.contains("metric.kind"), Comment(rawValue: path))
        }
    }
}
