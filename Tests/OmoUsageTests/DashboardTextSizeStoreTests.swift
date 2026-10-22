import Foundation
import Testing
@testable import OmoUsage

@Suite
struct DashboardTextSizeStoreTests {
    @Test
    func defaultsToStandardAndRepairsUnknownValues() throws {
        let suiteName = "DashboardTextSizeStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = DashboardTextSizeStore(defaults: defaults)

        #expect(store.load() == .standard)

        defaults.set(175, forKey: DashboardTextSizeStore.defaultsKey)

        #expect(store.load() == .standard)
        #expect(
            defaults.object(forKey: DashboardTextSizeStore.defaultsKey) == nil
        )
    }

    @Test
    func persistsNondefaultAndRemovesStandardValue() throws {
        let suiteName = "DashboardTextSizeStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = DashboardTextSizeStore(defaults: defaults)

        store.save(.largest)
        #expect(store.load() == .largest)
        #expect(store.load().scale == 2)
        #expect(
            defaults.integer(forKey: DashboardTextSizeStore.defaultsKey) == 200
        )

        store.save(.standard)
        #expect(store.load() == .standard)
        #expect(
            defaults.object(forKey: DashboardTextSizeStore.defaultsKey) == nil
        )
    }
}
