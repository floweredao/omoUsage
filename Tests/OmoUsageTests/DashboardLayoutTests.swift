import Foundation
import Testing
@testable import OmoUsage

@Suite
struct DashboardLayoutTests {
    @Test
    func shrinksForOneProviderAndCapsLargeRosters() {
        let one = usage(provider: .codex, meterCount: 1)
        #expect(DashboardLayout.panelHeight(for: [one]) < 300)

        let many = ProviderID.allCases.map {
            usage(provider: $0, meterCount: 3)
        }
        #expect(DashboardLayout.panelHeight(for: many) == 632)
    }

    @Test
    func codexTimestampUsesCompactSectionHeight() {
        let codex = usage(provider: .codex, meterCount: 1)

        #expect(DashboardLayout.panelHeight(for: [codex]) == 176)
    }

    @Test
    func lastProviderTimestampKeepsCompactFooterClearance() {
        let claude = usage(
            provider: .claude,
            meterCount: 2,
            creditText: nil
        )
        let codex = usage(provider: .codex, meterCount: 1)

        #expect(
            DashboardLayout.panelHeight(
                for: [claude, codex]
            ) == 334
        )
    }

    @Test
    func extraMeterResetTextDoesNotReserveProviderTimestampRow() {
        let withoutProviderTimestamp = usageWithExtraReset(
            updatedAt: nil
        )
        let suppressedProviderTimestamp = usageWithExtraReset(
            updatedAt: .now
        )

        #expect(
            DashboardLayout.panelHeight(
                for: [suppressedProviderTimestamp]
            ) == DashboardLayout.panelHeight(
                for: [withoutProviderTimestamp]
            )
        )
    }

    private func usage(
        provider: ProviderID,
        meterCount: Int,
        creditText: String? = "크레딧 0"
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: provider.rawValue,
                    title: nil,
                    meters: (0..<meterCount).map {
                        UsageMeter(
                            id: "\(provider.rawValue)-\($0)",
                            title: "주간",
                            period: .week,
                            percentRemaining: 50
                        )
                    },
                    creditText: creditText
                )
            ],
            availability: .available,
            updatedAt: .now
        )
    }

    private func usageWithExtraReset(
        updatedAt: Date?
    ) -> ProviderUsage {
        ProviderUsage(
            provider: .codex,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: "codex",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "codex-week",
                            title: "주간",
                            period: .week,
                            percentRemaining: 50
                        ),
                        UsageMeter(
                            id: "codex-extra",
                            title: "추가 사용량",
                            period: .extra,
                            percentRemaining: 50,
                            resetText: "02:00 기준"
                        ),
                    ],
                    creditText: "크레딧 0"
                )
            ],
            availability: .available,
            updatedAt: updatedAt
        )
    }
}
