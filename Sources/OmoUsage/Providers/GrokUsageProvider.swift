import Foundation

struct GrokUsageProvider: UsageProvider {
    let id = ProviderID.grok
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    func fetch(now: Date) async throws -> ProviderUsage {
        let discovered = try discovery.grok(now: now)
        let credential: DiscoveredCredential
        if let expiresAt = discovered.expiresAt, expiresAt <= now {
            credential = try await refresh(discovered, now: now)
        } else {
            credential = discovered
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
                credential.oidcIssuer != nil,
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

    private func refresh(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> DiscoveredCredential {
        guard
            let refreshToken = credential.refreshToken,
            let issuer = credential.oidcIssuer,
            let clientID = credential.oidcClientID,
            let accountID = credential.accountID,
            var discoveryURL = URL(string: issuer),
            discoveryURL.scheme == "https",
            discoveryURL.host?.lowercased() == "auth.grok.com",
            discoveryURL.user == nil,
            discoveryURL.password == nil,
            discoveryURL.port == nil || discoveryURL.port == 443
        else {
            throw ProviderTransportError.invalidResponse(id)
        }
        discoveryURL.append(
            path: ".well-known/openid-configuration"
        )
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
        let endpoint = try discoveryContract.schemaChecked {
            let discoveryPayload = try ProviderPayload.object(discoveryData)
            guard
                let endpointText = ProviderPayload.text(
                    discoveryPayload,
                    paths: [["token_endpoint"]]
                ),
                let endpoint = URL(string: endpointText),
                endpoint.scheme == "https",
                endpoint.host?.lowercased()
                    == discoveryURL.host?.lowercased(),
                endpoint.user == nil,
                endpoint.password == nil,
                (endpoint.port ?? 443) == (discoveryURL.port ?? 443)
            else {
                throw ProviderTransportError.invalidResponse(id)
            }
            return endpoint
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID)
        ]
        if let principalType = credential.principalType {
            form.queryItems?.append(
                URLQueryItem(
                    name: "principal_type",
                    value: principalType
                )
            )
        }
        if let principalID = credential.principalID {
            form.queryItems?.append(
                URLQueryItem(
                    name: "principal_id",
                    value: principalID
                )
            )
        }
        guard let body = form.percentEncodedQuery?.data(using: .utf8) else {
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
            expiresAt: expiresAt
        )
        return DiscoveredCredential(
            provider: id,
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            accountID: accountID,
            planName: credential.planName,
            expiresAt: expiresAt,
            source: credential.source,
            oidcIssuer: issuer,
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
