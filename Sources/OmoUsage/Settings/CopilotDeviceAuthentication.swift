import Foundation
import OmoUsageCore

struct CopilotDeviceCode: Equatable, Sendable {
    let userCode: String
    let verificationURL: URL
}

/// GitHub's OAuth device flow with the Copilot editor client that
/// `copilot_internal/user` accepts. The user enters the shown code on
/// github.com; the resulting token is stored as an app-owned snapshot.
@MainActor
struct CopilotDeviceAuthenticationClient {
    typealias Exchange = @MainActor (URLRequest, ProviderEndpointPurpose) async throws -> Data
    typealias PollWait = @MainActor (Int) async throws -> Void

    nonisolated static let clientID = "Iv1.b507a08c87ecfe98"
    nonisolated static let scope = "read:user"
    nonisolated static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    nonisolated static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    nonisolated static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"
    nonisolated static let maximumBodyBytes = 16_384

    private let exchange: Exchange
    private let pollWait: PollWait

    init(exchange: Exchange? = nil, pollWait: PollWait? = nil) {
        self.exchange = exchange ?? { try await CopilotDeviceAuthenticationHTTP.exchange($0, purpose: $1) }
        self.pollWait = pollWait ?? { try await Task.sleep(for: .seconds($0)) }
    }

    func authenticate(
        present: @MainActor (CopilotDeviceCode) async -> Bool
    ) async throws -> CredentialSnapshot {
        try Task.checkCancellation()
        let device = try Self.decode(Device.self, try await exchange(
            Self.request(Self.deviceCodeURL, fields: [
                ("client_id", Self.clientID), ("scope", Self.scope)
            ]),
            .copilotDeviceCode
        ))
        try Task.checkCancellation()
        guard Self.valid(device.deviceCode), Self.valid(device.userCode),
              (1...1_800).contains(device.expiresIn),
              let verification = Self.verificationURL(device.verificationUri)
        else { throw ClaudeBrowserAuthenticationError.invalidToken }
        var interval = device.interval ?? 5
        guard (1...600).contains(interval) else { throw ClaudeBrowserAuthenticationError.invalidToken }
        let presented = await present(
            CopilotDeviceCode(userCode: device.userCode, verificationURL: verification)
        )
        try Task.checkCancellation()
        guard presented else { throw ClaudeBrowserAuthenticationError.browserOpenFailed }
        var remaining = device.expiresIn
        while remaining > interval {
            // This delay is GitHub's required polling interval, not an application retry.
            try await pollWait(interval)
            remaining -= interval
            try Task.checkCancellation()
            let data = try await exchange(
                Self.request(Self.tokenURL, fields: [
                    ("client_id", Self.clientID),
                    ("device_code", device.deviceCode),
                    ("grant_type", Self.deviceGrant)
                ]),
                .copilotDeviceToken
            )
            try Task.checkCancellation()
            switch try Self.poll(data) {
            case .token(let token):
                return CredentialSnapshot(
                    provider: .copilot, accessToken: token, refreshToken: nil,
                    accountReference: nil, planName: nil, expiresAt: nil, source: .keychain
                )
            case .pending:
                continue
            case .slowDown:
                interval += 5
            }
        }
        throw ClaudeBrowserAuthenticationError.timedOut
    }

    enum Poll: Equatable {
        case token(String)
        case pending
        case slowDown
    }

    nonisolated static func poll(_ data: Data) throws -> Poll {
        let response = try decode(TokenResponse.self, data)
        if let token = response.accessToken {
            guard valid(token), response.tokenType?.lowercased() ?? "bearer" == "bearer" else {
                throw ClaudeBrowserAuthenticationError.invalidToken
            }
            return .token(token)
        }
        switch response.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": throw ClaudeBrowserAuthenticationError.authorizationDenied
        case "expired_token": throw ClaudeBrowserAuthenticationError.timedOut
        default: throw ClaudeBrowserAuthenticationError.exchangeFailed
        }
    }

    nonisolated static func request(
        _ url: URL,
        fields: [(String, String)]
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        request.httpBody = Data(fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }.joined(separator: "&").utf8)
        return request
    }

    nonisolated private static func verificationURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path == "/login/device"
        else { return nil }
        return url
    }

    nonisolated private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }

    nonisolated private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard data.count <= maximumBodyBytes, let value = try? decoder.decode(type, from: data)
        else { throw ClaudeBrowserAuthenticationError.invalidToken }
        return value
    }

    private struct Device: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int?
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let tokenType: String?
        let error: String?
    }
}

enum CopilotDeviceAuthenticationHTTP {
    static func exchange(
        _ request: URLRequest,
        purpose: ProviderEndpointPurpose,
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
                endpoint: ProviderContractCatalog.endpoint(purpose, for: .copilot)
            )
        } catch {
            try Task.checkCancellation()
            throw ClaudeBrowserAuthenticationError.exchangeFailed
        }
    }
}
