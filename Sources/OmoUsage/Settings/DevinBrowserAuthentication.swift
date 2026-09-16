import Foundation
import CryptoKit
import Security

enum DevinBrowserAuthenticationError: Error, Equatable {
    case browserOpenFailed
    case timedOut
    case listenerFailed
    case authorizationDenied
    case exchangeFailed
    case invalidToken
    case randomGenerationFailed
}

/// Captures a browser credential only. The caller must persist it and validate usage.
@MainActor
struct DevinBrowserAuthenticationClient {
    typealias Exchange = @MainActor (URLRequest) async throws -> Data
    typealias Timeout = @MainActor () async throws -> Void

    private let exchange: Exchange
    private let timeout: Timeout

    init(
        exchange: Exchange? = nil,
        timeout: Timeout? = nil
    ) {
        self.exchange = exchange ?? { try await DevinBrowserAuthenticationHTTP.exchange($0) }
        self.timeout = timeout ?? { try await Task.sleep(for: .seconds(180)) }
    }

    func authenticate(
        openURL: @MainActor (URL) async -> Bool
    ) async throws -> CredentialSnapshot {
        try Task.checkCancellation()
        let state = try Self.randomValue()
        let verifier = try Self.randomValue()
        let flow = try DevinBrowserAuthenticationAttempt(
            state: state, verifier: verifier, exchange: exchange
        )
        return try await withTaskCancellationHandler {
            flow.startTimeout(timeout)
            do {
                let redirect = try await flow.listener.start()
                try Task.checkCancellation()
                try flow.checkActive()
                var authorization = URLComponents(
                    string: "https://app.devin.ai/auth/cli/continue"
                )!
                authorization.queryItems = [
                    URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
                    URLQueryItem(name: "state", value: state),
                    URLQueryItem(name: "prompt", value: "select_account"),
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
                guard opened else { throw DevinBrowserAuthenticationError.browserOpenFailed }
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
            throw DevinBrowserAuthenticationError.randomGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class DevinBrowserAuthenticationAttempt {
    let listener: DevinBrowserAuthenticationListener
    private let verifier: String
    private let exchange: DevinBrowserAuthenticationClient.Exchange
    private var result: Result<CredentialSnapshot, Error>?
    private var continuation: CheckedContinuation<CredentialSnapshot, Error>?
    private var exchangeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        state: String,
        verifier: String,
        exchange: @escaping DevinBrowserAuthenticationClient.Exchange
    ) throws {
        self.verifier = verifier
        self.exchange = exchange
        listener = try DevinBrowserAuthenticationListener(state: state)
        listener.callback = { [weak self] result in self?.received(result) }
    }

    func startTimeout(_ timeout: @escaping DevinBrowserAuthenticationClient.Timeout) {
        timeoutTask = Task { [weak self] in
            do {
                try await timeout()
                try Task.checkCancellation()
                self?.finish(.failure(DevinBrowserAuthenticationError.timedOut))
            } catch {
                if !Task.isCancelled {
                    self?.finish(.failure(DevinBrowserAuthenticationError.timedOut))
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

    private func received(_ callback: Result<String, DevinBrowserAuthenticationError>) {
        guard result == nil, exchangeTask == nil else { return }
        switch callback {
        case .failure(let error):
            finish(.failure(error))
        case .success(let code):
            exchangeTask = Task { [weak self, exchange, verifier] in
                do {
                    try Task.checkCancellation()
                    var request = URLRequest(url: URL(string: "https://api.devin.ai/auth/cli/token")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 30
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONEncoder().encode(
                        TokenRequest(code: code, code_verifier: verifier)
                    )
                    let data = try await exchange(request)
                    try Task.checkCancellation()
                    let snapshot = try Self.snapshot(data)
                    self?.finish(.success(snapshot))
                } catch {
                    let safeError: Error
                    if error is CancellationError { safeError = CancellationError() }
                    else if let typed = error as? DevinBrowserAuthenticationError { safeError = typed }
                    else { safeError = DevinBrowserAuthenticationError.exchangeFailed }
                    self?.finish(.failure(safeError))
                }
            }
        }
    }

    private struct TokenRequest: Encodable {
        let code: String
        let code_verifier: String
    }

    private struct TokenResponse: Decodable {
        let token: String
    }

    private struct JWTClaims: Decodable {
        let exp: Double?
    }

    private static func snapshot(_ data: Data) throws -> CredentialSnapshot {
        guard data.count <= DevinBrowserAuthenticationHTTP.maximumBodyBytes,
              let response = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else { throw DevinBrowserAuthenticationError.invalidToken }
        let prefix = "devin-session-token$"
        var token = response.token.trimmingCharacters(in: .whitespacesAndNewlines)
        while token.hasPrefix(prefix) { token.removeFirst(prefix.count) }
        guard !token.isEmpty, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw DevinBrowserAuthenticationError.invalidToken
        }
        var expiration: Date?
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        if segments.count == 3 {
            var payload = String(segments[1])
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let bytes = Data(base64Encoded: payload),
               let claims = try? JSONDecoder().decode(JWTClaims.self, from: bytes),
               let seconds = claims.exp, seconds.isFinite {
                expiration = Date(timeIntervalSince1970: seconds)
            }
        }
        return CredentialSnapshot(
            provider: .devin, accessToken: prefix + token, refreshToken: nil,
            accountReference: "https://server.codeium.com", planName: nil,
            expiresAt: expiration, source: .keychain
        )
    }
}

enum DevinBrowserAuthenticationHTTP {
    static let maximumBodyBytes = 65_536

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
                for: request, delegate: DevinBrowserAuthenticationRedirectBlocker()
            )
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  response.expectedContentLength <= Int64(maximumBodyBytes)
            else { throw DevinBrowserAuthenticationError.exchangeFailed }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumBodyBytes else {
                    throw DevinBrowserAuthenticationError.exchangeFailed
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch {
            try Task.checkCancellation()
            throw DevinBrowserAuthenticationError.exchangeFailed
        }
    }
}

final class DevinBrowserAuthenticationRedirectBlocker: NSObject, URLSessionTaskDelegate {
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
