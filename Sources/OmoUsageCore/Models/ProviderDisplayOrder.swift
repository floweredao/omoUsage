import Foundation

public enum ProviderDisplayOrder {
    public static func repaired(
        rawValues: [String]
    ) -> [ProviderID] {
        repaired(
            rawValues.compactMap(ProviderID.init(rawValue:))
        )
    }

    public static func repaired(
        _ providers: [ProviderID]
    ) -> [ProviderID] {
        var seen: Set<ProviderID> = []
        let saved = providers.filter {
            seen.insert($0).inserted
        }
        return saved + ProviderID.allCases.filter {
            seen.insert($0).inserted
        }
    }
}

public enum AccountProviderDisplayOrder {
    public static func defaultOrder(
        configured identities: [AccountProviderID]
    ) -> [AccountProviderID] {
        var seenIdentities: Set<AccountProviderID> = []
        let registered = identities.filter {
            seenIdentities.insert($0).inserted
        }
        var seenAccounts: Set<AccountID> = []
        let accountOrder = registered.compactMap { identity in
            seenAccounts.insert(identity.accountID).inserted
                ? identity.accountID
                : nil
        }
        return accountOrder.flatMap { accountID in
            ProviderID.allCases.compactMap { providerID in
                registered.first {
                    $0.accountID == accountID
                        && $0.providerID == providerID
                }
            }
        }
    }

    public static func repaired(
        _ order: [AccountProviderID],
        configured identities: [AccountProviderID]
    ) -> [AccountProviderID] {
        var configuredSeen: Set<AccountProviderID> = []
        let fallback = identities.filter {
            configuredSeen.insert($0).inserted
        }
        let allowed = Set(fallback)
        var seen: Set<AccountProviderID> = []
        let saved = order.filter {
            allowed.contains($0) && seen.insert($0).inserted
        }
        return saved + fallback.filter { seen.insert($0).inserted }
    }
}

public struct ProviderDisplayOrderStore {
    public static let defaultsKey = "providerDisplayOrder"

    public let defaults: UserDefaults
    public let key: String

    public init(
        defaults: UserDefaults,
        key: String = Self.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [ProviderID] {
        let rawValues = defaults.stringArray(forKey: key) ?? []
        let order = ProviderDisplayOrder.repaired(
            rawValues: rawValues
        )
        if rawValues != order.map(\.rawValue) {
            defaults.set(order.map(\.rawValue), forKey: key)
        }
        return order
    }

    public func save(_ order: [ProviderID]) {
        defaults.set(
            ProviderDisplayOrder.repaired(order).map(\.rawValue),
            forKey: key
        )
    }
}
