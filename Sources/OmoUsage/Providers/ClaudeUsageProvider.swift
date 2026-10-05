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
    /// The refresh cooldown refused to spend the grant and the stored access
    /// token has already expired, so this candidate cannot be read now.
    private struct RefreshCoolingDown: Error {}

    /// Refresh inside a guard band instead of at the deadline: the dashboard
    /// polls on a timer, and a token that expires mid-flight reads as a
    /// revoked credential.
    static let refreshLeadTime: TimeInterval = 300
    /// The usage and token endpoints only serve Claude Code's own agent
    /// string. Reset vouchers (`cedar_ember`) also require a recent CLI
    /// version: older ones get `ineligible_reason: "cli_version"`, and
    /// 2.1.258 still predates voucher support.
    static let cliUserAgent = "claude-cli/2.1.280 (external, cli)"

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
    let refreshCoordinator: ClaudeRefreshCoordinator
    let planCache: ClaudePlanCache
    /// `nil` reads live on every fetch; the app passes `.shared`.
    let usageCache: ClaudeUsageCache?
    /// `nil` publishes nothing; the app passes `.live`.
    let shareStore: ClaudeUsageShareStore?

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
        usageCooldown: ClaudeUsageCooldown = .shared,
        refreshCoordinator: ClaudeRefreshCoordinator =
            ClaudeRefreshCoordinator(),
        planCache: ClaudePlanCache = ClaudePlanCache(),
        usageCache: ClaudeUsageCache? = nil,
        shareStore: ClaudeUsageShareStore? = nil
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
        self.refreshCoordinator = refreshCoordinator
        self.planCache = planCache
        self.usageCache = usageCache
        self.shareStore = shareStore
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
        // A recent read is still the answer: the endpoint's budget is shared
        // with every other program reading this account, manual refreshes
        // included.
        if let cached = await usageCache?.usage(
            for: accountProviderID,
            at: now
        ) {
            return cached
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
        var coolingDown = false
        for candidate in candidates {
            do {
                return try await oauthUsage(for: candidate, now: now)
            } catch is RefreshCoolingDown {
                coolingDown = true
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
        // A cooling refresh is a pause, not a lost login: report it as a
        // transient throttle so the dashboard keeps last-good usage instead
        // of dropping the card behind the Desktop fallback.
        if coolingDown {
            throw ProviderTransportError.requestFailed(id, 429)
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
            if await refreshCooldown.allowsAttempt(
                for: accountProviderID,
                at: now
            ) {
                credential = try await sharedRefresh(credential, now: now)
                didRefresh = true
            } else if expiresAt <= now {
                throw RefreshCoolingDown()
            }
            // Otherwise the token is inside the guard band but still valid:
            // read with it rather than refusing while the cooldown runs.
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
                let rotated = try await sharedRefresh(
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
            url: URL(
                string: "https://api.anthropic.com/api/oauth/usage"
                    + "?cedar_ember=1&skip_spend=1"
            )!
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
        request.setValue(Self.cliUserAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            data = try await http.data(
                for: request,
                endpoint: endpoint,
                detailingStatusFailures: true
            )
        } catch let failure as ProviderHTTPStatusFailure {
            if failure.transportError == .requestFailed(id, 429) {
                let blockedUntil = await usageCooldown.recordRateLimit(
                    for: accountProviderID,
                    at: now,
                    retryAfter: failure.retryAfter
                )
                await shareStore?.recordRateLimit(
                    until: blockedUntil,
                    for: accountID,
                    label: accountLabel,
                    at: now
                )
            }
            DiagnosticStore.shared.record(
                error: failure.transportError,
                provider: id,
                category: .providerRefresh
            )
            throw failure.transportError
        }
        let planName = try await resolvedPlanName(
            for: credential,
            now: now
        )
        let usage = try endpoint.schemaChecked {
            try ClaudeUsageParser.parse(
                data,
                planName: planName,
                now: now
            )
        }
        await usageCooldown.recordSuccess(for: accountProviderID)
        await usageCache?.record(usage, for: accountProviderID, at: now)
        await shareStore?.recordSuccess(
            data,
            for: accountID,
            label: accountLabel,
            at: now
        )
        return usage
    }

    /// The credential's own plan, else the account's OAuth profile plan.
    /// An in-app browser grant carries no plan, so the profile is read once
    /// per account after a successful usage read; a failed read only leaves
    /// the plan blank and waits out `ClaudePlanCache`'s retry interval.
    private func resolvedPlanName(
        for credential: DiscoveredCredential,
        now: Date
    ) async throws -> String {
        if let plan = credential.planName, !plan.isEmpty {
            return plan
        }
        if let plan = await planCache.plan(for: accountProviderID) {
            return plan
        }
        guard await planCache.allowsLookup(
            for: accountProviderID,
            at: now
        ) else {
            return ""
        }
        do {
            let plan = try await fetchProfilePlanName(credential)
            await planCache.record(plan, for: accountProviderID)
            return plan
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await planCache.recordFailure(
                for: accountProviderID,
                at: now
            )
            DiagnosticStore.shared.record(
                error: error,
                provider: id,
                category: .providerRefresh
            )
            return ""
        }
    }

    private func fetchProfilePlanName(
        _ credential: DiscoveredCredential
    ) async throws -> String {
        let endpoint = ProviderContractCatalog.endpoint(
            .claudeOAuthProfile,
            for: id
        )
        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/api/oauth/profile")!
        )
        request.timeoutInterval = 10
        request.setValue(
            "Bearer \(credential.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "oauth-2025-04-20",
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue(Self.cliUserAgent, forHTTPHeaderField: "User-Agent")
        let data = try await http.data(for: request, endpoint: endpoint)
        guard let plan = ClaudePlanName.fromProfile(data) else {
            throw ProviderTransportError.invalidResponse(id)
        }
        return plan
    }

    /// Routes every exchange for this account through one in-flight refresh
    /// so concurrent fetches never spend the same single-use grant twice.
    private func sharedRefresh(
        _ credential: DiscoveredCredential,
        now: Date
    ) async throws -> DiscoveredCredential {
        guard let refreshToken = credential.refreshToken else {
            throw ProviderTransportError.authenticationRequired(id)
        }
        return try await refreshCoordinator.refreshed(
            for: accountProviderID,
            refreshToken: refreshToken,
            validAfter: now.addingTimeInterval(Self.refreshLeadTime)
        ) {
            try await refreshedCredential(credential, now: now)
        }
    }

    /// Exchanges the stored refresh token and persists the rotated pair to its
    /// originating store. App-authorized Keychain credentials belong to the
    /// isolated OmoUsage login, not the user's interactive Claude Code session.
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
                "client_id": oauthClientID
            ],
            options: [.sortedKeys]
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.cliUserAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            data = try await http.data(
                for: request,
                endpoint: endpoint,
                detailingStatusFailures: true
            )
        } catch let failure as ProviderHTTPStatusFailure {
            let error = failure.transportError
            await refreshCooldown.recordFailure(
                for: accountProviderID,
                at: now,
                retryAfter: error == .requestFailed(id, 429)
                    ? failure.retryAfter
                    : nil
            )
            DiagnosticStore.shared.record(
                error: error,
                provider: id,
                category: .providerRefresh
            )
            // Only a spent or revoked grant means the login is gone; any
            // other 400 (a rejected scope, a malformed request) is a fault
            // in the request, not in the user's credential.
            if
                error == .requestFailed(id, 400),
                failure.oauthErrorCode == "invalid_grant"
            {
                throw ProviderTransportError.authenticationRequired(id)
            }
            throw error
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
        } catch let error as ClaudeDesktopSessionError
            where error == .keychainUnavailable || error == .cookiesUnavailable
        {
            logDesktopFailure(error)
            throw ProviderTransportError.authenticationRequired(id)
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
                    + "/usage?cedar_ember=1&skip_spend=1"
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

/// Claude subscription display names, e.g. `max` + `default_claude_max_20x`
/// -> "Max 20x". Shared by Claude Code credential files and the OAuth
/// profile so both sources label a plan the same way.
enum ClaudePlanName {
    static func make(
        subscriptionType: String?,
        rateLimitTier: String?
    ) -> String? {
        guard let subscription = subscriptionType, !subscription.isEmpty
        else {
            return nil
        }
        let plan = subscription.capitalized
        guard
            let tier = rateLimitTier?.lowercased(),
            tier.contains("_\(subscription.lowercased())_"),
            let suffix = tier.split(separator: "_").last,
            suffix.last == "x",
            let multiplier = Int(suffix.dropLast()),
            multiplier > 0
        else {
            return plan
        }
        return "\(plan) \(multiplier)x"
    }

    /// Reads `GET /api/oauth/profile`: `organization.organization_type`
    /// (`claude_max`, `claude_pro`, ...) names the subscription and
    /// `organization.rate_limit_tier` carries its multiplier.
    static func fromProfile(_ data: Data) -> String? {
        guard
            let root = try? UsageJSON.object(data),
            let organization = UsageJSON.object(root["organization"]),
            let type = (organization["organization_type"] as? String)?
                .lowercased(),
            type.hasPrefix("claude_"),
            type.count > "claude_".count
        else {
            return nil
        }
        return make(
            subscriptionType: String(type.dropFirst("claude_".count)),
            rateLimitTier: organization["rate_limit_tier"] as? String
        )
    }
}

/// Each account's profile plan for this launch. A failed profile read is
/// retried only after `retryInterval`, so the plan lookup never adds load
/// to an account whose requests are failing.
actor ClaudePlanCache {
    private let retryInterval: TimeInterval
    private var plans: [AccountProviderID: String] = [:]
    private var retryAfter: [AccountProviderID: Date] = [:]

    init(retryInterval: TimeInterval = 1_800) {
        self.retryInterval = retryInterval
    }

    func plan(for accountProviderID: AccountProviderID) -> String? {
        plans[accountProviderID]
    }

    func allowsLookup(
        for accountProviderID: AccountProviderID,
        at now: Date
    ) -> Bool {
        guard let blockedUntil = retryAfter[accountProviderID] else {
            return true
        }
        return now >= blockedUntil
    }

    func record(_ plan: String, for accountProviderID: AccountProviderID) {
        plans[accountProviderID] = plan
        retryAfter[accountProviderID] = nil
    }

    func recordFailure(
        for accountProviderID: AccountProviderID,
        at now: Date
    ) {
        retryAfter[accountProviderID] = now.addingTimeInterval(retryInterval)
    }
}
