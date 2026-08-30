import Foundation

struct AntigravityUsageProvider: UsageProvider {
    let id = ProviderID.antigravity
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
        let credential = try discovery.antigravity(now: now)
        let bases = [
            "https://daily-cloudcode-pa.googleapis.com",
            "https://cloudcode-pa.googleapis.com"
        ]
        var lastError: (any Error)?
        for base in bases {
            guard let url = URL(
                string: "\(base)/v1internal:fetchAvailableModels"
            ) else {
                continue
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = Data("{}".utf8)
            request.setValue(
                "Bearer \(credential.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
            do {
                let data = try await http.data(
                    for: request,
                    provider: id,
                    operation: .safe
                )
                return try AntigravityUsageParser.parse(data, now: now)
            } catch ProviderTransportError.authenticationRequired {
                throw ProviderTransportError.authenticationRequired(id)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ProviderTransportError.invalidResponse(id)
    }
}
