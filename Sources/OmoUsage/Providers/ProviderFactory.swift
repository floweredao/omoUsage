import OmoUsageCore
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
        let references = Set(registry.providerReferences)
        let referencedAccounts = ProviderID.allCases.flatMap { provider in
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
            return referencedAccounts.map { provider, account in
                FixtureUsageProvider(
                    id: provider,
                    accountID: account.id,
                    accountLabel: account.label
                )
            }
        }

        let discovery = CredentialDiscovery.live()
        let http = ProviderHTTP()
        return referencedAccounts.map { provider, account in
            switch provider {
            case .claude:
                ClaudeUsageProvider(
                    accountID: account.id,
                    accountLabel: account.label,
                    discovery: discovery,
                    http: http
                )
            case .codex:
                CodexUsageProvider(
                    discovery: discovery,
                    http: http,
                    accountID: account.id,
                    accountLabel: account.label
                )
            case .cursor:
                CursorUsageProvider(
                    discovery: discovery,
                    http: http,
                    accountID: account.id,
                    accountLabel: account.label
                )
            case .antigravity:
                AntigravityUsageProvider(
                    discovery: discovery,
                    http: http,
                    accountID: account.id,
                    accountLabel: account.label
                )
            case .copilot:
                CopilotUsageProvider(
                    discovery: discovery,
                    http: http,
                    accountID: account.id,
                    accountLabel: account.label
                )
            case .devin:
                DevinUsageProvider(
                    discovery: discovery,
                    http: http,
                    accountID: account.id,
                    accountLabel: account.label
                )
            case .grok:
                GrokUsageProvider(
                    discovery: discovery,
                    http: http,
                    accountID: account.id,
                    accountLabel: account.label
                )
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
