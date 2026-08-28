import Foundation
import Testing
@testable import OmoUsage

@Suite
struct DashboardPresentationStyleStoreTests {
    @Test
    func defaultsToPopoverAndRepairsUnknownValues() throws {
        let suiteName = "DashboardPresentationStyleStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = DashboardPresentationStyleStore(defaults: defaults)

        #expect(store.load() == .popover)

        defaults.set(
            "unknown-style",
            forKey: DashboardPresentationStyleStore.defaultsKey
        )

        #expect(store.load() == .popover)
        #expect(
            defaults.string(
                forKey: DashboardPresentationStyleStore.defaultsKey
            ) == nil
        )
    }

    @Test
    func persistsTheSelectedPresentationStyle() throws {
        let suiteName = "DashboardPresentationStyleStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = DashboardPresentationStyleStore(defaults: defaults)

        store.save(.sideNotch)

        #expect(store.load() == .sideNotch)
    }
}
