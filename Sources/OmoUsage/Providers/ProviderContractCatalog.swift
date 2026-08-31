import OmoUsageCore
enum ProviderContractCatalog {
    static let contracts: [ProviderID: ProviderContract] = {
        let definitions: [ProviderID: [EndpointDefinition]] = [
            .claude: [
                .get(.claudeOAuthUsage, ["Authorization", "Accept", "Content-Type", "anthropic-beta"], userAgent: .requiredStable),
                .post(.claudeTokenRefresh, ["Content-Type", "Accept"], userAgent: .requiredStable, safety: .unsafe),
                .get(.claudeDesktopUsage, ["Accept", "Content-Type", "Cookie", "Origin", "Referer"], userAgent: .requiredStable)
            ],
            .codex: [
                .get(.codexUsage, ["Authorization", "Accept"], userAgent: .requiredStable)
            ],
            .cursor: [
                .get(.cursorUsageSummary, ["Authorization", "Accept"]),
                .get(.cursorAccount, ["Authorization", "Accept"])
            ],
            .antigravity: [
                .post(.antigravityAvailableModels, ["Authorization", "Content-Type"], userAgent: .requiredStable)
            ],
            .copilot: [
                .get(.copilotUser, ["Authorization", "Accept", "Editor-Version", "Editor-Plugin-Version", "X-Github-Api-Version"], userAgent: .requiredStable)
            ],
            .devin: [
                .post(.devinUserStatus, ["Content-Type", "Connect-Protocol-Version"])
            ],
            .grok: [
                .get(.grokBilling, ["Authorization", "X-XAI-Token-Auth", "Accept"]),
                .get(.grokSettings, ["Authorization", "X-XAI-Token-Auth", "Accept"]),
                .get(.grokOpenIDConfiguration, ["Accept"]),
                .post(.grokTokenRefresh, ["Content-Type", "Accept"], safety: .unsafe)
            ],
            .opencode: [
                .get(.openCodeGoUsage, ["Authorization", "Accept"])
            ],
            .openrouter: [
                .get(.openRouterCredits, ["Authorization", "Accept"]),
                .get(.openRouterKey, ["Authorization", "Accept"])
            ],
            .zai: [
                .get(.zaiQuota, ["Authorization", "Accept"]),
                .get(.zaiSubscription, ["Authorization", "Accept"])
            ]
        ]
        return Dictionary(uniqueKeysWithValues: definitions.map { provider, endpoints in
            let revision = 1
            return (
                provider,
                ProviderContract(
                    provider: provider,
                    schemaRevision: revision,
                    endpoints: endpoints.map {
                        ProviderEndpointDescriptor(
                            provider: provider,
                            purpose: $0.purpose,
                            method: $0.method,
                            requiredHeaderNames: $0.requiredHeaderNames,
                            userAgentPolicy: $0.userAgentPolicy,
                            safety: $0.safety,
                            schemaRevision: revision
                        )
                    }
                )
            )
        })
    }()

    static func contract(for provider: ProviderID) -> ProviderContract {
        guard let contract = contracts[provider] else {
            preconditionFailure("Missing provider contract")
        }
        return contract
    }

    static func endpoint(
        _ purpose: ProviderEndpointPurpose,
        for provider: ProviderID
    ) -> ProviderEndpointDescriptor {
        guard let endpoint = contract(for: provider).endpoints.first(
            where: { $0.purpose == purpose }
        ) else {
            preconditionFailure("Missing provider endpoint contract")
        }
        return endpoint
    }
}

private struct EndpointDefinition {
    let purpose: ProviderEndpointPurpose
    let method: ProviderHTTPMethod
    let requiredHeaderNames: Set<String>
    let userAgentPolicy: ProviderUserAgentPolicy
    let safety: ProviderRequestSafety

    static func get(
        _ purpose: ProviderEndpointPurpose,
        _ headers: Set<String>,
        userAgent: ProviderUserAgentPolicy = .systemProvided,
        safety: ProviderRequestSafety = .safe
    ) -> EndpointDefinition {
        EndpointDefinition(
            purpose: purpose,
            method: .get,
            requiredHeaderNames: headers,
            userAgentPolicy: userAgent,
            safety: safety
        )
    }

    static func post(
        _ purpose: ProviderEndpointPurpose,
        _ headers: Set<String>,
        userAgent: ProviderUserAgentPolicy = .systemProvided,
        safety: ProviderRequestSafety = .safe
    ) -> EndpointDefinition {
        EndpointDefinition(
            purpose: purpose,
            method: .post,
            requiredHeaderNames: headers,
            userAgentPolicy: userAgent,
            safety: safety
        )
    }
}
