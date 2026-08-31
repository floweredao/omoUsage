import OmoUsageCore
import Foundation

struct ProviderDisconnectionStore {
    static let defaultsKey = "disconnectedProviders"

    let defaults: UserDefaults
    let key: String

    init(
        defaults: UserDefaults,
        key: String = Self.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Set<ProviderID> {
        let rawValues = defaults.stringArray(forKey: key) ?? []
        let providers = Set(
            rawValues.compactMap(ProviderID.init(rawValue:))
        )
        let repaired = orderedRawValues(providers)
        if rawValues != repaired {
            defaults.set(repaired, forKey: key)
        }
        return providers
    }

    func save(_ providers: Set<ProviderID>) {
        defaults.set(orderedRawValues(providers), forKey: key)
    }

    private func orderedRawValues(
        _ providers: Set<ProviderID>
    ) -> [String] {
        ProviderID.allCases.compactMap {
            providers.contains($0) ? $0.rawValue : nil
        }
    }
}
