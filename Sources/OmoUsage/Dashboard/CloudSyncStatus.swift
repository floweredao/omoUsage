import Observation

/// Whether the latest snapshot reached iCloud. The mobile app reads only
/// what the Mac publishes, so a failed publish must be visible on the Mac.
@MainActor
@Observable
final class CloudSyncStatus {
    private(set) var isFailing = false

    func publish(_ operation: () throws -> Void) throws {
        do {
            try operation()
            isFailing = false
        } catch {
            isFailing = true
            throw error
        }
    }
}
