import Foundation

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch(now: Date) async throws -> ProviderUsage
}
