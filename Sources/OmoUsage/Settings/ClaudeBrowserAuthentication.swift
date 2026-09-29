import Foundation
import CryptoKit
import Security
import OmoUsageCore

enum ClaudeBrowserAuthenticationError: Error, Equatable {
    case browserOpenFailed
    case timedOut
    case listenerFailed
    case authorizationDenied
    case stateMismatch
    case exchangeFailed
    case invalidToken
    case randomGenerationFailed
}

/// Runs Claude's browser OAuth (PKCE, loopback callback) inside the app. It
/// never launches the Claude CLI or touches a Claude Code Keychain item: the
/// grant comes back as a snapshot the caller stores as an app-owned secret.
@MainActor
struct ClaudeBrowserAuthenticationClient {
    typealias Exchange = @MainActor (URLRequest) async throws -> Data
    typealias Timeout = @MainActor () async throws -> Void

    nonisolated static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    nonisolated static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    nonisolated static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    nonisolated static let scopes = "org:create_api_key user:profile user:inference "
        + "user:sessions:claude_code user:mcp_servers user:file_upload"
    nonisolated static let preferredCallbackPort: UInt16 = 53692
    nonisolated static let maximumBodyBytes = 65_536

    private let exchange: Exchange
    private let timeout: Timeout
    private let now: @MainActor () -> Date
    private let preferredPort: UInt16

    init(
        exchange: Exchange? = nil,
        timeout: Timeout? = nil,
        now: (@MainActor () -> Date)? = nil,
        preferredPort: UInt16 = ClaudeBrowserAuthenticationClient.preferredCallbackPort
    ) {
        self.exchange = exchange ?? { try await ClaudeBrowserAuthenticationHTTP.exchange($0) }
        self.timeout = timeout ?? { try await Task.sleep(for: .seconds(600)) }
        self.now = now ?? { Date() }
        self.preferredPort = preferredPort
    }

    func authenticate(
        openURL: @MainActor (URL) async -> Bool
    ) async throws -> CredentialSnapshot {
        try Task.checkCancellation()
        // Claude's authorize endpoint echoes the verifier back as `state`.
        let verifier = try Self.randomValue()
        let flow = try ClaudeBrowserAuthenticationAttempt(
            verifier: verifier,
            preferredPort: preferredPort,
            exchange: exchange,
            now: now
        )
        return try await withTaskCancellationHandler {
            flow.startTimeout(timeout)
            do {
                let redirect = try await flow.listener.start()
                try Task.checkCancellation()
                try flow.checkActive()
                flow.redirectURI = redirect.absoluteString
                let opened = await openURL(
                    Self.authorizationURL(redirectURI: redirect.absoluteString, verifier: verifier)
                )
                try Task.checkCancellation()
                // An async opener can return after cancellation or the deadline.
                try flow.checkActive()
                guard opened else { throw ClaudeBrowserAuthenticationError.browserOpenFailed }
                let snapshot = try await flow.value()
                await flow.listener.close()
                try Task.checkCancellation()
                return snapshot
            } catch {
                flow.finish(.failure(error))
                await flow.listener.close()
                try Task.checkCancellation()
                // Stopping a listener that is still binding reports listenerFailed to
                // start(); retain the timeout/cancellation that actually ended the attempt.
                try flow.checkActive()
                throw error
            }
        } onCancel: {
            Task { @MainActor in flow.finish(.failure(CancellationError())) }
        }
    }

    nonisolated static func authorizationURL(redirectURI: String, verifier: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier)
        ]
        return components.url!
    }

    nonisolated static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    nonisolated static func tokenRequest(
        code: String,
        state: String,
        verifier: String,
        redirectURI: String
    ) throws -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClaudeUsageProvider.cliUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "code": code,
                "state": state,
                "redirect_uri": redirectURI,
                "code_verifier": verifier
            ],
            options: [.sortedKeys]
        )
        return request
    }

    nonisolated static func snapshot(_ data: Data, now: Date) throws -> CredentialSnapshot {
        guard data.count <= maximumBodyBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = token(root["access_token"]),
              let refreshToken = token(root["refresh_token"]),
              let expiresIn = UsageJSON.number(root["expires_in"]),
              expiresIn.isFinite, expiresIn > 0
        else { throw ClaudeBrowserAuthenticationError.invalidToken }
        let account = root["account"] as? [String: Any]
        return CredentialSnapshot(
            provider: .claude,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountReference: nil,
            planName: nil,
            expiresAt: now.addingTimeInterval(expiresIn),
            source: .keychain,
            email: account?["email_address"] as? String
        )
    }

    nonisolated private static func token(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
        else { return nil }
        return text
    }

    nonisolated private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ClaudeBrowserAuthenticationError.randomGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    nonisolated private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class ClaudeBrowserAuthenticationAttempt {
    let listener: ClaudeBrowserAuthenticationListener
    var redirectURI = ""
    private let verifier: String
    private let exchange: ClaudeBrowserAuthenticationClient.Exchange
    private let now: @MainActor () -> Date
    private var result: Result<CredentialSnapshot, Error>?
    private var continuation: CheckedContinuation<CredentialSnapshot, Error>?
    private var exchangeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        verifier: String,
        preferredPort: UInt16,
        exchange: @escaping ClaudeBrowserAuthenticationClient.Exchange,
        now: @escaping @MainActor () -> Date
    ) throws {
        self.verifier = verifier
        self.exchange = exchange
        self.now = now
        listener = try ClaudeBrowserAuthenticationListener(
            state: verifier, preferredPort: preferredPort
        )
        listener.callback = { [weak self] result in self?.received(result) }
    }

    func startTimeout(_ timeout: @escaping ClaudeBrowserAuthenticationClient.Timeout) {
        timeoutTask = Task { [weak self] in
            do {
                try await timeout()
                try Task.checkCancellation()
                self?.finish(.failure(ClaudeBrowserAuthenticationError.timedOut))
            } catch {
                if !Task.isCancelled {
                    self?.finish(.failure(ClaudeBrowserAuthenticationError.timedOut))
                }
            }
        }
    }

    func checkActive() throws {
        if let result { _ = try result.get() }
    }

    func value() async throws -> CredentialSnapshot {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<CredentialSnapshot, Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeoutTask?.cancel()
        timeoutTask = nil
        exchangeTask?.cancel()
        exchangeTask = nil
        listener.stop()
        continuation?.resume(with: result)
        continuation = nil
    }

    private func received(_ callback: Result<String, ClaudeBrowserAuthenticationError>) {
        guard result == nil, exchangeTask == nil else { return }
        switch callback {
        case .failure(let error):
            finish(.failure(error))
        case .success(let code):
            exchangeTask = Task { [weak self, exchange, verifier, redirectURI, now] in
                do {
                    try Task.checkCancellation()
                    let request = try ClaudeBrowserAuthenticationClient.tokenRequest(
                        code: code, state: verifier, verifier: verifier, redirectURI: redirectURI
                    )
                    let data = try await exchange(request)
                    try Task.checkCancellation()
                    let snapshot = try ClaudeBrowserAuthenticationClient.snapshot(data, now: now())
                    self?.finish(.success(snapshot))
                } catch {
                    let safeError: Error
                    if error is CancellationError { safeError = CancellationError() }
                    else if let typed = error as? ClaudeBrowserAuthenticationError { safeError = typed }
                    else { safeError = ClaudeBrowserAuthenticationError.exchangeFailed }
                    self?.finish(.failure(safeError))
                }
            }
        }
    }
}

enum ClaudeBrowserAuthenticationHTTP {
    /// Runs the exchange through the `.claudeTokenExchange` contract on a
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
                endpoint: ProviderContractCatalog.endpoint(.claudeTokenExchange, for: .claude)
            )
        } catch {
            try Task.checkCancellation()
            throw ClaudeBrowserAuthenticationError.exchangeFailed
        }
    }
}

final class ClaudeBrowserAuthenticationRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
