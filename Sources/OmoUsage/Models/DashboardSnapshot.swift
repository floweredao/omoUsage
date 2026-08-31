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
        let staleSuccessAt = now.addingTimeInterval(-3_600)
        return DashboardSnapshot(
            providers: [
                mobileFixtureUsage(
                    accountID: teamAccount,
                    accountLabel: "QA Team",
                    percentRemaining: 72,
                    successAt: now,
                    attemptAt: now,
                    refreshFailure: nil,
                    now: now
                ),
                mobileFixtureUsage(
                    accountID: personalAccount,
                    accountLabel: "QA Personal",
                    percentRemaining: 48,
                    successAt: staleSuccessAt,
                    attemptAt: now,
                    refreshFailure: .network,
                    now: now
                )
            ],
            generatedAt: now,
            lastRefreshAttemptAt: now,
            oldestDisplayedSuccessAt: staleSuccessAt
        )
    }

    private static func mobileFixtureUsage(
        accountID: AccountID,
        accountLabel: String,
        percentRemaining: Int,
        successAt: Date,
        attemptAt: Date,
        refreshFailure: ProviderRefreshFailure?,
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
                        ),
                        UsageMeter(
                            id: "spend",
                            title: "Last 30 days",
                            period: .extra,
                            metric: .spend(amount: 3, currency: .usd)
                        ),
                        UsageMeter(
                            id: "credit",
                            title: "Credits",
                            period: .extra,
                            metric: .credit(balance: 12, unit: .credits)
                        ),
                        UsageMeter(
                            id: "count",
                            title: "Requests",
                            period: .extra,
                            metric: .count(value: 500, unit: .requests)
                        ),
                        UsageMeter(
                            id: "information",
                            title: "Billing",
                            period: .extra,
                            metric: .informational(value: "Manual renewal")
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            lastSuccessfulAt: successAt,
            lastRefreshAttemptAt: attemptAt,
            refreshFailure: refreshFailure
        )
    }
}
