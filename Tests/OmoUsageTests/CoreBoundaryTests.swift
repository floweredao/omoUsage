import Foundation
import Testing
import OmoUsageCore

@Suite
struct CoreBoundaryTests {
    @Test
    func publicConsumerRoundTripsSchemaV4TypedMetricsAndFreshness() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_786_867_200)
        let successAt = checkedAt.addingTimeInterval(-3_600)
        let expected = DashboardSnapshot(
            providers: [
                ProviderUsage(
                    provider: .openrouter,
                    planName: "Pro",
                    groups: [
                        UsageGroup(
                            id: "typed",
                            title: nil,
                            meters: [
                                UsageMeter(
                                    id: "spend",
                                    title: "Last 30 days",
                                    period: .extra,
                                    metric: .spend(amount: 3, currency: .usd)
                                )
                            ],
                            creditText: nil
                        )
                    ],
                    availability: .available,
                    lastSuccessfulAt: successAt,
                    lastRefreshAttemptAt: checkedAt,
                    refreshFailure: .network
                )
            ],
            generatedAt: checkedAt,
            lastRefreshAttemptAt: checkedAt,
            oldestDisplayedSuccessAt: successAt
        )

        let encoded = try UsageSnapshotCodec.encode(expected)
        let decoded = try UsageSnapshotCodec.decode(encoded)
        let presentation = MobileFreshnessPresentation(
            snapshot: decoded,
            now: checkedAt.addingTimeInterval(15 * 60),
            hasSyncIssue: false
        )

        #expect(UsageSnapshotCodec.currentVersion == 4)
        #expect(decoded == expected)
        #expect(decoded.providers[0].groups[0].meters[0].metric.kind == .spend)
        #expect(decoded.providers[0].freshness == .stale)
        #expect(presentation.age == .stale)
    }
}
