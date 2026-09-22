import Foundation
import Synchronization
import Testing
import OmoUsageCore
@testable import OmoUsage

// The existing suite serializes all users of the real hosted callback port.
extension KiroBrowserAuthenticationTests {
    @Test
    func builderBrowserFlowValidatesAndRenewsItsOwnRegistration() async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        KiroBuilderProtocol.state.withLock {
            $0.tokenReplies = [
                (400, #"{"error":"authorization_pending"}"#),
                (400, #"{"error":"slow_down"}"#),
                (200, KiroBuilderFixture.token)
            ]
        }
        var intervals: [Int] = []
        let flow = try await fixture.begin(wait: { intervals.append($0) })
        #expect(try await fixture.callback(flow.url) == 200)
        let snapshot = try await flow.task.value
        #expect(intervals == [5, 5, 10])
        #expect(snapshot.accountReference == "builder-user-fixture")
        #expect(snapshot.principalID == snapshot.accountReference)
        #expect(snapshot.principalType == "AWSBuilderID")
        #expect(snapshot.oidcIssuer == "https://view.awsapps.com/start")
        #expect(snapshot.oidcClientID == "registered-client")
        #expect(snapshot.oidcClientSecret == "registered-secret")
        #expect(snapshot.oidcClientSecretExpiresAt == KiroBuilderFixture.now.addingTimeInterval(7200))
        #expect(!snapshot.description.contains("registered-secret"))
        #expect(!snapshot.debugDescription.contains("registered-secret"))
        #expect(try CredentialSnapshot(encodedSecret: snapshot.encodedSecret(), provider: .kiro) == snapshot)
        #expect(CredentialSnapshot(snapshot.credential(storage: .accountSnapshot(fixture.identity))) == snapshot)
        let usage = try await fixture.provider.fetch(
            credential: snapshot.credential(storage: .accountSnapshot(fixture.identity)),
            now: KiroBuilderFixture.now
        )
        #expect(usage.availability == .available)
        #expect(fixture.opened.map(\.host) == ["app.kiro.dev", "view.awsapps.com"])
        let requests = KiroBuilderProtocol.state.withLock { $0.requests }
        #expect(requests.map(\.url?.path) == [
            "/client/register", "/device_authorization", "/token", "/token", "/token",
            "/getUsageLimits", "/getUsageLimits"
        ])
        let bodies = KiroBuilderProtocol.state.withLock { $0.bodies }
        let registration = try #require(try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        #expect(registration["issuerUrl"] as? String == "https://view.awsapps.com/start")
        #expect(registration["grantTypes"] as? [String] == [
            "urn:ietf:params:oauth:grant-type:device_code", "refresh_token"
        ])
        for body in bodies[2...4] {
            #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == [
                "clientId": "registered-client", "clientSecret": "registered-secret",
                "deviceCode": "fixture-device", "grantType": "urn:ietf:params:oauth:grant-type:device_code"
            ])
        }
        #expect(requests.allSatisfy {
            ["oidc.us-east-1.amazonaws.com", "codewhisperer.us-east-1.amazonaws.com"].contains($0.url?.host)
        })
        #expect(requests.filter { $0.httpMethod == "GET" }.allSatisfy {
            !$0.url!.absoluteString.contains("profileArn")
        })

        let expired = snapshot.rotated(
            accessToken: snapshot.accessToken, refreshToken: snapshot.refreshToken,
            expiresAt: KiroBuilderFixture.now
        )
        try fixture.discovery.snapshotStore.save(expired, for: fixture.identity)
        let neighbor = AccountProviderID(accountID: .legacy, providerID: .kiro)
        try fixture.discovery.snapshotStore.save(expired, for: neighbor)
        KiroBuilderProtocol.state.withLock { $0.requests = []; $0.bodies = [] }
        _ = try await fixture.provider.fetch(now: KiroBuilderFixture.now)
        let renewed = try #require(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity))
        #expect(renewed.accessToken == "renewed-access")
        #expect(renewed.refreshToken == "renewed-refresh")
        #expect(renewed.oidcClientSecret == snapshot.oidcClientSecret)
        #expect(renewed.oidcClientSecretExpiresAt == snapshot.oidcClientSecretExpiresAt)
        #expect(renewed.accountReference == snapshot.accountReference)
        #expect(try fixture.discovery.snapshotStore.snapshot(for: neighbor) == expired)
        #expect(KiroBuilderProtocol.state.withLock { $0.requests.map(\.url?.path) } == ["/token", "/getUsageLimits"])
        let refreshBody = KiroBuilderProtocol.state.withLock { $0.bodies[0] }
        #expect(try JSONSerialization.jsonObject(with: refreshBody) as? [String: String] == [
            "clientId": "registered-client", "clientSecret": "registered-secret",
            "grantType": "refresh_token", "refreshToken": "builder-refresh"
        ])
    }

    @Test(arguments: ["issuer", "region", "state", "duplicate", "mixed"])
    func builderCallbackRejectsUntrustedDescriptorsWithoutConsumption(_ mode: String) async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        let flow = try await fixture.begin()
        #expect(try await fixture.callback(flow.url, mode: mode) == 400)
        #expect(KiroBuilderProtocol.state.withLock { $0.requests.isEmpty })
        #expect(try await fixture.callback(flow.url) == 200)
        _ = try await flow.task.value
    }

    @Test(arguments: ["organization", "external_idp"])
    func organizationReturnsTypedUnsupportedWithoutNetwork(_ option: String) async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        let flow = try await fixture.begin()
        #expect(try await fixture.callback(flow.url, mode: option) == 400)
        await #expect(throws: KiroBrowserAuthenticationError.unsupportedOrganization) {
            try await flow.task.value
        }
        #expect(KiroBuilderProtocol.state.withLock { $0.requests.isEmpty })
    }

    @Test(arguments: ["http://view.awsapps.com/start", "https://view.awsapps.com.attacker.invalid/start",
                      "https://attacker.invalid/start", "https://user@view.awsapps.com/start",
                      "https://view.awsapps.com:443/start", "https://view.awsapps.com/other"])
    func builderRejectsUntrustedVerificationURLs(_ uri: String) async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        KiroBuilderProtocol.state.withLock { $0.verificationURI = uri }
        let flow = try await fixture.begin()
        #expect(try await fixture.callback(flow.url) == 200)
        await #expect(throws: KiroBrowserAuthenticationError.invalidToken) { try await flow.task.value }
        #expect(fixture.opened.count == 1)
        #expect(KiroBuilderProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test(arguments: ["access_denied", "expired_token", "invalid_grant", "exhausted", "malformed", "identity"])
    func builderProtocolFailuresNeverReturnCredential(_ mode: String) async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        KiroBuilderProtocol.state.withLock {
            switch mode {
            case "exhausted":
                $0.deviceLifetime = 11
                $0.tokenReplies = Array(repeating: (400, #"{"error":"authorization_pending"}"#), count: 3)
            case "malformed": $0.tokenReplies = [(200, #"{"accessToken":"bad","expiresIn":0}"#)]
            case "identity": $0.usage = #"{"usageBreakdownList":[]}"#
            default: $0.tokenReplies = [(400, "{\"error\":\"\(mode)\"}")]
            }
        }
        var waits = 0
        let flow = try await fixture.begin(wait: { _ in waits += 1 })
        #expect(try await fixture.callback(flow.url) == 200)
        let expected: KiroBrowserAuthenticationError = switch mode {
        case "access_denied": .authorizationDenied
        case "expired_token", "exhausted": .timedOut
        case "malformed", "identity": .invalidToken
        default: .exchangeFailed
        }
        await #expect(throws: expected) { try await flow.task.value }
        #expect(waits == (mode == "exhausted" ? 2 : 1))
        #expect(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity) == nil)
    }

    @Test(arguments: [false, true])
    func builderCancellationAndDeadlineInterruptProtocolWait(timeout: Bool) async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        let (waiting, started) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let (deadline, deadlineSignal) = AsyncStream<Void>.makeStream()
        defer { started.finish(); releaseSignal.finish(); deadlineSignal.finish() }
        let flow = try await fixture.begin(
            wait: { _ in
                started.yield(())
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
                try Task.checkCancellation()
            },
            timeout: {
                var iterator = deadline.makeAsyncIterator()
                _ = await iterator.next()
                try Task.checkCancellation()
            }
        )
        #expect(try await fixture.callback(flow.url) == 200)
        var iterator = waiting.makeAsyncIterator()
        _ = await iterator.next()
        if timeout { deadlineSignal.yield(()) } else { flow.task.cancel() }
        do {
            _ = try await flow.task.value
            Issue.record("Cancelled Builder flow returned a credential")
        } catch {
            if timeout { #expect(error as? KiroBrowserAuthenticationError == .timedOut) }
            else { #expect(error is CancellationError) }
        }
        #expect(KiroBuilderProtocol.state.withLock { $0.requests.count } == 2)
        #expect(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity) == nil)
    }

    @Test
    func builderSecondBrowserOpenFailureDoesNotPoll() async throws {
        let fixture = KiroBuilderFixture()
        fixture.allowVerification = false
        defer { fixture.session.invalidateAndCancel() }
        let flow = try await fixture.begin()
        #expect(try await fixture.callback(flow.url) == 200)
        await #expect(throws: KiroBrowserAuthenticationError.browserOpenFailed) { try await flow.task.value }
        #expect(KiroBuilderProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test(arguments: ["wrong-user", "invalid-usage", "removed", "reconnected", "expired-registration", "copied", "unauthorized"])
    func builderRenewalCannotOverwriteInvalidOrChangedAccount(_ mode: String) async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        let original = fixture.snapshot(
            source: mode == "copied" ? .file : .keychain,
            registrationExpiry: mode == "expired-registration" ? KiroBuilderFixture.now : nil
        )
        try fixture.discovery.snapshotStore.save(original, for: fixture.identity)
        let replacement = original.rotated(
            accessToken: "reconnected", refreshToken: "reconnected-refresh",
            expiresAt: KiroBuilderFixture.now.addingTimeInterval(3600)
        )
        KiroBuilderProtocol.state.withLock {
            switch mode {
            case "wrong-user": $0.usage = KiroBuilderFixture.usage.replacingOccurrences(of: "builder-user-fixture", with: "another-user")
            case "invalid-usage": $0.usage = #"{"userInfo":{"userId":"builder-user-fixture"},"usageBreakdownList":[]}"#
            case "unauthorized": $0.refreshStatus = 401
            default: break
            }
            if mode == "removed" || mode == "reconnected" {
                let discovery = fixture.discovery
                let identity = fixture.identity
                let keychain = fixture.keychain
                $0.onRequest = { request in
                    guard request.url?.path == "/token" else { return }
                    if mode == "removed" {
                        try? keychain.remove(service: ProviderAPIKeyStore.serviceName, account: ProviderCredentialSnapshotStore.account(for: identity))
                    } else {
                        try? discovery.snapshotStore.save(replacement, for: identity)
                    }
                }
            }
        }
        do {
            _ = try await fixture.provider.fetch(now: KiroBuilderFixture.now)
            Issue.record("Invalid Builder renewal succeeded")
        } catch {
            switch mode {
            case "invalid-usage": #expect(error as? UsageParsingError == .invalidPayload)
            case "expired-registration": #expect(error as? CredentialDiscoveryError == .expired(.kiro))
            case "unauthorized": #expect(error as? ProviderTransportError == .authenticationRequired(.kiro))
            default: #expect(error as? CredentialDiscoveryError == .malformed(.kiro))
            }
        }
        let stored = try fixture.discovery.snapshotStore.snapshot(for: fixture.identity)
        #expect(stored == (mode == "removed" ? nil : mode == "reconnected" ? replacement : original))
        if mode == "expired-registration" || mode == "copied" {
            #expect(KiroBuilderProtocol.state.withLock { $0.requests.isEmpty })
        } else {
            #expect(KiroBuilderProtocol.state.withLock { $0.requests.count } == (mode == "unauthorized" ? 1 : 2))
        }
    }

    @Test(arguments: [false, true])
    func builder401RenewsOnceAndPreservesOmittedRefreshToken(rejectedAgain: Bool) async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        let original = fixture.snapshot(expiry: KiroBuilderFixture.now.addingTimeInterval(3600))
        try fixture.discovery.snapshotStore.save(original, for: fixture.identity)
        KiroBuilderProtocol.state.withLock {
            $0.usageStatuses = [401, rejectedAgain ? 401 : 200]
            $0.refresh = #"{"accessToken":"renewed-access","expiresIn":3600}"#
        }
        if rejectedAgain {
            await #expect(throws: ProviderTransportError.authenticationRequired(.kiro)) {
                try await fixture.provider.fetch(now: KiroBuilderFixture.now)
            }
            #expect(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity) == original)
        } else {
            _ = try await fixture.provider.fetch(now: KiroBuilderFixture.now)
        }
        #expect(KiroBuilderProtocol.state.withLock { $0.requests.map(\.url?.path) } == ["/getUsageLimits", "/token", "/getUsageLimits"])
        #expect(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity)?.refreshToken == original.refreshToken)
    }

    @Test
    func builderCancelledRenewalDoesNotPersistUnvalidatedToken() async throws {
        let fixture = KiroBuilderFixture()
        defer { fixture.session.invalidateAndCancel() }
        let original = fixture.snapshot()
        try fixture.discovery.snapshotStore.save(original, for: fixture.identity)
        let (requests, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        KiroBuilderProtocol.state.withLock {
            $0.holdUsage = true
            $0.onRequest = { request in
                if request.url?.path == "/getUsageLimits" { signal.yield(()) }
            }
        }
        let task = Task { try await fixture.provider.fetch(now: KiroBuilderFixture.now) }
        var iterator = requests.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity) == original)
        #expect(KiroBuilderProtocol.state.withLock { $0.requests.map(\.url?.path) } == ["/token", "/getUsageLimits"])
    }
}

@MainActor
private final class KiroBuilderFixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let token = #"{"accessToken":"builder-access","refreshToken":"builder-refresh","expiresIn":3600,"tokenType":"Bearer"}"#
    static let usage = #"{"userInfo":{"userId":"builder-user-fixture"},"usageBreakdownList":[{"resourceType":"CREDIT","usageLimitWithPrecision":100,"currentUsageWithPrecision":25}],"nextDateReset":1800000000}"#
    let keychain = KiroBuilderKeychain()
    let identity = AccountProviderID(
        accountID: AccountID(rawValue: "00000000-0000-0000-0000-000000000002")!, providerID: .kiro
    )
    let discovery: CredentialDiscovery
    let configuration: URLSessionConfiguration
    let session: URLSession
    let provider: KiroUsageProvider
    var opened: [URL] = []
    var allowVerification = true

    init() {
        let home = URL(fileURLWithPath: "/isolated/kiro-builder-tests")
        discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: home, codex: home), environment: [:],
            keychain: keychain, providerKeychain: keychain, homeDirectory: home, commandPaths: []
        )
        configuration = .ephemeral
        configuration.protocolClasses = [KiroBuilderProtocol.self]
        session = URLSession(configuration: configuration)
        provider = KiroUsageProvider(
            discovery: discovery, http: ProviderHTTP(session: session), accountID: identity.accountID
        )
        KiroBuilderProtocol.state.withLock { $0 = .init() }
    }

    func snapshot(
        source: CredentialSource = .keychain, registrationExpiry: Date? = nil, expiry: Date? = nil
    ) -> CredentialSnapshot {
        CredentialSnapshot(
            provider: .kiro, accessToken: "builder-access", refreshToken: "builder-refresh",
            accountReference: "builder-user-fixture", planName: nil, expiresAt: expiry ?? Self.now,
            source: source, oidcIssuer: KiroBuilderIDAuthentication.issuer,
            oidcClientID: "registered-client", oidcClientSecret: "registered-secret",
            oidcClientSecretExpiresAt: registrationExpiry ?? Self.now.addingTimeInterval(7200),
            principalType: KiroBuilderIDAuthentication.principalType, principalID: "builder-user-fixture"
        )
    }

    func begin(
        wait: @escaping KiroBuilderIDAuthentication.PollWait = { _ in },
        timeout: KiroBrowserAuthenticationClient.Timeout? = nil
    ) async throws -> (url: URL, task: Task<CredentialSnapshot, Error>) {
        let (urls, signal) = AsyncThrowingStream<URL, Error>.makeStream()
        let task = Task {
            do {
                return try await KiroBrowserAuthenticationClient(
                    exchange: { try await KiroBrowserAuthenticationHTTP.exchange($0, configuration: self.configuration) },
                    timeout: timeout, pollWait: wait, now: { Self.now }
                ).authenticate { url in
                    self.opened.append(url)
                    if self.opened.count == 1 {
                        signal.yield(url)
                        return true
                    }
                    // Observe release of the first listener before AWS browser navigation.
                    let listener = try? KiroBrowserAuthenticationListener(state: "probe")
                    do {
                        _ = try await #require(listener).start()
                    } catch {
                        Issue.record("Hosted listener was not closed before AWS navigation")
                    }
                    await listener?.close()
                    return self.allowVerification
                }
            } catch {
                signal.finish(throwing: error)
                throw error
            }
        }
        var iterator = urls.makeAsyncIterator()
        let url = try #require(try await iterator.next())
        return (url, task)
    }

    func callback(_ authorization: URL, mode: String = "") async throws -> Int {
        let state = try #require(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "state" })?.value)
        var components = URLComponents(string: "http://localhost:3128/signin/callback")!
        components.queryItems = [
            URLQueryItem(name: "login_option", value: ["organization", "external_idp"].contains(mode) ? mode : "builderid"),
            URLQueryItem(name: "issuer_url", value: mode == "issuer" ? "http://169.254.169.254/" : "https://view.awsapps.com/start"),
            URLQueryItem(name: "idc_region", value: mode == "region" ? "eu-central-1" : "us-east-1"),
            URLQueryItem(name: "state", value: mode == "state" ? "wrong" : state)
        ]
        if mode == "duplicate" { components.queryItems?.append(URLQueryItem(name: "state", value: state)) }
        if mode == "mixed" { components.queryItems?.append(URLQueryItem(name: "code", value: "social-code")) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3
        let local = URLSession(configuration: config)
        defer { local.invalidateAndCancel() }
        let (_, response) = try await local.data(from: components.url!)
        return try #require(response as? HTTPURLResponse).statusCode
    }
}

private final class KiroBuilderKeychain: KeychainReading, ProviderKeychain, Sendable {
    let values = Mutex<[String: String]>([:])
    func value(service: String, account: String) throws -> String? { values.withLock { $0[account] } }
    func set(_ value: String, service: String, account: String) throws { values.withLock { $0[account] = value } }
    func remove(service: String, account: String) throws { values.withLock { $0[account] = nil } }
}

private final class KiroBuilderProtocol: URLProtocol {
    struct State {
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        var tokenReplies: [(Int, String)] = []
        var verificationURI = "https://view.awsapps.com/start/#/device?user_code=TEST-CODE"
        var deviceLifetime = 600
        var usage = #"{"userInfo":{"userId":"builder-user-fixture"},"usageBreakdownList":[{"resourceType":"CREDIT","usageLimitWithPrecision":100,"currentUsageWithPrecision":25}],"nextDateReset":1800000000}"#
        var usageStatuses: [Int] = []
        var refresh = #"{"accessToken":"renewed-access","refreshToken":"renewed-refresh","expiresIn":3600}"#
        var refreshStatus = 200
        var holdUsage = false
        var onRequest: (@Sendable (URLRequest) -> Void)?
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = requestBodyData(request) ?? Data()
        let (status, json, hook) = Self.state.withLock { state -> (Int, String, (@Sendable (URLRequest) -> Void)?) in
            state.requests.append(request)
            state.bodies.append(body)
            let reply: (Int, String)
            switch request.url?.path {
            case "/client/register":
                reply = (200, #"{"clientId":"registered-client","clientSecret":"registered-secret","clientSecretExpiresAt":1790007200}"#)
            case "/device_authorization":
                let payload: [String: Any] = [
                    "deviceCode": "fixture-device", "verificationUriComplete": state.verificationURI,
                    "interval": 5, "expiresIn": state.deviceLifetime
                ]
                reply = (200, String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
            case "/token":
                let fields = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
                if fields?["grantType"] == "refresh_token" {
                    reply = (state.refreshStatus, state.refresh)
                } else if !state.tokenReplies.isEmpty {
                    reply = state.tokenReplies.removeFirst()
                } else {
                    reply = (200, #"{"accessToken":"builder-access","refreshToken":"builder-refresh","expiresIn":3600,"tokenType":"Bearer"}"#)
                }
            case "/getUsageLimits":
                reply = (state.usageStatuses.isEmpty ? 200 : state.usageStatuses.removeFirst(), state.usage)
            default:
                Issue.record("Unexpected Builder endpoint")
                reply = (500, "{}")
            }
            return (reply.0, reply.1, state.onRequest)
        }
        hook?(request)
        if request.url?.path == "/getUsageLimits", Self.state.withLock({ $0.holdUsage }) { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
