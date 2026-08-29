import Foundation
import Testing
@testable import OmoUsage

@Suite
struct SideNotchHideDelayStoreTests {
    @Test
    func defaultsToStandardAndRepairsUnknownValues() throws {
        let suiteName = "SideNotchHideDelayStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = SideNotchHideDelayStore(defaults: defaults)

        #expect(store.load() == .standard)

        defaults.set(
            9.9,
            forKey: SideNotchHideDelayStore.defaultsKey
        )

        #expect(store.load() == .standard)
        #expect(
            defaults.object(
                forKey: SideNotchHideDelayStore.defaultsKey
            ) == nil
        )
    }

    @Test
    func persistsNondefaultAndRemovesStandardValue() throws {
        let suiteName = "SideNotchHideDelayStoreTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = SideNotchHideDelayStore(defaults: defaults)

        store.save(.extraLong)
        #expect(store.load() == .extraLong)
        #expect(
            defaults.double(
                forKey: SideNotchHideDelayStore.defaultsKey
            ) == 2
        )

        store.save(.standard)
        #expect(store.load() == .standard)
        #expect(
            defaults.object(
                forKey: SideNotchHideDelayStore.defaultsKey
            ) == nil
        )
    }
}
