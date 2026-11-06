import Foundation
import OmoUsageCore

/// Runs OpenRouter's documented OAuth PKCE flow inside the app. A successful
/// sign-in mints a user API key, which the caller saves exactly like a key
/// pasted into Settings.
@MainActor
struct OpenRouterBrowserAuthenticationClient {
    nonisolated static let authorizeURL = URL(string: "https://openrouter.ai/auth")!
    nonisolated static let keyURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
    nonisolated static let keyLabel = "OmoUsage"
    nonisolated static let maximumBodyBytes = 16_384

    private let exchange: ClaudeBrowserAuthenticationClient.Exchange
    private let timeout: ClaudeBrowserAuthenticationClient.Timeout

    init(
        exchange: ClaudeBrowserAuthenticationClient.Exchange? = nil,
        timeout: ClaudeBrowserAuthenticationClient.Timeout? = nil
    ) {
        self.exchange = exchange ?? { try await OpenRouterBrowserAuthenticationHTTP.exchange($0) }
        self.timeout = timeout ?? { try await Task.sleep(for: .seconds(600)) }
    }

    func authenticate(openURL: @MainActor (URL) async -> Bool) async throws -> String {
        try Task.checkCancellation()
        let verifier = try ClaudeBrowserAuthenticationClient.randomValue()
        let state = try ClaudeBrowserAuthenticationClient.randomValue()
        let flow = try ClaudeBrowserAuthenticationAttempt(
            state: state,
            callback: BrowserAuthenticationCallback(
                providerName: "OpenRouter",
                redirectHost: "localhost",
                path: "/callback",
                ports: [],
                allowsEphemeralPort: true
            ),
            exchange: exchange,
            now: { Date() },
            tokenRequest: { code, _ in try Self.keyRequest(code: code, verifier: verifier) },
            snapshot: { data, _ in try Self.keySnapshot(data) }
        )
        return try await flow.run(timeout: timeout, openURL: openURL) {
            Self.authorizationURL(callbackURL: $0, verifier: verifier, state: state)
        }.accessToken
    }

    nonisolated static func authorizationURL(
        callbackURL: String,
        verifier: String,
        state: String
    ) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL),
            URLQueryItem(
                name: "code_challenge",
                value: ClaudeBrowserAuthenticationClient.challenge(for: verifier)
            ),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "key_label", value: keyLabel),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    nonisolated static func keyRequest(code: String, verifier: String) throws -> URLRequest {
        var request = URLRequest(url: keyURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "code": code,
                "code_verifier": verifier,
                "code_challenge_method": "S256"
            ],
            options: [.sortedKeys]
        )
        return request
    }

    /// The attempt runner speaks in snapshots; the minted key travels as the
    /// snapshot's access token and is never persisted in this shape.
    nonisolated static func keySnapshot(_ data: Data) throws -> CredentialSnapshot {
        guard data.count <= maximumBodyBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = (root["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
        else { throw ClaudeBrowserAuthenticationError.invalidToken }
        return CredentialSnapshot(
            provider: .openrouter,
            accessToken: key,
            refreshToken: nil,
            accountReference: nil,
            planName: nil,
            expiresAt: nil,
            source: .keychain
        )
    }
}

enum OpenRouterBrowserAuthenticationHTTP {
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
                endpoint: ProviderContractCatalog.endpoint(.openRouterKeyExchange, for: .openrouter)
            )
        } catch {
            try Task.checkCancellation()
            throw ClaudeBrowserAuthenticationError.exchangeFailed
        }
    }
}
