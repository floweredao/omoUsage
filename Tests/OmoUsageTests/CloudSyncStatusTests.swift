import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct CloudSyncStatusTests {
    private struct CloudSyncStatusTestError: Error {}

    @Test @MainActor
    func failedPublishIsShownUntilAPublishSucceeds() throws {
        let status = CloudSyncStatus()

        #expect(throws: CloudSyncStatusTestError.self) {
            try status.publish { throw CloudSyncStatusTestError() }
        }
        #expect(status.isFailing)

        try status.publish {}
        #expect(!status.isFailing)
    }
}
