import Foundation

struct CodexUsageProvider: UsageProvider {
    let id = ProviderID.codex
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    init(
        discovery: CredentialDiscovery = .live(),
        http: ProviderHTTP = ProviderHTTP()
    ) {
        self.discovery = discovery
        self.http = http
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        let credential = try discovery.codex(now: now)
        var request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        )
        request.timeoutInterval = 10
        request.setValue(
            "Bearer \(credential.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OmoUsage", forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID {
            request.setValue(
                accountID,
                forHTTPHeaderField: "ChatGPT-Account-Id"
            )
        }
        let data = try await http.data(
            for: request,
            provider: id,
            operation: .safe
        )
        return try CodexUsageParser.parse(data, now: now)
    }
}
