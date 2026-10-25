#if DEBUG
import Foundation
import Testing
@testable import OmoUsage

@Suite
struct FixtureModeIsolationTests {
    private let fixture = ["OMO_USAGE_FIXTURE_MODE": "1", "XDG_CONFIG_HOME": "/real/config"]

    @Test
    func fixtureModeNeverReachesRealSettingsRegistryOrICloud() throws {
        let scratch = URL(filePath: "/scratch/fixture", directoryHint: .isDirectory)

        #expect(!FixtureModeIsolation.publishesToCloud(
            environment: fixture,
            hasCompanionFixture: false
        ))
        #expect(FixtureModeIsolation.configEnvironment(
            fixture,
            scratchRoot: scratch
        )["XDG_CONFIG_HOME"] == scratch.path(percentEncoded: false))
        let defaults = try #require(FixtureModeIsolation.defaults(environment: fixture))
        #expect(defaults !== UserDefaults.standard)
        UserDefaults().removePersistentDomain(
            forName: FixtureModeIsolation.defaultsSuiteName
        )
    }

    @Test
    func liveModeKeepsRealSettingsRegistryAndICloud() {
        let live = ["XDG_CONFIG_HOME": "/real/config"]

        #expect(FixtureModeIsolation.publishesToCloud(
            environment: live,
            hasCompanionFixture: false
        ))
        #expect(FixtureModeIsolation.configEnvironment(live) == live)
        #expect(FixtureModeIsolation.defaults(environment: live) == nil)
    }
}
#endif
