import Foundation
import CryptoKit
import Security

enum KiroBrowserAuthenticationError: Error, Equatable {
    case browserOpenFailed
    case timedOut
    case listenerFailed
    case authorizationDenied
    case exchangeFailed
    case invalidToken
    case randomGenerationFailed
    case unsupportedOrganization
}

/// Captures a browser credential only. The caller must persist it and validate usage.
@MainActor
struct KiroBrowserAuthenticationClient {
    typealias Exchange = @MainActor (URLRequest) async throws -> Data
    typealias Timeout = @MainActor () async throws -> Void

    private let exchange: Exchange
    private let timeout: Timeout
    private let now: @MainActor () -> Date
    private let pollWait: KiroBuilderIDAuthentication.PollWait

    init(
        exchange: Exchange? = nil,
        timeout: Timeout? = nil,
        pollWait: @escaping KiroBuilderIDAuthentication.PollWait = {
            try await Task.sleep(for: .seconds($0))
        },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.exchange = exchange ?? { try await KiroBrowserAuthenticationHTTP.exchange($0) }
        self.timeout = timeout ?? { try await Task.sleep(for: .seconds(180)) }
        self.now = now
        self.pollWait = pollWait
    }

    func authenticate(
        openURL: @escaping @MainActor (URL) async -> Bool
    ) async throws -> CredentialSnapshot {
        try Task.checkCancellation()
        let state = try Self.randomValue()
        let verifier = try Self.randomValue()
        let flow = try KiroBrowserAuthenticationAttempt(
            state: state, verifier: verifier, exchange: exchange, now: now,
            openURL: openURL, pollWait: pollWait
        )
        return try await withTaskCancellationHandler {
            flow.startTimeout(timeout)
            do {
                let redirect = try await flow.listener.start()
                try Task.checkCancellation()
                try flow.checkActive()
                var authorization = URLComponents(
                    string: "https://app.kiro.dev/signin"
                )!
                authorization.queryItems = [
                    URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
                    URLQueryItem(name: "state", value: state),
                    URLQueryItem(name: "redirect_from", value: "KiroIDE"),
                    URLQueryItem(
                        name: "code_challenge",
                        value: Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
                    ),
                    URLQueryItem(name: "code_challenge_method", value: "S256")
                ]
                let opened = await openURL(authorization.url!)
                try Task.checkCancellation()
                // An async opener can return after cancellation or the deadline.
                try flow.checkActive()
                guard opened else { throw KiroBrowserAuthenticationError.browserOpenFailed }
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

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KiroBrowserAuthenticationError.randomGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class KiroBrowserAuthenticationAttempt {
    let listener: KiroBrowserAuthenticationListener
    private let verifier: String
    private let now: @MainActor () -> Date
    private let exchange: KiroBrowserAuthenticationClient.Exchange
    private let openURL: @MainActor (URL) async -> Bool
    private let pollWait: KiroBuilderIDAuthentication.PollWait
    private var result: Result<CredentialSnapshot, Error>?
    private var continuation: CheckedContinuation<CredentialSnapshot, Error>?
    private var exchangeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        state: String,
        verifier: String,
        exchange: @escaping KiroBrowserAuthenticationClient.Exchange,
        now: @escaping @MainActor () -> Date,
        openURL: @escaping @MainActor (URL) async -> Bool,
        pollWait: @escaping KiroBuilderIDAuthentication.PollWait
    ) throws {
        self.verifier = verifier
        self.now = now
        self.exchange = exchange
        self.openURL = openURL
        self.pollWait = pollWait
        listener = try KiroBrowserAuthenticationListener(state: state)
        listener.callback = { [weak self] result in self?.received(result) }
    }

    func startTimeout(_ timeout: @escaping KiroBrowserAuthenticationClient.Timeout) {
        timeoutTask = Task { [weak self] in
            do {
                try await timeout()
                try Task.checkCancellation()
                self?.finish(.failure(KiroBrowserAuthenticationError.timedOut))
            } catch {
                if !Task.isCancelled {
                    self?.finish(.failure(KiroBrowserAuthenticationError.timedOut))
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

    private func received(_ callback: Result<KiroBrowserCallback, KiroBrowserAuthenticationError>) {
        guard result == nil, exchangeTask == nil else { return }
        switch callback {
        case .failure(let error):
            finish(.failure(error))
        case .success(let callback):
            exchangeTask = Task { [weak self, exchange, verifier, now, openURL, pollWait, listener] in
                do {
                    try Task.checkCancellation()
                    if callback == .builderID {
                        // Device authorization has no callback. Release the hosted chooser's
                        // port before opening AWS, and keep the attempt's deadline/cancel owner.
                        await listener.close()
                        try Task.checkCancellation()
                        let snapshot = try await KiroBuilderIDAuthentication(
                            exchange: exchange, pollWait: pollWait, now: now
                        ).authenticate(openURL: openURL)
                        try Task.checkCancellation()
                        self?.finish(.success(snapshot))
                        return
                    }
                    guard case .socialCode(let code) = callback else { return }
                    var request = URLRequest(url: URL(string: "https://prod.us-east-1.auth.desktop.kiro.dev/oauth/token")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 30
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(
                        TokenRequest(code: code, code_verifier: verifier, redirect_uri: "http://localhost:3128")
                    )
                    let data = try await exchange(request)
                    try Task.checkCancellation()
                    let snapshot = try KiroOAuthTokenResponse.snapshot(data, now: now())
                    self?.finish(.success(snapshot))
                } catch {
                    let safeError: Error
                    if error is CancellationError { safeError = CancellationError() }
                    else if let typed = error as? KiroBrowserAuthenticationError { safeError = typed }
                    else { safeError = KiroBrowserAuthenticationError.exchangeFailed }
                    self?.finish(.failure(safeError))
                }
            }
        }
    }

    private struct TokenRequest: Encodable {
        let code: String
        let code_verifier: String
        let redirect_uri: String
    }

}

enum KiroBrowserAuthenticationHTTP {
    static let maximumBodyBytes = 65_536

    /// Keep the injected provider transport configuration, but never forward a refresh
    /// body through HTTP redirects. The shared boundary retains typed provider errors.
    static func refresh(_ request: URLRequest, http: ProviderHTTP) async throws -> Data {
        let configuration = http.session.configuration
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(
            configuration: configuration, delegate: KiroBrowserAuthenticationRedirectBlocker(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        return try await ProviderHTTP(session: session, retryPolicy: http.retryPolicy).data(
            for: request, provider: .kiro, operation: .unsafe
        )
    }

    /// The configuration seam is for URLProtocol fixtures; production always uses ephemeral.
    static func exchange(
        _ request: URLRequest,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Data {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(
                for: request, delegate: KiroBrowserAuthenticationRedirectBlocker()
            )
            guard let http = response as? HTTPURLResponse,
                  response.expectedContentLength <= Int64(maximumBodyBytes)
            else { throw KiroBrowserAuthenticationError.exchangeFailed }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBodyBytes else {
                    throw KiroBrowserAuthenticationError.exchangeFailed
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            if http.statusCode == 400,
               request.url?.absoluteString == KiroBuilderIDAuthentication.tokenEndpoint.absoluteString {
                throw try KiroBuilderIDAuthentication.tokenError(data)
            }
            guard http.statusCode == 200 else { throw KiroBrowserAuthenticationError.exchangeFailed }
            return data
        } catch {
            try Task.checkCancellation()
            if let polling = error as? KiroBuilderIDPollingError { throw polling }
            if let typed = error as? KiroBrowserAuthenticationError { throw typed }
            throw KiroBrowserAuthenticationError.exchangeFailed
        }
    }
}

final class KiroBrowserAuthenticationRedirectBlocker: NSObject, URLSessionTaskDelegate {
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

/// Verified social response shared by sign-in and app-owned renewal.
enum KiroOAuthTokenResponse {
    static let issuer = "https://prod.us-east-1.auth.desktop.kiro.dev"

    private struct Response: Decodable {
        let accessToken: String
        let refreshToken: String?
        let profileArn: String?
        let expiresIn: Double
    }

    static func snapshot(
        _ data: Data, now: Date, replacing original: CredentialSnapshot? = nil
    ) throws -> CredentialSnapshot {
        guard data.count <= KiroBrowserAuthenticationHTTP.maximumBodyBytes,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.expiresIn.isFinite, response.expiresIn > 0,
              now.timeIntervalSince1970.isFinite,
              let refresh = response.refreshToken ?? original?.refreshToken,
              let profile = response.profileArn ?? original?.accountReference,
              [response.accessToken, refresh].allSatisfy({
                  !$0.isEmpty && $0.utf8.allSatisfy { $0 > 32 && $0 < 127 }
              }),
              original == nil || profile == original?.accountReference,
              (try? CredentialDiscovery.kiroEndpoint(profileARN: profile)) != nil
        else { throw KiroBrowserAuthenticationError.invalidToken }
        let expiry = now.addingTimeInterval(response.expiresIn)
        guard expiry.timeIntervalSince1970.isFinite, expiry > now else {
            throw KiroBrowserAuthenticationError.invalidToken
        }
        if let original {
            return original.rotated(
                accessToken: response.accessToken, refreshToken: refresh, expiresAt: expiry
            )
        }
        return CredentialSnapshot(
            provider: .kiro, accessToken: response.accessToken, refreshToken: refresh,
            accountReference: profile, planName: nil, expiresAt: expiry,
            source: .keychain, oidcIssuer: issuer
        )
    }
}
