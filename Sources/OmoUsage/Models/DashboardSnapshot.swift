import Foundation

struct DashboardSnapshot: Equatable, Codable, Sendable {
    let providers: [ProviderUsage]
    let refreshedAt: Date

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
            providers: providers.sorted {
                positions[$0.provider, default: .max] < positions[$1.provider, default: .max]
            },
            refreshedAt: refreshedAt
        )
    }
}
