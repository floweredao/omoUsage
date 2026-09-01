import OmoUsageCore
import Foundation

struct CodexUsageProvider: UsageProvider {
    let id = ProviderID.codex
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    private static let refreshLeadTime: TimeInterval = 300
    private static let tokenEndpoint = URL(
        string: "https://auth.openai.com/oauth/token"
    )!
    private static let oauthClientID =
        "app_EMoamEEZ73f0CkXaXp7hrann"

    init(
        discovery: CredentialDiscovery = .live(),
        http: ProviderHTTP = ProviderHTTP()
    ) {
        self.discovery = discovery
        self.http = http
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        let candidates = discovery.codexCandidates(now: now)
        guard !candidates.isEmpty else {
            let credential = try discovery.codex(now: now)
            return try await fetch(
                credential: credential,
                now: now
            )
        }
        var firstAuthenticationFailure: ProviderTransportError?
        for credential in candidates {
            do {
                return try await fetch(
                    credential: credential,
                    now: now
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProviderContractError {
                throw error
            } catch let error as ProviderTransportError {
                guard error == .authenticationRequired(id) else {
                    throw error
                }
                if firstAuthenticationFailure == nil {
                    firstAuthenticationFailure = error
                }
            } catch {
                throw error
            }
        }
        throw firstAuthenticationFailure
            ?? ProviderTransportError.authenticationRequired(id)
    }

    private func fetch(
        credential storedCredential: DiscoveredCredential,
        now: Date
    ) async throws -> ProviderUsage {
        var credential = storedCredential
        var didRefresh = false
        if
            let expiresAt = credential.expiresAt,
            expiresAt.timeIntervalSince(now) <= Self.refreshLeadTime
        {
            credential = try await refreshedCredential(
                credential,
                now: now
            )
            didRefresh = true
        }
        do {
            return try await fetchUsage(credential, now: now)
        } catch {
            if
                !didRefresh,
                credential.refreshToken != nil,
                error as? ProviderTransportError
                    == .authenticationRequired(id)
            {
                let rotated = try await refreshedCredential(
                    credential,
                    now: now
                )
                return try await fetchUsage(rotated, now: now)
            }
            throw error
        }
    }

    private func fetchUsage(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> ProviderUsage {
        let endpoint = ProviderContractCatalog.endpoint(.codexUsage, for: id)
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
        let data = try await http.data(for: request, endpoint: endpoint)
        return try endpoint.schemaChecked {
            try CodexUsageParser.parse(data, now: now)
        }
    }

    private func refreshedCredential(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> DiscoveredCredential {
        guard let refreshToken = credential.refreshToken else {
            throw ProviderTransportError.authenticationRequired(id)
        }
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = formEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", Self.oauthClientID)
        ])
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OmoUsage", forHTTPHeaderField: "User-Agent")
        let data = try await http.data(
            for: request,
            provider: id,
            operation: .unsafe
        )
        let payload = try ProviderPayload.object(data)
        guard
            let accessToken = ProviderPayload.text(
                payload,
                paths: [["access_token"]]
            )
        else {
            throw ProviderTransportError.invalidResponse(id)
        }
        let rotatedRefreshToken = ProviderPayload.text(
            payload,
            paths: [["refresh_token"]]
        )
        let rotatedIDToken = ProviderPayload.text(
            payload,
            paths: [["id_token"]]
        )
        let expiresAt = ProviderPayload.number(
            payload,
            paths: [["expires_in"]]
        ).map { now.addingTimeInterval($0) }
        try discovery.persistCodexCredential(
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            idToken: rotatedIDToken,
            lastRefresh: now,
            storage: credential.storage
        )
        return DiscoveredCredential(
            provider: id,
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken ?? refreshToken,
            accountID: credential.accountID,
            planName: credential.planName,
            expiresAt: expiresAt,
            source: credential.source,
            storage: credential.storage
        )
    }

    private func formEncoded(
        _ fields: [(String, String)]
    ) -> Data {
        let text = fields.map {
            "\(formComponent($0.0))=\(formComponent($0.1))"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    private func formComponent(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,
                0x2D, 0x2E, 0x5F, 0x7E:
                String(UnicodeScalar(byte))
            case 0x20:
                "+"
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }
}
