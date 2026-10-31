import OmoUsageCore
import Foundation

@MainActor
final class ExperimentalFeatureStore {
    nonisolated static let kiroLBDefaultsKey = "OmoUsage.experimental.kiroLB"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isKiroLBEnabled: Bool {
        Self.isKiroLBEnabled(in: defaults)
    }

    func setKiroLBEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.kiroLBDefaultsKey)
    }

    nonisolated static func isKiroLBEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: kiroLBDefaultsKey)
    }

    /// Providers that ship behind a Labs flag, so a persisted or posted
    /// provider order may predate them.
    nonisolated static let experimentalProviders: Set<ProviderID> = [.kiroLB]

    nonisolated static func excludedProviders(
        in defaults: UserDefaults
    ) -> Set<ProviderID> {
        isKiroLBEnabled(in: defaults) ? [] : experimentalProviders
    }
}
