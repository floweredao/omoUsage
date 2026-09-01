import OmoUsageCore
import Foundation

struct GrokUsageProvider: UsageProvider {
    /// Refresh inside a guard band rather than at the deadline; a token
    /// that expires mid-flight reads as a revoked credential.
    static let refreshLeadTime: TimeInterval = 300
    /// Used when the store carries no issuer to discover from. A stored
    /// issuer still goes through the strict allow-list below.
    static let fixedTokenEndpoint = URL(
        string: "https://auth.x.ai/oauth2/token"
    )!
    /// Unreserved set from RFC 3986: `+` must survive as `%2B`, because a
    /// form-urlencoded reader decodes a literal `+` back into a space.
    static let formAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    let id = ProviderID.grok
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    func fetch(now: Date) async throws -> ProviderUsage {
        let discovered = try discovery.grok(now: now)
        // Only an auth rejection says the *account* is the problem. A 500,
        // a 429, a malformed payload or a failed write-back are facts about
        // the request, and replaying them across every stored account just
        // multiplies the damage.
        var candidates = discovery.grokCandidates(now: now)
        if candidates.isEmpty {
            candidates = [discovered]
        }
        var authFailure: any Error = ProviderTransportError
            .authenticationRequired(id)
        for candidate in candidates {
            do {
                return try await usage(for: candidate, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProviderTransportError
                where error == .authenticationRequired(id)
            {
                authFailure = error
            } catch {
                throw error
            }
        }
        throw authFailure
    }

    /// One account's full attempt: rotate it if it is inside the guard
    /// band, read usage, and rotate once more if a token the clock still
    /// trusts turns out to be revoked.
    private func usage(
        for candidate: DiscoveredCredential,
        now: Date
    ) async throws -> ProviderUsage {
        var credential = candidate
        if
            let expiresAt = credential.expiresAt,
            expiresAt.timeIntervalSince(now) <= Self.refreshLeadTime
        {
            credential = try await refresh(credential, now: now)
        }
        do {
            return try await fetchUsage(
                credential,
                now: now
            )
        } catch let error as ProviderTransportError {
            guard
                case .authenticationRequired(let provider) = error,
                provider == id,
                credential.refreshToken != nil,
                credential.oidcClientID != nil
            else {
                throw error
            }
            let refreshed = try await refresh(credential, now: now)
            return try await fetchUsage(refreshed, now: now)
        }
    }

    private func fetchUsage(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> ProviderUsage {
        async let billing = get(
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            purpose: .grokBilling,
            token: credential.accessToken
        )
        async let settings = try? get(
            "https://cli-chat-proxy.grok.com/v1/settings",
            purpose: .grokSettings,
            token: credential.accessToken
        )
        let (billingData, settingsData) = try await (billing, settings)
        let endpoint = ProviderContractCatalog.endpoint(.grokBilling, for: id)
        return try endpoint.schemaChecked {
            try parse(billingData, settings: settingsData, now: now)
        }
    }

    private static func formBody(
        _ fields: [(String, String)]
    ) -> Data? {
        let encoded = fields.compactMap { name, value in
            guard
                let name = name.addingPercentEncoding(
                    withAllowedCharacters: formAllowedCharacters
                ),
                let value = value.addingPercentEncoding(
                    withAllowedCharacters: formAllowedCharacters
                )
            else {
                return nil as String?
            }
            return "\(name)=\(value)"
        }
        guard encoded.count == fields.count else {
            return nil
        }
        return encoded.joined(separator: "&").data(using: .utf8)
    }

    /// Resolves the token endpoint from a stored issuer. The allow-list
    /// and the same-host check on the discovered endpoint are the reason
    /// a hostile `oidc_issuer` never receives the refresh token.
    private func discoveredTokenEndpoint(
        issuer: String
    ) async throws -> URL {
        guard
            var discoveryURL = URL(string: issuer),
            discoveryURL.scheme == "https",
            discoveryURL.host?.lowercased() == "auth.grok.com",
            discoveryURL.user == nil,
            discoveryURL.password == nil,
            discoveryURL.port == nil || discoveryURL.port == 443
        else {
            throw ProviderTransportError.invalidResponse(id)
        }
        let host = discoveryURL.host?.lowercased()
        let port = discoveryURL.port ?? 443
        discoveryURL.append(path: ".well-known/openid-configuration")
        let discoveryContract = ProviderContractCatalog.endpoint(
            .grokOpenIDConfiguration,
            for: id
        )
        var discoveryRequest = URLRequest(url: discoveryURL)
        discoveryRequest.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        let discoveryData = try await http.data(
            for: discoveryRequest,
            endpoint: discoveryContract
        )
        return try discoveryContract.schemaChecked {
            let discoveryPayload = try ProviderPayload.object(
                discoveryData
            )
            guard
                let endpointText = ProviderPayload.text(
                    discoveryPayload,
                    paths: [["token_endpoint"]]
                ),
                let endpoint = URL(string: endpointText),
                endpoint.scheme == "https",
                endpoint.host?.lowercased() == host,
                endpoint.user == nil,
                endpoint.password == nil,
                (endpoint.port ?? 443) == port
            else {
                throw ProviderTransportError.invalidResponse(id)
            }
            return endpoint
        }
    }

    private func refresh(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> DiscoveredCredential {
        guard
            let refreshToken = credential.refreshToken,
            let clientID = credential.oidcClientID,
            let accountID = credential.accountID
        else {
            throw ProviderTransportError.invalidResponse(id)
        }
        let endpoint: URL
        if let issuer = credential.oidcIssuer {
            endpoint = try await discoveredTokenEndpoint(issuer: issuer)
        } else {
            endpoint = Self.fixedTokenEndpoint
        }
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID)
        ]
        if let principalType = credential.principalType {
            fields.append(("principal_type", principalType))
        }
        if let principalID = credential.principalID {
            fields.append(("principal_id", principalID))
        }
        guard let body = Self.formBody(fields) else {
            throw ProviderTransportError.invalidResponse(id)
        }
        let tokenContract = ProviderContractCatalog.endpoint(
            .grokTokenRefresh,
            for: id
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = body
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let tokenData = try await http.data(
            for: request,
            endpoint: tokenContract
        )
        let (tokenPayload, accessToken, expiresIn) = try tokenContract
            .schemaChecked {
                let tokenPayload = try ProviderPayload.object(tokenData)
                guard
                    let accessToken = ProviderPayload.text(
                        tokenPayload,
                        paths: [["access_token"]]
                    ),
                    let expiresIn = ProviderPayload.number(
                        tokenPayload,
                        paths: [["expires_in"]]
                    )
                else {
                    throw ProviderTransportError.invalidResponse(id)
                }
                return (tokenPayload, accessToken, expiresIn)
            }
        let rotatedRefreshToken = ProviderPayload.text(
            tokenPayload,
            paths: [["refresh_token"]]
        ) ?? refreshToken
        let expiresAt = now.addingTimeInterval(expiresIn)
        try discovery.persistGrokCredential(
            accountID: accountID,
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            expiresAt: expiresAt,
            idToken: ProviderPayload.text(
                tokenPayload,
                paths: [["id_token"]]
            )
        )
        return DiscoveredCredential(
            provider: id,
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            accountID: accountID,
            planName: credential.planName,
            expiresAt: expiresAt,
            source: credential.source,
            oidcIssuer: credential.oidcIssuer,
            oidcClientID: clientID,
            principalType: credential.principalType,
            principalID: credential.principalID
        )
    }

    private func get(
        _ url: String,
        purpose: ProviderEndpointPurpose,
        token: String
    ) async throws -> Data {
        let endpoint = ProviderContractCatalog.endpoint(purpose, for: id)
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 12
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "xai-grok-cli",
            forHTTPHeaderField: "X-XAI-Token-Auth"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.data(for: request, endpoint: endpoint)
    }

    private func parse(
        _ data: Data,
        settings: Data?,
        now: Date
    ) throws -> ProviderUsage {
        let root = try ProviderPayload.object(data)
        let used = ProviderPayload.number(
            root,
            paths: [
                ["config", "creditUsagePercent"],
                ["weekly", "usedPercent"],
                ["weekly", "used_percent"],
                ["weeklyUsedPercent"],
                ["weekly_usage_percent"]
            ]
        )
        let remaining = ProviderPayload.number(
            root,
            paths: [
                ["weekly", "percentRemaining"],
                ["weekly", "percent_remaining"],
                ["weeklyRemainingPercent"]
            ]
        )
        let percentRemaining = remaining.flatMap(ProviderPayload.percent)
            ?? used.flatMap {
                ProviderPayload.remainingPercent(usedPercent: $0)
            }
        guard let percentRemaining else {
            throw ProviderTransportError.invalidResponse(id)
        }
        let reset = ProviderPayload.date(
            root,
            paths: [
                ["config", "currentPeriod", "end"],
                ["weekly", "resetAt"],
                ["weekly", "reset_at"],
                ["weeklyResetAt"]
            ]
        )
        let cap = ProviderPayload.number(
            root,
            paths: [
                ["config", "onDemandCap", "val"],
                ["payAsYouGo", "monthlyCap"],
                ["pay_as_you_go", "monthly_cap"],
                ["payAsYouGoCap"]
            ]
        )
        let settingsRoot: [String: Any]? = if let settings {
            try? ProviderPayload.object(settings)
        } else {
            nil
        }
        var metrics = [
            UsageMeter(
                id: "grok-week",
                title: "주간",
                period: .week,
                percentRemaining: percentRemaining,
                resetsAt: reset,
                resetText: ProviderPayload.resetText(reset, now: now)
            )
        ]
        if let cap = cap.flatMap(ProviderPayload.nonnegativeInteger) {
            metrics.append(
                UsageMeter(
                    id: "grok-monthly-cap",
                    title: "추가 사용량",
                    period: .extra,
                    metric: .informational(value: "\(cap) 한도")
                )
            )
        }
        return ProviderUsage(
            provider: id,
            planName: settingsRoot.flatMap {
                ProviderPayload.text(
                    $0,
                    paths: [
                        ["subscription_tier_display"],
                        ["planName"],
                        ["subscriptionTier"],
                        ["plan"]
                    ]
                )
            } ?? "",
            groups: [
                UsageGroup(
                    id: "grok-usage",
                    title: nil,
                    meters: metrics,
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }
}
