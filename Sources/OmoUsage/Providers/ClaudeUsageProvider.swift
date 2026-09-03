import OmoUsageCore
import Foundation
import Security

struct ClaudeDesktopSession: Equatable, Sendable {
    let organizationID: String
    let cookieHeader: String
}

struct ClaudeDesktopSessionDiscovery: Sendable {
    let current: @Sendable () throws -> ClaudeDesktopSession?

    static let unavailable = ClaudeDesktopSessionDiscovery {
        nil
    }
}

struct ClaudeUsageProvider: UsageProvider {
    /// Claude Code's own grant. The endpoint issues a token scoped to what
    /// it is asked for, so a narrower request silently loses capabilities.
    static let oauthScope = """
        user:profile user:inference \
        user:sessions:claude_code user:mcp_servers \
        user:file_upload
        """
    /// Refresh inside a guard band instead of at the deadline: the dashboard
    /// polls on a timer, and a token that expires mid-flight reads as a
    /// revoked credential.
    static let refreshLeadTime: TimeInterval = 300

    let id = ProviderID.claude
    let accountID: AccountID
    let accountLabel: String
    let discovery: CredentialDiscovery
    let http: ProviderHTTP
    let desktopUsageURL: URL
    let desktopSessionDiscovery: ClaudeDesktopSessionDiscovery
    let tokenEndpoint: URL
    let oauthClientID: String
    let refreshCooldown: ClaudeRefreshCooldown
    let usageCooldown: ClaudeUsageCooldown

    init(
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue,
        discovery: CredentialDiscovery = .live(),
        http: ProviderHTTP = ProviderHTTP(),
        desktopUsageURL: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(
                components: "Library",
                "Application Support",
                "Claude",
                "plan-usage-history.json"
            ),
        desktopSessionDiscovery: ClaudeDesktopSessionDiscovery = .live(),
        // TOKEN_URL as shipped in Claude Code 2.1.220; the older
        // console.anthropic.com host is no longer the CLI's endpoint.
        tokenEndpoint: URL = URL(
            string: "https://platform.claude.com/v1/oauth/token"
        )!,
        oauthClientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        refreshCooldown: ClaudeRefreshCooldown = .shared,
        usageCooldown: ClaudeUsageCooldown = .shared
    ) {
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.discovery = discovery
        self.http = http
        self.desktopUsageURL = desktopUsageURL
        self.desktopSessionDiscovery = desktopSessionDiscovery
        self.tokenEndpoint = tokenEndpoint
        self.oauthClientID = oauthClientID
        self.refreshCooldown = refreshCooldown
        self.usageCooldown = usageCooldown
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        let stored: DiscoveredCredential
        do {
            stored = try discovery.claude(
                accountID: accountID,
                now: now,
                allowingExpired: true
            )
        } catch let discoveryError as CredentialDiscoveryError {
            return try await fetchDesktopUsage(
                now: now,
                cause: discoveryError,
                allowsCachedHistory: true
            )
        }
        // A throttled account stays throttled: reissuing the read (or
        // rotating the token to retry it) is what turns a 429 into a
        // longer ban. Surface the same transient failure so the dashboard
        // keeps showing last-good usage.
        guard await usageCooldown.allowsAttempt(
            for: accountProviderID,
            at: now
        ) else {
            throw ProviderTransportError.requestFailed(id, 429)
        }
        // Only an auth rejection says anything about *which* credential we
        // picked. A 500, a 429, a malformed payload or a lost rotation are
        // facts about the request, so replaying them against every other
        // stored credential just multiplies the damage.
        var candidates = discovery.claudeCandidates(
            accountID: accountID,
            now: now,
            allowingExpired: true
        )
        if candidates.isEmpty {
            candidates = [stored]
        }
        var authFailure: any Error = ProviderTransportError
            .authenticationRequired(id)
        for candidate in candidates {
            do {
                return try await oauthUsage(for: candidate, now: now)
            } catch is CancellationError {
                throw CancellationError()
            } catch let contractError as ProviderContractError {
                throw contractError
            } catch let error as ProviderTransportError
                where error == .authenticationRequired(id)
            {
                authFailure = error
            } catch {
                throw error
            }
        }
        return try await fetchDesktopUsage(
            now: now,
            cause: authFailure,
            allowsCachedHistory: false
        )
    }

    /// One credential's full attempt: rotate it if it is at or past the
    /// guard band, read usage, and rotate once more if a token the clock
    /// still trusts turns out to be revoked.
    private func oauthUsage(
        for candidate: DiscoveredCredential,
        now: Date
    ) async throws -> ProviderUsage {
        var credential = candidate
        var didRefresh = false
        if
            let expiresAt = credential.expiresAt,
            expiresAt.timeIntervalSince(now) <= Self.refreshLeadTime
        {
            guard await refreshCooldown.allowsAttempt(
                for: accountProviderID,
                at: now
            ) else {
                throw ProviderTransportError.authenticationRequired(id)
            }
            credential = try await refreshedCredential(
                credential,
                now: now
            )
            didRefresh = true
        }
        do {
            return try await fetchOAuthUsage(credential, now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch let contractError as ProviderContractError {
            throw contractError
        } catch {
            // A token the clock still considers valid can be rejected after
            // a revoke or a clock skew; rotate once before giving up.
            if
                !didRefresh,
                credential.refreshToken != nil,
                error as? ProviderTransportError
                    == .authenticationRequired(id),
                await refreshCooldown.allowsAttempt(
                    for: accountProviderID,
                    at: now
                )
            {
                let rotated = try await refreshedCredential(
                    credential,
                    now: now
                )
                return try await fetchOAuthUsage(rotated, now: now)
            }
            throw error
        }
    }

    private func fetchOAuthUsage(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> ProviderUsage {
        let endpoint = ProviderContractCatalog.endpoint(
            .claudeOAuthUsage,
            for: id
        )
        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!
        )
        request.timeoutInterval = 10
        request.setValue(
            "Bearer \(credential.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "oauth-2025-04-20",
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue(
            "claude-code/2.1.69",
            forHTTPHeaderField: "User-Agent"
        )
        let data: Data
        do {
            data = try await http.data(for: request, endpoint: endpoint)
        } catch {
            if
                error as? ProviderTransportError
                    == .requestFailed(id, 429)
            {
                await usageCooldown.recordRateLimit(
                    for: accountProviderID,
                    at: now
                )
            }
            throw error
        }
        let usage = try endpoint.schemaChecked {
            try ClaudeUsageParser.parse(
                data,
                planName: credential.planName ?? "",
                now: now
            )
        }
        await usageCooldown.recordSuccess(for: accountProviderID)
        return usage
    }

    /// Exchanges the stored refresh token for a fresh access token and writes
    /// the rotated pair back where Claude Code keeps it, so the CLI and this
    /// app stay on the same credential chain.
    private func refreshedCredential(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> DiscoveredCredential {
        guard let refreshToken = credential.refreshToken else {
            throw ProviderTransportError.authenticationRequired(id)
        }
        let endpoint = ProviderContractCatalog.endpoint(
            .claudeTokenRefresh,
            for: id
        )
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": oauthClientID,
                "scope": Self.oauthScope
            ],
            options: [.sortedKeys]
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The token endpoint sorts unrecognised clients into a throttle that
        // answers 429 before validating the grant at all; the CLI agent
        // string is what gets the request served.
        request.setValue(
            "claude-cli/2.1.220 (external, cli)",
            forHTTPHeaderField: "User-Agent"
        )
        let data: Data
        do {
            data = try await http.data(for: request, endpoint: endpoint)
        } catch {
            await refreshCooldown.recordFailure(
                for: accountProviderID,
                at: now
            )
            DiagnosticStore.shared.record(
                error: error,
                provider: id,
                category: .providerRefresh
            )
            if
                error as? ProviderTransportError
                    == .requestFailed(id, 400)
            {
                throw ProviderTransportError.authenticationRequired(id)
            }
            throw error
        }
        await refreshCooldown.recordSuccess(for: accountProviderID)
        let (payload, accessToken, expiresIn) = try endpoint.schemaChecked {
            let payload = try ProviderPayload.object(data)
            guard
                let accessToken = ProviderPayload.text(
                    payload,
                    paths: [["access_token"]]
                ),
                let expiresIn = ProviderPayload.number(
                    payload,
                    paths: [["expires_in"]]
                )
            else {
                throw ProviderTransportError.invalidResponse(id)
            }
            return (payload, accessToken, expiresIn)
        }
        let rotatedRefreshToken = ProviderPayload.text(
            payload,
            paths: [["refresh_token"]]
        ) ?? refreshToken
        let expiresAt = now.addingTimeInterval(expiresIn)
        // A rotated token that cannot be written back is lost: the grant is
        // already spent, so reporting usage here would strand the account
        // behind a credential nobody can read next launch.
        do {
            try discovery.persistClaudeCredential(
                accessToken: accessToken,
                refreshToken: rotatedRefreshToken,
                expiresAt: expiresAt,
                source: credential.source,
                storage: credential.storage
            )
        } catch {
            DiagnosticStore.shared.record(
                error: error,
                provider: id,
                category: .credentialPersistence
            )
            throw error
        }
        return DiscoveredCredential(
            provider: id,
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            accountID: credential.accountID,
            planName: credential.planName,
            expiresAt: expiresAt,
            source: credential.source,
            storage: credential.storage
        )
    }

    private func fetchDesktopUsage(
        now: Date,
        cause: Error,
        allowsCachedHistory: Bool
    ) async throws -> ProviderUsage {
        let session: ClaudeDesktopSession?
        do {
            session = try desktopSessionDiscovery.current()
        } catch let error as KeychainReadError
            where error.status == errSecInteractionNotAllowed
        {
            logDesktopFailure(error)
            let authenticationFailure =
                ProviderTransportError.authenticationRequired(id)
            if allowsCachedHistory {
                return try cachedDesktopUsage(
                    now: now,
                    cause: authenticationFailure
                )
            }
            throw authenticationFailure
        } catch {
            logDesktopFailure(error)
            if
                !allowsCachedHistory,
                cause as? ProviderTransportError
                    == .authenticationRequired(id)
            {
                throw cause
            }
            throw error
        }
        guard let session else {
            if allowsCachedHistory {
                return try cachedDesktopUsage(now: now, cause: cause)
            }
            throw cause
        }
        do {
            return try await fetchDesktopSessionUsage(
                session,
                now: now
            )
        } catch {
            logDesktopFailure(error)
            throw error
        }
    }

    private func fetchDesktopSessionUsage(
        _ session: ClaudeDesktopSession,
        now: Date
    ) async throws -> ProviderUsage {
        let endpoint = ProviderContractCatalog.endpoint(
            .claudeDesktopUsage,
            for: id
        )
        let organizationID = session.organizationID
            .addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? session.organizationID
        var request = URLRequest(
            url: URL(
                string: "https://claude.ai/api/organizations/"
                    + organizationID
                    + "/usage"
            )!
        )
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            session.cookieHeader,
            forHTTPHeaderField: "Cookie"
        )
        request.setValue(
            "https://claude.ai",
            forHTTPHeaderField: "Origin"
        )
        request.setValue(
            "https://claude.ai/settings/usage",
            forHTTPHeaderField: "Referer"
        )
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) "
                + "Chrome/140.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let data = try await http.data(for: request, endpoint: endpoint)
        return try endpoint.schemaChecked {
            try ClaudeUsageParser.parse(
                data,
                planName: "Claude.ai",
                now: now
            )
        }
    }

    private func cachedDesktopUsage(
        now: Date,
        cause: Error
    ) throws -> ProviderUsage {
        guard
            let data = try? Data(contentsOf: desktopUsageURL),
            let usage = try? ClaudeUsageParser.parseDesktopHistory(
                data,
                now: now
            )
        else {
            throw cause
        }
        return usage
    }

    private func logDesktopFailure(_ error: Error) {
        DiagnosticStore.shared.record(
            error: error,
            provider: id,
            category: .desktopSession
        )
    }
}
