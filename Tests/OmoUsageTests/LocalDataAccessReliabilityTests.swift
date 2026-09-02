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
    func runawayBoundedProcessIsKilledWithinDeadline() {
        #expect(throws: BoundedProcessError.timedOut) {
            _ = try BoundedProcessRunner().run(
                executable: URL(filePath: "/usr/bin/yes"),
                arguments: [],
                timeout: 0.05
            )
        }
    }
}
