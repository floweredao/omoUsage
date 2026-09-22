import OmoUsageCore
import Foundation

/// Undocumented GetUsageLimits query used by the official Kiro CLI.
struct KiroUsageProvider: UsageProvider {
    let id = ProviderID.kiro
    let accountID: AccountID
    let accountLabel: String
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    init(
        discovery: CredentialDiscovery,
        http: ProviderHTTP,
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue
    ) {
        self.discovery = discovery
        self.http = http
        self.accountID = accountID
        self.accountLabel = accountLabel
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        try Task.checkCancellation()
        var credential = try discovery.kiro(
            accountID: accountID, now: now, allowingExpiredAppOAuth: true
        )
        let owned = CredentialDiscovery.isAppOwnedKiroOAuth(credential)
        if owned, let expiry = credential.expiresAt, expiry <= now.addingTimeInterval(60) {
            if credential.oidcIssuer == KiroBuilderIDAuthentication.issuer {
                return try await refreshBuilderID(credential, now: now)
            }
            credential = try await refresh(credential, now: now)
            return try await fetch(credential: credential, now: now)
        }
        do {
            return try await fetch(credential: credential, now: now)
        } catch ProviderTransportError.authenticationRequired(.kiro) where owned {
            if credential.oidcIssuer == KiroBuilderIDAuthentication.issuer {
                return try await refreshBuilderID(credential, now: now)
            }
            credential = try await refresh(credential, now: now)
            return try await fetch(credential: credential, now: now)
        }
    }

    /// Validate a newly captured credential without rotating or persisting it.
    func fetch(credential: DiscoveredCredential, now: Date) async throws -> ProviderUsage {
        try Task.checkCancellation()
        try CredentialDiscovery.validateKiroCredential(credential, now: now)
        if credential.oidcIssuer == KiroBuilderIDAuthentication.issuer {
            let request = KiroBuilderIDAuthentication.usageRequest(accessToken: credential.accessToken)
            let data = try await KiroBrowserAuthenticationHTTP.refresh(request, http: http)
            guard try KiroBuilderIDAuthentication.userID(data) == credential.principalID else {
                throw CredentialDiscoveryError.malformed(id)
            }
            return try parse(data, now: now)
        }
        guard let profileARN = credential.accountID else {
            throw CredentialDiscoveryError.malformed(id)
        }
        var request = URLRequest(
            url: try CredentialDiscovery.kiroEndpoint(profileARN: profileARN),
            timeoutInterval: 10
        )
        let endpoint = ProviderContractCatalog.endpoint(.kiroUsageLimits, for: id)
        if credential.oidcIssuer == KiroOAuthTokenResponse.issuer {
            // Kiro-Go's social bearer API uses this REST query with the token's profile ARN.
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.path = "/getUsageLimits"
            components.queryItems = [
                URLQueryItem(name: "origin", value: "AI_EDITOR"),
                URLQueryItem(name: "resourceType", value: "AGENTIC_REQUEST"),
                URLQueryItem(name: "isEmailRequired", value: "true"),
                URLQueryItem(name: "profileArn", value: profileARN)
            ]
            request.url = components.url!
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            let data = try await http.data(for: request, provider: id, operation: .safe)
            return try endpoint.schemaChecked { try parse(data, now: now) }
        }
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("AmazonCodeWhispererService.GetUsageLimits", forHTTPHeaderField: "X-Amz-Target")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["profileArn": profileARN])
        let data = try await http.data(for: request, endpoint: endpoint)
        return try endpoint.schemaChecked {
            try parse(data, now: now)
        }
    }

    private func refreshBuilderID(_ credential: DiscoveredCredential, now: Date) async throws -> ProviderUsage {
        guard CredentialDiscovery.isAppOwnedKiroOAuth(credential),
              case .accountSnapshot(let identity) = credential.storage,
              identity.accountID == accountID
        else { throw CredentialDiscoveryError.expired(id) }
        let request = try KiroBuilderIDAuthentication.refreshRequest(credential, now: now)
        let data = try await KiroBrowserAuthenticationHTTP.refresh(request, http: http)
        try Task.checkCancellation()
        let snapshot = try KiroBuilderIDAuthentication.refreshedSnapshot(
            data, original: CredentialSnapshot(credential), now: now
        )
        // AWS OIDC returns no identity: validate the renewed bearer against the
        // pinned usage identity before storing it, including after a 401.
        let usage = try await fetch(credential: snapshot.credential(storage: .accountSnapshot(identity)), now: now)
        try Task.checkCancellation()
        _ = try discovery.persistKiroOAuth(snapshot, replacing: credential)
        return usage
    }

    private func refresh(_ credential: DiscoveredCredential, now: Date) async throws -> DiscoveredCredential {
        guard CredentialDiscovery.isAppOwnedKiroOAuth(credential),
              case .accountSnapshot(let identity) = credential.storage,
              identity.accountID == accountID,
              let refreshToken = credential.refreshToken
        else { throw CredentialDiscoveryError.expired(id) }
        var request = URLRequest(
            url: URL(string: KiroOAuthTokenResponse.issuer + "/refreshToken")!,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])
        let data = try await KiroBrowserAuthenticationHTTP.refresh(request, http: http)
        try Task.checkCancellation()
        let snapshot = try KiroOAuthTokenResponse.snapshot(
            data, now: now, replacing: CredentialSnapshot(credential)
        )
        return try discovery.persistKiroOAuth(snapshot, replacing: credential)
    }

    private func parse(_ data: Data, now: Date) throws -> ProviderUsage {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let credits = response.usageBreakdownList.filter { $0.resourceType == "CREDIT" }
        guard credits.count == 1, let credit = credits.first else {
            throw UsageParsingError.invalidPayload
        }
        let limit = credit.usageLimitWithPrecision
        let total = credit.currentUsageWithPrecision
        let overage = credit.currentOveragesWithPrecision ?? 0
        guard
            [limit, total, overage].allSatisfy({ $0.isFinite && $0 >= 0 }),
            total >= overage,
            let reset = credit.nextDateReset ?? response.nextDateReset,
            reset.isFinite,
            (1_000_000_000...4_102_444_800).contains(reset)
        else {
            throw UsageParsingError.invalidPayload
        }
        let planUsed = total - overage
        // Bonus spend is folded into total usage; the API does not separate
        // plan attribution. Do not manufacture a plan percentage for these accounts.
        let ambiguous = !(credit.bonuses ?? []).isEmpty || credit.freeTrialInfo != nil
        guard ambiguous || planUsed <= limit else {
            throw UsageParsingError.invalidPayload
        }
        let metric: UsageMetric
        if ambiguous || limit == 0 {
            metric = .informational(value: "플랜 잔여량 확인 불가")
        } else {
            metric = .quotaRemaining(percent: Int(((limit - planUsed) / limit * 100).rounded()))
        }
        return ProviderUsage(
            provider: id,
            accountID: accountID,
            accountLabel: accountLabel,
            planName: response.subscriptionInfo?.subscriptionTitle ?? "Kiro",
            groups: [
                UsageGroup(
                    id: "kiro-credits",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "kiro-plan",
                            title: "플랜 크레딧",
                            period: .extra,
                            metric: metric,
                            resetsAt: Date(timeIntervalSince1970: reset),
                            showsMenuBarBadge: !ambiguous && limit > 0
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    private struct Response: Decodable {
        let usageBreakdownList: [Breakdown]
        let nextDateReset: Double?
        let subscriptionInfo: Subscription?
    }

    private struct Subscription: Decodable {
        let subscriptionTitle: String?
    }

    private struct Breakdown: Decodable {
        let resourceType: String
        let usageLimitWithPrecision: Double
        let currentUsageWithPrecision: Double
        let currentOveragesWithPrecision: Double?
        let nextDateReset: Double?
        let bonuses: [AdditionalCredits]?
        let freeTrialInfo: AdditionalCredits?
    }

    private struct AdditionalCredits: Decodable {}
}
