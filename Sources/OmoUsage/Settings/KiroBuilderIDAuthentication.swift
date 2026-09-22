import Foundation

enum KiroBuilderIDPollingError: Error {
    case pending
    case slowDown
}

/// AWS IAM Identity Center's public-client device grant. The hosted chooser
/// selects this fixed issuer; none of its callback values become network URLs.
struct KiroBuilderIDAuthentication {
    typealias PollWait = @MainActor (Int) async throws -> Void
    static let issuer = "https://view.awsapps.com/start"
    static let tokenEndpoint = URL(string: "https://oidc.us-east-1.amazonaws.com/token")!
    static let principalType = "AWSBuilderID"
    static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

    let exchange: KiroBrowserAuthenticationClient.Exchange
    let pollWait: PollWait
    let now: @MainActor () -> Date

    @MainActor
    func authenticate(openURL: @MainActor (URL) async -> Bool) async throws -> CredentialSnapshot {
        try Task.checkCancellation()
        let registrationData = try await exchange(Self.request(
            path: "/client/register",
            body: [
                "clientName": "Kiro",
                "clientType": "public",
                "issuerUrl": Self.issuer,
                "grantTypes": [Self.deviceGrant, "refresh_token"],
                "scopes": [
                    "codewhisperer:completions", "codewhisperer:analysis",
                    "codewhisperer:conversations", "codewhisperer:transformations",
                    "codewhisperer:taskassist"
                ]
            ]
        ))
        try Task.checkCancellation()
        let registration = try Self.decode(Registration.self, registrationData)
        let registrationExpiry = Date(timeIntervalSince1970: registration.clientSecretExpiresAt)
        guard Self.valid(registration.clientId), Self.valid(registration.clientSecret),
              registration.clientSecretExpiresAt.isFinite, registrationExpiry > now()
        else { throw KiroBrowserAuthenticationError.invalidToken }
        let deviceData = try await exchange(Self.request(
            path: "/device_authorization",
            body: [
                "clientId": registration.clientId,
                "clientSecret": registration.clientSecret,
                "startUrl": Self.issuer
            ]
        ))
        try Task.checkCancellation()
        let device = try Self.decode(Device.self, deviceData)
        guard Self.valid(device.deviceCode), (1...600).contains(device.expiresIn),
              let verification = Self.verificationURL(device.verificationUriComplete)
        else { throw KiroBrowserAuthenticationError.invalidToken }
        var interval = device.interval ?? 5
        guard (1...600).contains(interval) else { throw KiroBrowserAuthenticationError.invalidToken }
        let deadline = now().addingTimeInterval(TimeInterval(device.expiresIn))
        let opened = await openURL(verification)
        try Task.checkCancellation()
        guard opened else { throw KiroBrowserAuthenticationError.browserOpenFailed }
        var remaining = device.expiresIn
        while remaining > interval {
            try Task.checkCancellation()
            guard now() < deadline else { throw KiroBrowserAuthenticationError.timedOut }
            // This delay is the AWS protocol's interval, not an application retry.
            try await pollWait(interval)
            remaining -= interval
            try Task.checkCancellation()
            guard now() < deadline else { throw KiroBrowserAuthenticationError.timedOut }
            do {
                let data = try await exchange(Self.request(
                    path: "/token",
                    body: [
                        "clientId": registration.clientId,
                        "clientSecret": registration.clientSecret,
                        "deviceCode": device.deviceCode,
                        "grantType": Self.deviceGrant
                    ]
                ))
                try Task.checkCancellation()
                let issuedAt = now()
                let token = try Self.token(data, now: issuedAt)
                guard let refresh = token.refreshToken, Self.valid(refresh) else {
                    throw KiroBrowserAuthenticationError.invalidToken
                }
                let usage = try await exchange(Self.usageRequest(accessToken: token.accessToken))
                try Task.checkCancellation()
                // Builder ID has a default profile, not an enumerable profile ARN.
                // GetUsageLimits supplies the stable identity used for account isolation.
                let userID = try Self.userID(usage)
                return CredentialSnapshot(
                    provider: .kiro, accessToken: token.accessToken, refreshToken: refresh,
                    accountReference: userID, planName: nil,
                    expiresAt: issuedAt.addingTimeInterval(token.expiresIn), source: .keychain,
                    oidcIssuer: Self.issuer, oidcClientID: registration.clientId,
                    oidcClientSecret: registration.clientSecret,
                    oidcClientSecretExpiresAt: registrationExpiry,
                    principalType: Self.principalType, principalID: userID
                )
            } catch KiroBuilderIDPollingError.pending {
                continue
            } catch KiroBuilderIDPollingError.slowDown {
                interval += 5
            }
        }
        throw KiroBrowserAuthenticationError.timedOut
    }

    static func refreshRequest(_ credential: DiscoveredCredential, now: Date) throws -> URLRequest {
        guard hasRegistration(credential),
              let expiry = credential.oidcClientSecretExpiresAt, expiry > now,
              let refresh = credential.refreshToken, valid(refresh),
              let clientID = credential.oidcClientID,
              let secret = credential.oidcClientSecret
        else { throw CredentialDiscoveryError.expired(.kiro) }
        return try request(path: "/token", body: [
            "clientId": clientID, "clientSecret": secret,
            "grantType": "refresh_token", "refreshToken": refresh
        ])
    }

    static func refreshedSnapshot(
        _ data: Data, original: CredentialSnapshot, now: Date
    ) throws -> CredentialSnapshot {
        let response = try token(data, now: now)
        guard let refresh = response.refreshToken ?? original.refreshToken, valid(refresh) else {
            throw KiroBrowserAuthenticationError.invalidToken
        }
        return original.rotated(
            accessToken: response.accessToken, refreshToken: refresh,
            expiresAt: now.addingTimeInterval(response.expiresIn)
        )
    }

    static func hasRegistration(_ credential: DiscoveredCredential) -> Bool {
        credential.provider == .kiro && credential.source == .keychain
            && credential.oidcIssuer == issuer && credential.principalType == principalType
            && credential.oidcClientID.map(valid) == true
            && credential.oidcClientSecret.map(valid) == true
            && credential.oidcClientSecretExpiresAt?.timeIntervalSince1970.isFinite == true
            && credential.principalID.map(valid) == true
            && credential.accountID == credential.principalID
    }

    static func usageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://codewhisperer.us-east-1.amazonaws.com/getUsageLimits?origin=AI_EDITOR&resourceType=AGENTIC_REQUEST&isEmailRequired=true")!,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func userID(_ data: Data) throws -> String {
        struct Usage: Decodable {
            struct User: Decodable { let userId: String }
            let userInfo: User
        }
        let user = try decode(Usage.self, data).userInfo.userId
        guard valid(user) else { throw KiroBrowserAuthenticationError.invalidToken }
        return user
    }

    static func tokenError(_ data: Data) throws -> any Error {
        struct Failure: Decodable { let error: String }
        switch try decode(Failure.self, data).error {
        case "authorization_pending": return KiroBuilderIDPollingError.pending
        case "slow_down": return KiroBuilderIDPollingError.slowDown
        case "access_denied": return KiroBrowserAuthenticationError.authorizationDenied
        case "expired_token": return KiroBrowserAuthenticationError.timedOut
        default: return KiroBrowserAuthenticationError.exchangeFailed
        }
    }

    private static func verificationURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
              (parts.host == "view.awsapps.com" && ["/start", "/start/"].contains(parts.path))
                || (parts.host == "oidc.us-east-1.amazonaws.com" && parts.path == "/device")
        else { return nil }
        return url
    }

    private static func request(path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://oidc.us-east-1.amazonaws.com" + path)!, timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= KiroBrowserAuthenticationHTTP.maximumBodyBytes,
              let value = try? JSONDecoder().decode(type, from: data)
        else { throw KiroBrowserAuthenticationError.invalidToken }
        return value
    }

    private static func token(_ data: Data, now: Date) throws -> Token {
        let token = try decode(Token.self, data)
        let expiry = now.addingTimeInterval(token.expiresIn)
        guard valid(token.accessToken), token.tokenType == nil || token.tokenType == "Bearer",
              token.expiresIn.isFinite, token.expiresIn > 0,
              expiry.timeIntervalSince1970.isFinite, expiry > now
        else { throw KiroBrowserAuthenticationError.invalidToken }
        return token
    }

    private struct Registration: Decodable {
        let clientId: String
        let clientSecret: String
        let clientSecretExpiresAt: Double
    }

    private struct Device: Decodable {
        let deviceCode: String
        let verificationUriComplete: String
        let expiresIn: Int
        let interval: Int?
    }

    private struct Token: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        let tokenType: String?
    }
}
