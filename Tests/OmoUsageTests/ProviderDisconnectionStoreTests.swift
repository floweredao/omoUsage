import Foundation
import Testing
@testable import OmoUsage

@Suite("Provider disconnection store")
struct ProviderDisconnectionStoreTests {
    @Test
    func repairsAndPersistsDisconnectedProviders() throws {
        let name = "ProviderDisconnectionStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ProviderDisconnectionStore(
            defaults: defaults,
            key: "disconnected"
        )
        defaults.set(
            ["claude", "unknown", "claude"],
            forKey: "disconnected"
        )

        #expect(store.load() == [.claude])

        store.save([.copilot, .codex])
        #expect(
            defaults.stringArray(forKey: "disconnected")
                == ["codex", "copilot"]
        )
    }
}
