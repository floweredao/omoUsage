import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct DashboardLayoutTests {
    @Test
    @MainActor
    func popoverHeightFitsTwoProviderContentWithoutBlankBand() {
        let providers = screenshotProviders()
        let contentWidth: CGFloat = 320 - 28
        let hostingView = NSHostingView(
            rootView:
                VStack(spacing: 0) {
                    ProviderSectionView(usage: providers[0])
                    Divider()
                        .padding(.vertical, 10)
                    ProviderSectionView(usage: providers[1])
                }
                .frame(width: contentWidth)
                .environment(
                    \.appLocalization,
                    LocalizationContext(language: .english)
                )
        )
        let renderedContentHeight = hostingView.fittingSize.height
        let calculatedContentHeight =
            DashboardLayout.panelHeight(for: providers)
            - DashboardLayout.footerHeight
        let expectedContentHeight: CGFloat =
            12
            + renderedContentHeight
            + DashboardLayout.contentBottomPadding

        #expect(calculatedContentHeight == expectedContentHeight)
    }

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
    func repeatedProviderAccountsReserveBothAliasRows() {
        let codex = usage(provider: .codex, meterCount: 1)
        let claude = usage(provider: .claude, meterCount: 1)
        let work = codex.assigningAccount(
            id: AccountID(rawValue: "00000000-0000-0000-0000-000000000002")!,
            label: "Work"
        )

        #expect(
            DashboardLayout.panelHeight(for: [codex, work])
                == DashboardLayout.panelHeight(for: [codex, claude]) + 26
        )
        #expect(
            DashboardLayout.panelHeight(for: [work])
                == DashboardLayout.panelHeight(for: [codex]) + 13
        )
    }

    @Test
    func codexTimestampUsesCompactSectionHeight() {
        let codex = usage(provider: .codex, meterCount: 1)

        #expect(DashboardLayout.panelHeight(for: [codex]) == 160)
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
            ) == 284
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

    private func screenshotProviders() -> [ProviderUsage] {
        [
            ProviderUsage(
                provider: .codex,
                planName: "Pro",
                groups: [
                    UsageGroup(
                        id: "codex.main",
                        title: nil,
                        meters: [
                            UsageMeter(
                                id: "codex.week",
                                title: "Weekly",
                                period: .week,
                                percentRemaining: 12,
                                resetText: "Resets in 4 days"
                            ),
                            UsageMeter(
                                id: "codex.credits",
                                title: "Credits",
                                period: .extra,
                                metric: .credit(
                                    balance: 0,
                                    unit: .credits
                                )
                            ),
                            UsageMeter(
                                id: "codex.tickets",
                                title: "Full reset tickets",
                                period: .extra,
                                metric: .count(
                                    value: 0,
                                    unit: .tickets
                                )
                            ),
                        ],
                        creditText: nil
                    )
                ],
                availability: .available,
                updatedAt: Date(timeIntervalSince1970: 1_788_467_380)
            ),
            ProviderUsage(
                provider: .claude,
                planName: "Max 5x",
                groups: [
                    UsageGroup(
                        id: "claude.main",
                        title: nil,
                        meters: [
                            UsageMeter(
                                id: "claude.session",
                                title: "Session (5 hours)",
                                period: .session,
                                percentRemaining: 77,
                                resetText: "Resets in 3 hr 56 min"
                            ),
                            UsageMeter(
                                id: "claude.week",
                                title: "Weekly",
                                period: .week,
                                percentRemaining: 78,
                                resetText: "Resets in 6 days"
                            ),
                            UsageMeter(
                                id: "claude.fable",
                                title: "Fable weekly",
                                period: .week,
                                percentRemaining: 83,
                                resetText: "Resets in 6 days"
                            ),
                        ],
                        creditText: nil
                    )
                ],
                availability: .available,
                updatedAt: Date(timeIntervalSince1970: 1_788_467_380)
            ),
        ]
    }
}
