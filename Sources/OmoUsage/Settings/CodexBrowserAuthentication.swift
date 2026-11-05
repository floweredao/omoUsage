import Foundation
import OmoUsageCore

/// Runs ChatGPT's browser OAuth for Codex (PKCE, loopback callback) inside the
/// app, with the client and redirect ports the official Codex CLI registers.
/// It never launches the CLI or writes `~/.codex/auth.json`: the grant comes
/// back as a snapshot the caller stores as an app-owned secret.
@MainActor
struct CodexBrowserAuthenticationClient {
    nonisolated static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    nonisolated static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    nonisolated static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    nonisolated static let scopes = "openid profile email offline_access"
    /// The only redirect ports allow-listed for this client.
    nonisolated static let callbackPorts: [UInt16] = [1455, 1457]
    nonisolated static let maximumBodyBytes = 65_536

    private let exchange: ClaudeBrowserAuthenticationClient.Exchange
    private let timeout: ClaudeBrowserAuthenticationClient.Timeout
    private let now: @MainActor () -> Date
    private let ports: [UInt16]

    init(
        exchange: ClaudeBrowserAuthenticationClient.Exchange? = nil,
        timeout: ClaudeBrowserAuthenticationClient.Timeout? = nil,
        now: (@MainActor () -> Date)? = nil,
        ports: [UInt16] = CodexBrowserAuthenticationClient.callbackPorts
    ) {
        self.exchange = exchange ?? { try await CodexBrowserAuthenticationHTTP.exchange($0) }
        self.timeout = timeout ?? { try await Task.sleep(for: .seconds(600)) }
        self.now = now ?? { Date() }
        self.ports = ports
    }

    func authenticate(
        openURL: @MainActor (URL) async -> Bool
    ) async throws -> CredentialSnapshot {
        try Task.checkCancellation()
        let verifier = try ClaudeBrowserAuthenticationClient.randomValue()
        let state = try ClaudeBrowserAuthenticationClient.randomValue()
        let flow = try ClaudeBrowserAuthenticationAttempt(
            state: state,
            callback: BrowserAuthenticationCallback(
                providerName: "Codex",
                redirectHost: "127.0.0.1",
                path: "/auth/callback",
                ports: ports,
                allowsEphemeralPort: false
            ),
            exchange: exchange,
            now: now,
            tokenRequest: { code, redirectURI in
                Self.tokenRequest(code: code, verifier: verifier, redirectURI: redirectURI)
            },
            snapshot: { try Self.snapshot($0, now: $1) }
        )
        return try await flow.run(timeout: timeout, openURL: openURL) {
            Self.authorizationURL(redirectURI: $0, verifier: verifier, state: state)
        }
    }

    nonisolated static func authorizationURL(
        redirectURI: String,
        verifier: String,
        state: String
    ) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(
                name: "code_challenge",
                value: ClaudeBrowserAuthenticationClient.challenge(for: verifier)
            ),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    nonisolated static func tokenRequest(
        code: String,
        verifier: String,
        redirectURI: String
    ) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OmoUsage", forHTTPHeaderField: "User-Agent")
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let body = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", verifier)
        ].map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// Builds the same snapshot discovery derives from a Codex `auth.json`:
    /// the ChatGPT account id comes from the ID token's auth claim, and the
    /// deadline from the access token's `exp`.
    nonisolated static func snapshot(_ data: Data, now: Date) throws -> CredentialSnapshot {
        guard data.count <= maximumBodyBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = token(root["access_token"]),
              let refreshToken = token(root["refresh_token"]),
              let idToken = token(root["id_token"]),
              let claims = CredentialDiscovery.codexJWTPayload(idToken),
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = token(auth["chatgpt_account_id"])
        else { throw ClaudeBrowserAuthenticationError.invalidToken }
        let expiresAt = CredentialDiscovery.codexJWTPayload(accessToken)
            .flatMap { UsageJSON.number($0["exp"]) }
            .map { Date(timeIntervalSince1970: $0) }
            ?? UsageJSON.number(root["expires_in"]).map { now.addingTimeInterval($0) }
        return CredentialSnapshot(
            provider: .codex,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountReference: accountID,
            planName: nil,
            expiresAt: expiresAt,
            source: .keychain,
            email: CredentialDiscovery.codexIdentityEmail(idToken)
                ?? CredentialDiscovery.codexIdentityEmail(accessToken)
        )
    }

    nonisolated private static func token(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
        else { return nil }
        return text
    }
}

enum CodexBrowserAuthenticationHTTP {
    /// Runs the exchange through the `.codexTokenExchange` contract on a
    /// private ephemeral session that refuses redirects. The configuration
    /// seam is for URLProtocol fixtures; production always uses ephemeral.
    static func exchange(
        _ request: URLRequest,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Data {
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: ClaudeBrowserAuthenticationRedirectBlocker(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        do {
            return try await ProviderHTTP(session: session).data(
                for: request,
                endpoint: ProviderContractCatalog.endpoint(.codexTokenExchange, for: .codex)
            )
        } catch {
            try Task.checkCancellation()
            throw ClaudeBrowserAuthenticationError.exchangeFailed
        }
    }
}
