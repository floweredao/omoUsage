import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct ProviderDisplayOrderStoreTests {
    @Test
    func repairsUnknownDuplicateAndMalformedSavedValues() throws {
        let suiteName = "OmoUsageOrderTests-\(UUID().uuidString)"
        let defaults = try #require(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderDisplayOrderStore(
            defaults: defaults
        )
        defaults.set(
            ["codex", "unknown-provider", "codex", "claude"],
            forKey: ProviderDisplayOrderStore.defaultsKey
        )
        let expected = [
            ProviderID.codex,
            .claude,
            .cursor,
            .antigravity,
            .copilot,
            .devin,
            .grok,
            .kiro,
            .opencode,
            .openrouter,
            .zai
        ]

        #expect(store.load() == expected)
        #expect(
            defaults.stringArray(
                forKey: ProviderDisplayOrderStore.defaultsKey
            ) == expected.map(\.rawValue)
        )

        defaults.set(
            "malformed",
            forKey: ProviderDisplayOrderStore.defaultsKey
        )

        #expect(store.load() == ProviderID.allCases)
        #expect(
            defaults.stringArray(
                forKey: ProviderDisplayOrderStore.defaultsKey
            ) == ProviderID.allCases.map(\.rawValue)
        )
    }
}
