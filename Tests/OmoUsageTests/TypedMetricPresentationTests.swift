import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

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

        let unitedStates = Locale(identifier: "en_US")
        for (metric, expected, showsProgress) in cases {
            #expect(
                localization.metricValue(
                    metric,
                    regionalPreferences: unitedStates
                ) == expected
            )
            #expect(metric.presentation.showsProgress == showsProgress)
            if metric.kind != .quotaRemaining {
                #expect(!localization.metricValue(metric).contains("%"))
                #expect(!localization.metricValue(metric).contains("remaining"))
            }
        }
    }

    @Test(arguments: [
        (AppLanguage.english, "en_US", "$1,234.50 spent"),
        (AppLanguage.english, "en_GB", "US$1,234.50 spent"),
        (AppLanguage.english, "de_DE", "1.234,50 US$ spent"),
        (AppLanguage.korean, "ko_KR", "US$1,234.50 사용"),
        (AppLanguage.korean, "en_US", "$1,234.50 사용")
    ])
    func moneyFollowsTheRegionNotTheDisplayLanguage(
        language: AppLanguage,
        region: String,
        expected: String
    ) {
        let localization = LocalizationContext(language: language)
        #expect(
            localization.metricValue(
                .spend(amount: 1_234.5, currency: .usd),
                regionalPreferences: Locale(identifier: region)
            ) == expected
        )
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
    func sideNotchRailShowsTheLowerOfSessionAndWeeklyQuota() {
        let weekly = UsageMeter(
            id: "claude.week",
            title: "Weekly",
            period: .week,
            percentRemaining: 91
        )
        let session = UsageMeter(
            id: "claude.session",
            title: "Session (5 hours)",
            period: .session,
            percentRemaining: 63
        )
        let tiedWeekly = UsageMeter(
            id: "claude.week",
            title: "Weekly",
            period: .week,
            percentRemaining: 63
        )

        #expect(
            SideNotchSummaryMeterPolicy.select(from: [weekly, session])?.id
                == "claude.session"
        )
        #expect(
            SideNotchSummaryMeterPolicy.select(from: [tiedWeekly, session])?.id
                == "claude.session"
        )
    }

    @Test
    func sideNotchRailShowsExhaustedWeeklyOverFullSession() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": 0},
                  "seven_day": {"utilization": 100}
                }
                """.utf8
            ),
            planName: "Max",
            now: Date(timeIntervalSince1970: 1_785_675_000)
        )
        let selected = SideNotchSummaryMeterPolicy.select(
            from: usage.groups.flatMap(\.meters)
        )

        #expect(selected?.id == "claude.week")
        #expect(selected?.percentRemaining == 0)
        #expect(SideNotchUsageRisk.level(for: try #require(selected).metric) == .critical)
    }

    @Test
    func sideNotchRailIgnoresExhaustedModelWeeklyQuota() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": 40},
                  "seven_day": {"utilization": 10},
                  "limits": [
                    {
                      "kind": "weekly_scoped",
                      "group": "weekly",
                      "percent": 100,
                      "scope": {"model": {"id": null, "display_name": "Fable"}}
                    }
                  ]
                }
                """.utf8
            ),
            planName: "Max",
            now: Date(timeIntervalSince1970: 1_785_675_000)
        )
        let meters = usage.groups.flatMap(\.meters)
        let fable = try #require(meters.first {
            SideNotchSummaryMeterPolicy.isModelScoped($0)
        })

        #expect(fable.percentRemaining == 0)
        #expect(
            SideNotchSummaryMeterPolicy.select(from: meters)?.id
                == "claude.session"
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
