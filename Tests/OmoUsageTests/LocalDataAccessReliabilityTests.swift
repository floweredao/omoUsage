import Foundation
import Testing
@testable import OmoUsage

@Suite
struct LocalDataAccessReliabilityTests {
    @Test
    func runawayCommandIsTerminatedWithinDeadline() {
        #expect(throws: LocalDataAccessError.timedOut) {
            _ = try LocalDataAccess.commandValue(
                executable: URL(filePath: "/usr/bin/tail"),
                arguments: ["-f", "/dev/null"],
                timeout: 0.05
            )
        }
    }

    @Test
    func runawayKeychainCommandIsKilledWithinDeadline() {
        let reader = SecurityKeychainReader(
            executable: URL(filePath: "/usr/bin/yes"),
            timeout: 0.05
        )

        #expect(throws: KeychainReadError.self) {
            _ = try reader.value(service: "unused", account: "")
        }
    }
}
