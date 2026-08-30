import Foundation

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    var accountID: AccountID { get }
    var accountLabel: String { get }
    func fetch(now: Date) async throws -> ProviderUsage
}

extension UsageProvider {
    var accountID: AccountID { .legacy }
    var accountLabel: String { AccountLabel.defaultValue }
    var accountProviderID: AccountProviderID {
        AccountProviderID(accountID: accountID, providerID: id)
    }
}
