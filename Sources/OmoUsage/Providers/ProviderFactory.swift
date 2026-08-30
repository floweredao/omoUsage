import Foundation

enum ProviderFactory {
    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any UsageProvider] {
        if environment["OMO_USAGE_FIXTURE_MODE"] == "1" {
            return ProviderID.allCases.map {
                FixtureUsageProvider(id: $0)
            }
        }

        let discovery = CredentialDiscovery.live()
        let http = ProviderHTTP()
        return companionProviders(discovery: discovery, http: http) + [
            OpenCodeUsageProvider(discovery: discovery),
            OpenRouterUsageProvider(discovery: discovery, http: http),
            ZAIUsageProvider(discovery: discovery, http: http)
        ]
    }

    static func current(
        registry: ProviderAccountRegistry,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any UsageProvider] {
        let accountByID = Dictionary(
            uniqueKeysWithValues: registry.accounts.map { ($0.id, $0) }
        )
        let legacyLabel = accountByID[.legacy]?.label
            ?? AccountLabel.defaultValue
        let references = Set(registry.apiKeyReferences)
        let apiKeyProviders: [ProviderID] = [.opencode, .openrouter, .zai]
        let referencedAccounts = apiKeyProviders.flatMap { provider in
            registry.accounts.compactMap { account -> (ProviderID, ProviderAccount)? in
                let identity = AccountProviderID(
                    accountID: account.id,
                    providerID: provider
                )
                return references.contains(identity)
                    ? (provider, account)
                    : nil
            }
        }

        if environment["OMO_USAGE_FIXTURE_MODE"] == "1" {
            let companions = ProviderID.allCases
                .filter { !apiKeyProviders.contains($0) }
                .map {
                    FixtureUsageProvider(
                        id: $0,
                        accountID: .legacy,
                        accountLabel: legacyLabel
                    )
                }
            return companions + referencedAccounts.map { provider, account in
                FixtureUsageProvider(
                    id: provider,
                    accountID: account.id,
                    accountLabel: account.label
                )
            }
        }

        let discovery = CredentialDiscovery.live()
        let http = ProviderHTTP()
        let companions = companionProviders(
            discovery: discovery,
            http: http
        ).map {
            AccountScopedUsageProvider(
                provider: $0,
                accountID: .legacy,
                accountLabel: legacyLabel
            )
        }
        return companions + referencedAccounts.map { provider, account in
            switch provider {
            case .opencode:
                OpenCodeUsageProvider(
                    discovery: discovery,
                    accountID: account.id,
                    accountLabel: account.label
                )
            case .openrouter:
                OpenRouterUsageProvider(
                    discovery: discovery,
                    http: http,
                    accountID: account.id,
                    accountLabel: account.label
                )
            case .zai:
                ZAIUsageProvider(
                    discovery: discovery,
                    http: http,
                    accountID: account.id,
                    accountLabel: account.label
                )
            default:
                preconditionFailure("Non-API-key provider reference")
            }
        }
    }

    private static func companionProviders(
        discovery: CredentialDiscovery,
        http: ProviderHTTP
    ) -> [any UsageProvider] {
        [
            ClaudeUsageProvider(discovery: discovery, http: http),
            CodexUsageProvider(discovery: discovery, http: http),
            CursorUsageProvider(discovery: discovery, http: http),
            AntigravityUsageProvider(discovery: discovery, http: http),
            CopilotUsageProvider(discovery: discovery, http: http),
            DevinUsageProvider(discovery: discovery, http: http),
            GrokUsageProvider(discovery: discovery, http: http)
        ]
    }
}

private struct AccountScopedUsageProvider: UsageProvider {
    let provider: any UsageProvider
    let accountID: AccountID
    let accountLabel: String

    var id: ProviderID { provider.id }

    func fetch(now: Date) async throws -> ProviderUsage {
        try await provider.fetch(now: now)
    }
}
