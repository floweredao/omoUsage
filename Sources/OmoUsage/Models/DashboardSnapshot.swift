import Foundation

struct DashboardSnapshot: Equatable, Codable, Sendable {
    let providers: [ProviderUsage]
    let generatedAt: Date
    let lastRefreshAttemptAt: Date?
    let oldestDisplayedSuccessAt: Date?

    var refreshedAt: Date { lastRefreshAttemptAt ?? generatedAt }

    init(
        providers: [ProviderUsage],
        generatedAt: Date,
        lastRefreshAttemptAt: Date? = nil,
        oldestDisplayedSuccessAt: Date? = nil
    ) {
        self.providers = providers
        self.generatedAt = generatedAt
        self.lastRefreshAttemptAt = lastRefreshAttemptAt
        self.oldestDisplayedSuccessAt = oldestDisplayedSuccessAt
    }

    init(providers: [ProviderUsage], refreshedAt: Date) {
        self.init(
            providers: providers,
            generatedAt: refreshedAt,
            lastRefreshAttemptAt: refreshedAt,
            oldestDisplayedSuccessAt: providers
                .compactMap(\.lastSuccessfulAt)
                .min()
        )
    }

    static func ordered(
        providers: [ProviderUsage],
        refreshedAt: Date,
        providerOrder: [ProviderID] = ProviderID.allCases
    ) -> DashboardSnapshot {
        let order = ProviderDisplayOrder.repaired(providerOrder)
        let positions = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($1, $0) }
        )
        return DashboardSnapshot(
            providers: providers.enumerated().sorted {
                let lhsPosition = positions[$0.element.provider, default: .max]
                let rhsPosition = positions[$1.element.provider, default: .max]
                return lhsPosition == rhsPosition
                    ? $0.offset < $1.offset
                    : lhsPosition < rhsPosition
            }.map(\.element),
            refreshedAt: refreshedAt
        )
    }

    static func ordered(
        providers: [ProviderUsage],
        refreshedAt: Date,
        accountProviderOrder: [AccountProviderID]
    ) -> DashboardSnapshot {
        let positions = Dictionary(
            uniqueKeysWithValues: accountProviderOrder.enumerated().map {
                ($1, $0)
            }
        )
        return DashboardSnapshot(
            providers: providers.enumerated().sorted {
                let lhsPosition = positions[
                    $0.element.accountProviderID,
                    default: .max
                ]
                let rhsPosition = positions[
                    $1.element.accountProviderID,
                    default: .max
                ]
                return lhsPosition == rhsPosition
                    ? $0.offset < $1.offset
                    : lhsPosition < rhsPosition
            }.map(\.element),
            refreshedAt: refreshedAt
        )
    }

    static func mobileFixture(now: Date) -> DashboardSnapshot {
        let teamAccount = AccountID(
            UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 10
                )
            )
        )
        let personalAccount = AccountID(
            UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 11
                )
            )
        )
        return DashboardSnapshot(
            providers: [
                mobileFixtureUsage(
                    accountID: teamAccount,
                    accountLabel: "QA Team",
                    percentRemaining: 72,
                    now: now
                ),
                mobileFixtureUsage(
                    accountID: personalAccount,
                    accountLabel: "QA Personal",
                    percentRemaining: 48,
                    now: now
                )
            ],
            refreshedAt: now
        )
    }

    private static func mobileFixtureUsage(
        accountID: AccountID,
        accountLabel: String,
        percentRemaining: Int,
        now: Date
    ) -> ProviderUsage {
        ProviderUsage(
            provider: .openrouter,
            accountID: accountID,
            accountLabel: accountLabel,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: "openrouter-\(accountID.rawValue)",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "weekly",
                            title: "Weekly",
                            period: .week,
                            percentRemaining: percentRemaining,
                            resetsAt: now.addingTimeInterval(259_200)
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }
}
