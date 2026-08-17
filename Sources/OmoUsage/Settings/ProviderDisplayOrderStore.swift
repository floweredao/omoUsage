import Foundation

enum ProviderDisplayOrder {
    static func repaired(
        rawValues: [String]
    ) -> [ProviderID] {
        repaired(
            rawValues.compactMap(ProviderID.init(rawValue:))
        )
    }

    static func repaired(
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

struct ProviderDisplayOrderStore {
    static let defaultsKey = "providerDisplayOrder"

    let defaults: UserDefaults
    let key: String

    init(
        defaults: UserDefaults,
        key: String = Self.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [ProviderID] {
        let rawValues = defaults.stringArray(forKey: key) ?? []
        let order = ProviderDisplayOrder.repaired(
            rawValues: rawValues
        )
        if rawValues != order.map(\.rawValue) {
            defaults.set(order.map(\.rawValue), forKey: key)
        }
        return order
    }

    func save(_ order: [ProviderID]) {
        defaults.set(
            ProviderDisplayOrder.repaired(order).map(\.rawValue),
            forKey: key
        )
    }
}
