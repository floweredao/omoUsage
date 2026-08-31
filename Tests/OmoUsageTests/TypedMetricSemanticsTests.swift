import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct TypedMetricSemanticsTests {
    @Test
    func modelsAllFiveMetricKindsWithoutPercentageCoercion() throws {
        let metrics: [UsageMetric] = [
            .quotaRemaining(percent: 72),
            .spend(amount: 3, currency: .usd),
            .credit(balance: 12, unit: .credits),
            .count(value: 500, unit: .requests),
            .informational(value: "Plan renews manually")
        ]

        #expect(metrics.map(\.kind) == [
            .quotaRemaining, .spend, .credit, .count, .informational
        ])
        #expect(metrics.map(\.progressFraction) == [0.72, nil, nil, nil, nil])
    }

    @Test
    func rejectsValuesOutsideStrictSemanticAllowlistsAndBounds() {
        #expect(UsageMetric.quotaRemaining(validating: -1) == nil)
        #expect(UsageMetric.quotaRemaining(validating: 101) == nil)
        #expect(UsageMetric.spend(validating: -.infinity, currency: .usd) == nil)
        #expect(UsageMetric.credit(validating: -1, unit: .credits) == nil)
        #expect(UsageMetric.count(validating: -1, unit: .requests) == nil)
        #expect(UsageMetric.informational(validating: "") == nil)
        #expect(UsageCurrency.allCases == [.usd])
        #expect(Set(UsageMetricUnit.allCases) == [.usd, .credits, .requests, .tokens, .tickets])
    }

    @Test
    func codecRoundTripsTypedMetricsAndUsesVersionFour() throws {
        let now = Date(timeIntervalSince1970: 1_786_867_200)
        let expected = DashboardSnapshot(
            providers: [
                ProviderUsage(
                    provider: .openrouter,
                    planName: "Paid",
                    groups: [
                        UsageGroup(
                            id: "typed",
                            title: nil,
                            meters: typedMeters,
                            creditText: nil
                        )
                    ],
                    availability: .available,
                    updatedAt: now
                )
            ],
            refreshedAt: now
        )

        let data = try UsageSnapshotCodec.encode(expected)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["version"] as? Int == 4)
        #expect(try UsageSnapshotCodec.decode(data) == expected)
    }

    @Test
    func persistedVersionsOneThroughThreeMapLegacyMetersToQuota() throws {
        for version in 1...3 {
            let timestamp = version == 3
                ? #""generatedAt":1786867200000,"lastRefreshAttemptAt":1786867200000,"oldestDisplayedSuccessAt":null"#
                : #""refreshedAt":1786867200000"#
            let account = version == 3
                ? #""accountOrdinal":1,"lastSuccessfulAt":null,"lastRefreshAttemptAt":null,"refreshFailure":null"#
                : #""updatedAt":null"#
            let data = Data(
                """
                {"version":\(version),"providers":[{
                  "provider":"codex",\(account),"planName":"Plus",
                  "groups":[{"id":"limits","title":null,"meters":[{
                    "id":"session","title":"Session","period":"session",
                    "percentRemaining":72,"resetsAt":null,"resetText":null,
                    "showsMenuBarBadge":false
                  }],"creditText":null}],"availability":"available"
                }],\(timestamp)}
                """.utf8
            )

            let meter = try #require(
                UsageSnapshotCodec.decode(data).providers.first?
                    .groups.first?.meters.first
            )
            #expect(meter.metric == .quotaRemaining(percent: 72))
        }
    }

    private var typedMeters: [UsageMeter] {
        [
            UsageMeter(id: "quota", title: "Weekly", period: .week, metric: .quotaRemaining(percent: 72)),
            UsageMeter(id: "spend", title: "Last 30 days", period: .extra, metric: .spend(amount: 3, currency: .usd)),
            UsageMeter(id: "credit", title: "Balance", period: .extra, metric: .credit(balance: 12, unit: .credits)),
            UsageMeter(id: "count", title: "Requests", period: .extra, metric: .count(value: 500, unit: .requests)),
            UsageMeter(id: "info", title: "Billing", period: .extra, metric: .informational(value: "Manual renewal"))
        ]
    }
}
