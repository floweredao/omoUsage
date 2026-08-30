import Foundation

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
        refreshCooldown: ClaudeRefreshCooldown = .shared
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
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        let stored: DiscoveredCredential
        do {
            stored = try discovery.claude(now: now, allowingExpired: true)
        } catch let discoveryError as CredentialDiscoveryError {
            return try await fetchDesktopUsage(
                now: now,
                cause: discoveryError,
                allowsCachedHistory: true
            )
        }
        var credential = stored
        var didRefresh = false
        if let expiresAt = credential.expiresAt, expiresAt <= now {
            guard await refreshCooldown.allowsAttempt(
                for: accountProviderID,
                at: now
            ) else {
                return try await fetchDesktopUsage(
                    now: now,
                    cause: ProviderTransportError
                        .authenticationRequired(id),
                    allowsCachedHistory: false
                )
            }
            do {
                credential = try await refreshedCredential(
                    credential,
                    now: now
                )
                didRefresh = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await fetchDesktopUsage(
                    now: now,
                    cause: error,
                    allowsCachedHistory: false
                )
            }
        }
        do {
            return try await fetchOAuthUsage(credential, now: now)
        } catch is CancellationError {
            throw CancellationError()
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
                do {
                    let rotated = try await refreshedCredential(
                        credential,
                        now: now
                    )
                    return try await fetchOAuthUsage(rotated, now: now)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let retryError {
                    return try await fetchDesktopUsage(
                        now: now,
                        cause: retryError,
                        allowsCachedHistory: false
                    )
                }
            }
            return try await fetchDesktopUsage(
                now: now,
                cause: error,
                allowsCachedHistory: false
            )
        }
    }

    private func fetchOAuthUsage(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> ProviderUsage {
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
        let data = try await http.data(
            for: request,
            provider: id,
            operation: .safe
        )
        return try ClaudeUsageParser.parse(
            data,
            planName: credential.planName ?? "",
            now: now
        )
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
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": oauthClientID
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
            data = try await http.data(
                for: request,
                provider: id,
                operation: .unsafe
            )
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
            throw error
        }
        await refreshCooldown.recordSuccess(for: accountProviderID)
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
        let rotatedRefreshToken = ProviderPayload.text(
            payload,
            paths: [["refresh_token"]]
        ) ?? refreshToken
        let expiresAt = now.addingTimeInterval(expiresIn)
        do {
            try discovery.persistClaudeCredential(
                accessToken: accessToken,
                refreshToken: rotatedRefreshToken,
                expiresAt: expiresAt,
                source: credential.source
            )
        } catch {
            DiagnosticStore.shared.record(
                error: error,
                provider: id,
                category: .credentialPersistence
            )
        }
        return DiscoveredCredential(
            provider: id,
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            accountID: credential.accountID,
            planName: credential.planName,
            expiresAt: expiresAt,
            source: credential.source
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
        } catch {
            logDesktopFailure(error)
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
        let data = try await http.data(
            for: request,
            provider: id,
            operation: .safe
        )
        return try ClaudeUsageParser.parse(
            data,
            planName: "Claude.ai",
            now: now
        )
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
