import Foundation

enum ProviderFactory {
    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any UsageProvider] {
        if environment["OMO_USAGE_FIXTURE_MODE"] == "1" {
            return ProviderID.allCases.map(FixtureUsageProvider.init)
        }

        let discovery = CredentialDiscovery.live()
        let http = ProviderHTTP()
        return [
            ClaudeUsageProvider(discovery: discovery, http: http),
            CodexUsageProvider(discovery: discovery, http: http),
            CursorUsageProvider(discovery: discovery, http: http),
            AntigravityUsageProvider(discovery: discovery, http: http),
            CopilotUsageProvider(discovery: discovery, http: http),
            DevinUsageProvider(discovery: discovery, http: http),
            GrokUsageProvider(discovery: discovery, http: http),
            OpenCodeUsageProvider(discovery: discovery),
            OpenRouterUsageProvider(discovery: discovery, http: http),
            ZAIUsageProvider(discovery: discovery, http: http)
        ]
    }
}
