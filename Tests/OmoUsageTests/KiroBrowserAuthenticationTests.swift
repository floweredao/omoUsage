import Foundation
import CryptoKit
import Network
import Synchronization
import Testing
@testable import OmoUsage
import OmoUsageCore

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct KiroBrowserAuthenticationTests {
    @Test
    func browserOpenFailureIsReportedAfterListenerBinds() async {
        var opened = false
        do {
            _ = try await KiroBrowserAuthenticationClient().authenticate { url in
                opened = true
                #expect(url.host == "app.kiro.dev")
                #expect(url.path == "/signin")
                return false
            }
            Issue.record("Browser-open failure unexpectedly succeeded")
        } catch {
            #expect(error as? KiroBrowserAuthenticationError == .browserOpenFailed)
        }
        #expect(opened, "Authentication must bind its listener and open the hosted chooser")
    }

    @Test(arguments: [false, true])
    func expiredAppOwnedSnapshotRefreshesAndPersistsBeforeUsage(nonlegacy: Bool) async throws {
        let keychain = KiroOAuthKeychain()
        let account = nonlegacy
            ? AccountID(rawValue: "00000000-0000-0000-0000-000000000002")!
            : .legacy
        let identity = AccountProviderID(accountID: account, providerID: .kiro)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let old = CredentialSnapshot(
            provider: .kiro, accessToken: "old-access", refreshToken: "old-refresh",
            accountReference: KiroOAuthProtocol.profile, planName: nil,
            expiresAt: now, source: .keychain,
            oidcIssuer: "https://prod.us-east-1.auth.desktop.kiro.dev"
        )
        let home = URL(fileURLWithPath: "/isolated/kiro-oauth-tests")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: home, codex: home),
            environment: [:], keychain: keychain, providerKeychain: keychain,
            homeDirectory: home, commandPaths: []
        )
        try discovery.snapshotStore.save(old, for: identity)
        let neighbor = AccountProviderID(
            accountID: AccountID(rawValue: "00000000-0000-0000-0000-000000000003")!,
            providerID: .kiro
        )
        try discovery.snapshotStore.save(old, for: neighbor)
        KiroOAuthProtocol.state.withLock {
            $0 = .init(onRequest: { request in
                if request.url?.path == "/getUsageLimits" {
                    #expect((try? discovery.snapshotStore.snapshot(for: identity))?.accessToken == "new-access")
                }
            })
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KiroOAuthProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = KiroUsageProvider(
            discovery: discovery, http: ProviderHTTP(session: session), accountID: account
        )
        let usage = try await provider.fetch(now: now)
        #expect(usage.accountID == account)
        let stored = try #require(try discovery.snapshotStore.snapshot(for: identity))
        #expect(stored.accessToken == "new-access")
        #expect(stored.refreshToken == "new-refresh")
        #expect(stored.expiresAt == now.addingTimeInterval(3600))
        let requests = KiroOAuthProtocol.state.withLock { $0.requests }
        #expect(requests.count == 2)
        #expect(requests.first?.url?.absoluteString == "https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken")
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
        let body = try #require(KiroOAuthProtocol.state.withLock { $0.bodies.first })
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["refreshToken": "old-refresh"])
        #expect(requests.last?.httpMethod == "GET")
        #expect(requests.last?.url?.path == "/getUsageLimits")
        let query = URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) }) == [
            "profileArn": KiroOAuthProtocol.profile, "origin": "AI_EDITOR",
            "resourceType": "AGENTIC_REQUEST", "isEmailRequired": "true"
        ])
        #expect(try discovery.snapshotStore.snapshot(for: neighbor) == old)
    }

    @Test(arguments: [false, true])
    func copiedCLISnapshotsNeverRotate(nonlegacy: Bool) async throws {
        let fixture = try KiroOAuthFixture(nonlegacy: nonlegacy, owned: false, expiresAt: Self.now)
        defer { fixture.session.invalidateAndCancel() }
        await #expect(throws: CredentialDiscoveryError.expired(.kiro)) {
            try await fixture.provider.fetch(now: Self.now)
        }
        #expect(KiroOAuthProtocol.state.withLock { $0.requests.isEmpty })
        #expect(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity) == fixture.original)
    }

    @Test(arguments: ["unauthorized", "server-error", "wrong-profile", "bad-expiry", "removed", "reconnected", "write-failed"])
    func failedRefreshRetainsExactAccount(_ mode: String) async throws {
        let fixture = try KiroOAuthFixture(expiresAt: Self.now)
        defer { fixture.session.invalidateAndCancel() }
        let replacement = fixture.original.rotated(
            accessToken: "reconnected-access", refreshToken: "reconnected-refresh",
            expiresAt: Self.now.addingTimeInterval(7200)
        )
        KiroOAuthProtocol.state.withLock { state in
            switch mode {
            case "unauthorized": state.statuses = [401]
            case "server-error": state.statuses = [500]
            case "wrong-profile":
                state.refreshJSON = Self.tokenJSON.replacingOccurrences(of: "social-fixture", with: "different-owner")
            case "bad-expiry":
                state.refreshJSON = Self.tokenJSON.replacingOccurrences(of: "\"expiresIn\":3600", with: "\"expiresIn\":0")
            default: break
            }
            state.onRequest = { _ in
                switch mode {
                case "removed":
                    try? fixture.keychain.remove(
                        service: ProviderAPIKeyStore.serviceName,
                        account: ProviderCredentialSnapshotStore.account(for: fixture.identity)
                    )
                case "reconnected":
                    try? fixture.discovery.snapshotStore.save(replacement, for: fixture.identity)
                case "write-failed": fixture.keychain.failWrites.withLock { $0 = true }
                default: break
                }
            }
        }
        do {
            _ = try await fixture.provider.fetch(now: Self.now)
            Issue.record("Invalid refresh must not publish usage")
        } catch {
            switch mode {
            case "unauthorized": #expect(error as? ProviderTransportError == .authenticationRequired(.kiro))
            case "server-error": #expect(error as? ProviderTransportError == .requestFailed(.kiro, 500))
            case "wrong-profile", "bad-expiry": #expect(error as? KiroBrowserAuthenticationError == .invalidToken)
            default: #expect(error as? CredentialDiscoveryError == .malformed(.kiro))
            }
        }
        #expect(KiroOAuthProtocol.state.withLock { $0.requests.count } == 1)
        let stored = try fixture.discovery.snapshotStore.snapshot(for: fixture.identity)
        #expect(stored == (mode == "removed" ? nil : mode == "reconnected" ? replacement : fixture.original))
    }

    @Test
    func authorizationFailureRefreshesOnceAndRetainsOmittedRefreshMetadata() async throws {
        let fixture = try KiroOAuthFixture(expiresAt: Self.now.addingTimeInterval(600))
        defer { fixture.session.invalidateAndCancel() }
        KiroOAuthProtocol.state.withLock {
            $0.statuses = [401, 200, 200]
            $0.refreshJSON = #"{"accessToken":"new-access","expiresIn":3600}"#
        }
        _ = try await fixture.provider.fetch(now: Self.now)
        #expect(KiroOAuthProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["GET", "POST", "GET"])
        let stored = try #require(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity))
        #expect(stored.refreshToken == fixture.original.refreshToken)
        #expect(stored.accountReference == fixture.original.accountReference)
    }

    @Test
    func unpersistedCredentialValidationNeverRenews() async throws {
        let fixture = try KiroOAuthFixture(expiresAt: Self.now.addingTimeInterval(10))
        defer { fixture.session.invalidateAndCancel() }
        let credential = fixture.original.credential(storage: .accountSnapshot(fixture.identity))
        _ = try await fixture.provider.fetch(credential: credential, now: Self.now)
        #expect(KiroOAuthProtocol.state.withLock { $0.requests.map(\.httpMethod) } == ["GET"])
        #expect(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity) == fixture.original)
    }

    @Test
    func cancelledRefreshDoesNotPublishOrPersist() async throws {
        let fixture = try KiroOAuthFixture(expiresAt: Self.now)
        defer { fixture.session.invalidateAndCancel() }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        KiroOAuthProtocol.state.withLock {
            $0.holdResponse = true
            $0.onRequest = { _ in continuation.yield(()) }
        }
        let task = Task { try await fixture.provider.fetch(now: Self.now) }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.discovery.snapshotStore.snapshot(for: fixture.identity) == fixture.original)
        #expect(KiroOAuthProtocol.state.withLock { $0.requests.count } == 1)
    }

    @Test(arguments: [0.0, -1.0, 1e308])
    func invalidExpiryCannotAuthenticate(_ lifetime: Double) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "accessToken": "fixture-access", "refreshToken": "fixture-refresh",
            "profileArn": KiroOAuthProtocol.profile, "expiresIn": lifetime
        ])
        // A finite huge lifetime remains representable by Date; it is tested separately
        // by the finite result guard rather than assuming a provider token duration.
        if lifetime <= 0 {
            #expect(throws: KiroBrowserAuthenticationError.invalidToken) {
                try KiroOAuthTokenResponse.snapshot(data, now: Self.now)
            }
        } else {
            #expect(throws: KiroBrowserAuthenticationError.invalidToken) {
                try KiroOAuthTokenResponse.snapshot(data, now: Date(timeIntervalSince1970: 1e308))
            }
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static var tokenJSON: String {
        """
        {"accessToken":"fixture-access","refreshToken":"fixture-refresh","profileArn":"\(KiroOAuthProtocol.profile)","expiresIn":3600}
        """
    }

    @Test
    func realBuilderCallbackContinuesToAWSInsteadOfRequiringSocialCode() async throws {
        var requests: [URLRequest] = []
        let flow = try await Self.begin(exchange: { request in
            requests.append(request)
            throw KiroBrowserAuthenticationError.exchangeFailed
        })
        defer { flow.task.cancel() }
        let status = try await Self.http(
            flow.callback.appendingPathComponent("signin/callback"),
            query: "login_option=builderid&issuer_url=https%3A%2F%2Fview.awsapps.com%2Fstart&idc_region=us-east-1&state=\(flow.state)"
        )
        #expect(status == 200)
        if status != 200 {
            flow.task.cancel()
            await Self.expectFailure(flow.task, nil)
            return
        }
        await Self.expectFailure(flow.task, .exchangeFailed)
        #expect(requests.map(\.url?.absoluteString) == [
            "https://oidc.us-east-1.amazonaws.com/client/register"
        ])
        await Self.expectClosed(flow.callback)
    }

    @Test
    func realHTTPWrongStateThenValidAndDuplicateExchangeOnce() async throws {
        let exchange = KiroTransportExchangeGate()
        let flow = try await Self.begin(exchange: { try await exchange.exchange($0) })
        defer { flow.task.cancel() }
        let items = URLComponents(url: flow.authorization, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(flow.authorization.path == "/signin")
        #expect(Set(query.keys) == [
            "redirect_uri", "state", "redirect_from", "code_challenge", "code_challenge_method"
        ])
        #expect(query["redirect_from"] == "KiroIDE")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"]?.count == 43)
        #expect(flow.callback.host == "localhost")
        #expect(flow.callback.port == 3128)

        let wrong = try await Self.http(flow.callback, query: "code=fixture-code&state=wrong")
        #expect(wrong == 400)
        #expect(exchange.requests.isEmpty)
        print("TRANSPORT HTTP wrong-state -> 400; exchanges=0; query redacted")
        let valid = try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)")
        #expect(valid == 200)
        let request = try await exchange.started.nextValue()
        let duplicate = try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)")
        #expect(duplicate == 409)
        #expect(exchange.requests.count == 1)
        #expect(request.url?.absoluteString == "https://prod.us-east-1.auth.desktop.kiro.dev/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let requestBody = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: requestBody)
        let body = try #require(json as? [String: String])
        #expect(Set(body.keys) == ["code", "code_verifier", "redirect_uri"])
        #expect(body["redirect_uri"] == "http://localhost:3128")
        #expect(body["code"] == "fixture-code")
        let verifier = try #require(body["code_verifier"])
        #expect(verifier.count == 43)
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        #expect(Self.base64URL(digest) == query["code_challenge"])
        #expect(verifier != flow.state)
        exchange.release(Data(Self.tokenJSON.utf8))
        let snapshot = try await flow.task.value
        #expect(snapshot.provider == .kiro)
        #expect(snapshot.accessToken == "fixture-access")
        #expect(snapshot.source == .keychain)
        #expect(snapshot.refreshToken == "fixture-refresh")
        #expect(snapshot.accountReference == KiroOAuthProtocol.profile)
        #expect(snapshot.expiresAt == Self.now.addingTimeInterval(3600))
        #expect(snapshot.oidcIssuer == KiroOAuthTokenResponse.issuer)
        await Self.expectClosed(flow.callback)
        print("TRANSPORT HTTP valid -> 200; duplicate -> 409; exchanges=1; listener closed")
    }

    @Test(arguments: [
        "wrong-host", "duplicate-host", "wrong-path", "encoded-path", "post",
        "duplicate-state", "duplicate-code", "encoded-duplicate", "empty-code",
        "external-idp", "bad-percent", "wrong-state-error", "missing-state-error", "body", "absolute-target"
    ])
    func malformedCallbacksCannotConsumeAttempt(_ variant: String) async throws {
        var exchanges = 0
        let flow = try await Self.begin(exchange: { _ in
            exchanges += 1
            return Data(Self.tokenJSON.utf8)
        })
        defer { flow.task.cancel() }
        let host = "localhost:\(flow.callback.port!)"
        var target = "/signin/callback?code=fixture-code&state=\(flow.state)"
        var headers = "Host: \(host)\r\n"
        var method = "GET"
        var body = ""
        switch variant {
        case "wrong-host": headers = "Host: attacker.invalid:\(flow.callback.port!)\r\n"
        case "duplicate-host": headers += "Host: \(host)\r\n"
        case "wrong-path": target = target.replacingOccurrences(of: "/signin/callback", with: "/other")
        case "encoded-path": target = target.replacingOccurrences(of: "/signin/callback", with: "/signin/%63allback")
        case "post": method = "POST"
        case "duplicate-state": target += "&state=\(flow.state)"
        case "duplicate-code": target += "&code=another"
        case "encoded-duplicate": target += "&%73tate=\(flow.state)"
        case "empty-code": target = "/signin/callback?code=&state=\(flow.state)"
        case "bad-percent": target = "/signin/callback?code=%ZZ&state=\(flow.state)"
        case "external-idp": target += "&issuer_url=http%3A%2F%2F169.254.169.254&login_option=external_idp"
        case "wrong-state-error": target = "/signin/callback?error=denied&state=wrong"
        case "missing-state-error": target = "/signin/callback?error=denied"
        case "body": headers += "Content-Length: 1\r\n"; body = "x"
        case "absolute-target": target = "http://\(host)\(target)"
        default: Issue.record("Unknown malformed callback fixture")
        }
        let response = try await KiroTransportRawHTTP.send(
            port: UInt16(flow.callback.port!),
            request: "\(method) \(target) HTTP/1.1\r\n\(headers)\r\n\(body)"
        )
        #expect(response.hasPrefix("HTTP/1.1 400"))
        #expect(exchanges == 0)
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        _ = try await flow.task.value
        #expect(exchanges == 1)
        await Self.expectClosed(flow.callback)
    }

    @Test
    func verifiedProviderErrorTerminatesWithoutExchange() async throws {
        var exchanges = 0
        let flow = try await Self.begin(exchange: { _ in
            exchanges += 1
            return Data()
        })
        #expect(try await Self.http(flow.callback, query: "error=denied&state=\(flow.state)") == 400)
        await Self.expectFailure(flow.task, .authorizationDenied)
        #expect(exchanges == 0)
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: [false, true])
    func cancellationAndTimeoutCloseWaitingListener(timeout: Bool) async throws {
        let signal = KiroTransportEvent<Void>()
        var exchanges = 0
        let flow = try await Self.begin(
            exchange: { _ in exchanges += 1; return Data() },
            timeout: { _ = try await signal.nextValue() }
        )
        if timeout { signal.send(()) } else { flow.task.cancel() }
        await Self.expectFailure(flow.task, timeout ? .timedOut : nil)
        #expect(exchanges == 0)
        await Self.expectClosed(flow.callback)
        print("TRANSPORT \(timeout ? "timeout" : "cancel") waiting -> listener closed; exchanges=0")
    }

    @Test(arguments: [false, true])
    func cancellationAndTimeoutPreventLateExchangeSuccess(timeout: Bool) async throws {
        let signal = KiroTransportEvent<Void>()
        let exchange = KiroTransportExchangeGate()
        let flow = try await Self.begin(
            exchange: { try await exchange.exchange($0) },
            timeout: { _ = try await signal.nextValue() }
        )
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        _ = try await exchange.started.nextValue()
        if timeout { signal.send(()) } else { flow.task.cancel() }
        await Self.expectFailure(flow.task, timeout ? .timedOut : nil)
        await Self.expectClosed(flow.callback)
        exchange.release(Data(Self.tokenJSON.utf8))
        _ = try await exchange.finished.nextValue()
        await Self.expectFailure(flow.task, timeout ? .timedOut : nil)
        #expect(exchange.requests.count == 1)
        print("TRANSPORT \(timeout ? "timeout" : "cancel") during exchange -> no late success; listener closed")
    }

    @Test
    func alreadyCancelledTaskDoesNotOpenBrowser() async {
        var opened = false
        let task = Task {
            try await KiroBrowserAuthenticationClient().authenticate { _ in
                opened = true
                return true
            }
        }
        task.cancel()
        await Self.expectFailure(task, nil)
        #expect(!opened)
    }

    @Test(arguments: ["{}", #"{"token":""}"#, #"{"token":"devin-session-token$"}"#, #"{"token":42}"#, "not-json"])
    func invalidExchangePayloadDoesNotAuthenticate(_ json: String) async throws {
        let flow = try await Self.begin(exchange: { _ in Data(json.utf8) })
        #expect(try await Self.http(flow.callback, query: "code=fixture-code&state=\(flow.state)") == 200)
        await Self.expectFailure(flow.task, .invalidToken)
        await Self.expectClosed(flow.callback)
    }

    @Test
    func timeoutBeforeBrowserOpeningRetainsTimeoutError() async {
        var opened = false
        let task = Task {
            try await KiroBrowserAuthenticationClient(
                exchange: { _ in Data() }, timeout: {}
            ).authenticate { _ in
                opened = true
                return true
            }
        }
        await Self.expectFailure(task, .timedOut)
        #expect(!opened)
    }

    @Test(arguments: [false, true])
    func asyncBrowserOpenerCannotReturnLateSuccess(timeout: Bool) async throws {
        let opened = KiroTransportEvent<URL>()
        let release = KiroTransportEvent<Void>()
        let timeoutSignal = KiroTransportEvent<Void>()
        let timeoutReturned = KiroTransportEvent<Void>()
        let task = Task {
            try await KiroBrowserAuthenticationClient(
                exchange: { _ in Issue.record("Unexpected exchange"); return Data() },
                timeout: {
                    _ = try await timeoutSignal.nextValue()
                    timeoutReturned.send(())
                }
            ).authenticate { url in
                opened.send(url)
                _ = try? await release.nextValue()
                return true
            }
        }
        let url = try await opened.nextValue()
        let callback = try #require(Self.callbackURL(url))
        if timeout {
            timeoutSignal.send(())
            _ = try await timeoutReturned.nextValue()
            release.send(())
        } else {
            task.cancel()
        }
        await Self.expectFailure(task, timeout ? .timedOut : nil)
        await Self.expectClosed(callback)
    }

    @Test
    func oversizedIncompleteRequestIsRejectedWithoutExchange() async throws {
        var exchanges = 0
        let flow = try await Self.begin(exchange: { _ in
            exchanges += 1
            return Data(Self.tokenJSON.utf8)
        })
        defer { flow.task.cancel() }
        let response = try await KiroTransportRawHTTP.send(
            port: UInt16(flow.callback.port!),
            request: "GET /signin/callback?" + String(repeating: "x", count: 8_192)
        )
        #expect(response.hasPrefix("HTTP/1.1 400"))
        #expect(exchanges == 0)
        flow.task.cancel()
        await Self.expectFailure(flow.task, nil)
        await Self.expectClosed(flow.callback)
    }

    @Test(arguments: ["success", "redirect", "status-error", "declared-large", "streamed-large"])
    func ephemeralExchangeRejectsRedirectStatusAndOversizedBodies(_ mode: String) async throws {
        let server = try KiroTransportHTTPFixture(mode: mode)
        let url = try await server.start()
        do {
            let data = try await KiroBrowserAuthenticationHTTP.exchange(URLRequest(url: url))
            #expect(mode == "success")
            #expect(data == Data(#"{"token":"fixture-token"}"#.utf8))
        } catch {
            #expect(mode != "success")
            #expect(error as? KiroBrowserAuthenticationError == .exchangeFailed)
        }
        await server.close()
        #expect(server.requestCount == 1)
        await Self.expectClosed(url)
        print("TRANSPORT exchange \(mode) -> bounded result; requests=1; fixture listener closed")
    }

    private static func begin(
        exchange: @escaping KiroBrowserAuthenticationClient.Exchange,
        timeout: KiroBrowserAuthenticationClient.Timeout? = nil
    ) async throws -> (
        task: Task<CredentialSnapshot, Error>, authorization: URL, callback: URL, state: String
    ) {
        let opened = KiroTransportEvent<URL>()
        let task = Task {
            do {
                return try await KiroBrowserAuthenticationClient(
                    exchange: exchange, timeout: timeout, now: { Self.now }
                ).authenticate { url in
                    opened.send(url)
                    return true
                }
            } catch {
                opened.fail(error)
                throw error
            }
        }
        do {
            let authorization = try await opened.nextValue()
            let callback = try #require(callbackURL(authorization))
            let state = try #require(URLComponents(
                url: authorization, resolvingAgainstBaseURL: false
            )?.queryItems?.first { $0.name == "state" }?.value)
            return (task, authorization, callback, state)
        } catch {
            task.cancel()
            _ = await task.result
            throw error
        }
    }

    private static func callbackURL(_ authorization: URL) -> URL? {
        URLComponents(url: authorization, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
    }

    private static func http(_ callback: URL, query: String = "") async throws -> Int {
        var components = URLComponents(url: callback, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query.isEmpty ? nil : query
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: components.url!)
        return (response as! HTTPURLResponse).statusCode
    }

    private static func expectClosed(_ callback: URL) async {
        do {
            _ = try await http(callback)
            Issue.record("Callback listener still accepts HTTP after authentication ended")
        } catch {
            let code = (error as? URLError)?.code
            #expect(code == .cannotConnectToHost || code == .networkConnectionLost)
        }
    }

    private static func expectFailure(
        _ task: Task<CredentialSnapshot, Error>,
        _ expected: KiroBrowserAuthenticationError?
    ) async {
        do {
            _ = try await task.value
            Issue.record("Authentication unexpectedly succeeded")
        } catch {
            if let expected {
                #expect(error as? KiroBrowserAuthenticationError == expected)
            } else {
                #expect(error is CancellationError)
            }
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}


private final class KiroOAuthKeychain: KeychainReading, ProviderKeychain, Sendable {
    let values = Mutex<[String: String]>([:])
    let failWrites = Mutex(false)
    func value(service: String, account: String) throws -> String? {
        values.withLock { $0[account] }
    }
    func set(_ value: String, service: String, account: String) throws {
        if failWrites.withLock({ $0 }) { throw CredentialDiscoveryError.malformed(.kiro) }
        values.withLock { $0[account] = value }
    }
    func remove(service: String, account: String) throws {
        values.withLock { $0[account] = nil }
    }
}

private final class KiroOAuthProtocol: URLProtocol {
    static let profile = "arn:aws:codewhisperer:us-east-1:123456789012:profile/social-fixture"
    struct State {
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        var onRequest: (@Sendable (URLRequest) -> Void)?
        var statuses = [200]
        var refreshJSON: String?
        var holdResponse = false
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = requestBodyData(request)
        let (hook, status, refreshJSON, hold) = Self.state.withLock {
            $0.requests.append(request)
            $0.bodies.append(body ?? Data())
            return ($0.onRequest, $0.statuses[min($0.requests.count - 1, $0.statuses.count - 1)], $0.refreshJSON, $0.holdResponse)
        }
        hook?(request)
        if hold { return }
        let json = request.url?.path == "/refreshToken"
            ? refreshJSON ?? """
            {"accessToken":"new-access","refreshToken":"new-refresh","expiresIn":3600,"profileArn":"\(Self.profile)"}
            """
            : """
            {"usageBreakdownList":[{"resourceType":"CREDIT","usageLimitWithPrecision":100,"currentUsageWithPrecision":25}],"nextDateReset":1800000000}
            """
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct KiroOAuthFixture: Sendable {
    let keychain: KiroOAuthKeychain
    let discovery: CredentialDiscovery
    let original: CredentialSnapshot
    let identity: AccountProviderID
    let session: URLSession
    let provider: KiroUsageProvider

    init(nonlegacy: Bool = true, owned: Bool = true, expiresAt: Date) throws {
        keychain = KiroOAuthKeychain()
        let account = nonlegacy
            ? AccountID(rawValue: "00000000-0000-0000-0000-000000000002")! : .legacy
        identity = AccountProviderID(accountID: account, providerID: .kiro)
        original = CredentialSnapshot(
            provider: .kiro, accessToken: "old-access", refreshToken: "old-refresh",
            accountReference: KiroOAuthProtocol.profile, planName: nil, expiresAt: expiresAt,
            source: owned ? .keychain : .file, oidcIssuer: owned ? KiroOAuthTokenResponse.issuer : nil
        )
        let home = URL(fileURLWithPath: "/isolated/kiro-oauth-tests")
        discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: home, codex: home), environment: [:],
            keychain: keychain, providerKeychain: keychain, homeDirectory: home, commandPaths: []
        )
        try discovery.snapshotStore.save(original, for: identity)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KiroOAuthProtocol.self]
        session = URLSession(configuration: configuration)
        provider = KiroUsageProvider(
            discovery: discovery, http: ProviderHTTP(session: session), accountID: account
        )
        KiroOAuthProtocol.state.withLock { $0 = .init() }
    }
}

@MainActor
private final class KiroTransportEvent<Value: Sendable> {
    private let stream: AsyncThrowingStream<Value, Error>
    private let continuation: AsyncThrowingStream<Value, Error>.Continuation

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream()
    }

    func send(_ value: Value) { continuation.yield(value) }
    func fail(_ error: Error) { continuation.finish(throwing: error) }

    func nextValue() async throws -> Value {
        var iterator = stream.makeAsyncIterator()
        let value = try await iterator.next()
        try Task.checkCancellation()
        return try #require(value)
    }
}

@MainActor
private final class KiroTransportHTTPFixture {
    private let listener: NWListener
    private let mode: String
    private let ready = KiroTransportEvent<URL>()
    private var cancelled = false
    private var peers: [ObjectIdentifier: NWConnection] = [:]
    private var closed: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0

    init(mode: String) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready.send(URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/token")!)
                case .failed(let error):
                    self.ready.fail(error)
                    self.listener.cancel()
                case .cancelled:
                    self.cancelled = true
                    self.listener.stateUpdateHandler = nil
                    self.listener.newConnectionHandler = nil
                    self.finishClose()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.start(queue: .main)
        return try await ready.nextValue()
    }

    func close() async {
        listener.cancel()
        for peer in peers.values { peer.cancel() }
        if cancelled && peers.isEmpty { return }
        await withCheckedContinuation { closed = $0 }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        peers[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                switch state {
                case .ready: self.receive(connection, accumulated: Data())
                case .failed: connection.cancel()
                case .cancelled:
                    self.peers.removeValue(forKey: id)
                    connection.stateUpdateHandler = nil
                    self.finishClose()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var request = accumulated
                if let data { request.append(data) }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.requestCount += 1
                    self.respond(connection)
                } else if error != nil || done || request.count > 8_192 {
                    connection.cancel()
                } else {
                    self.receive(connection, accumulated: request)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection) {
        let fixture = #"{"token":"fixture-token"}"#
        let headers: String
        let body: String
        switch mode {
        case "redirect":
            headers = "302 Found\r\nLocation: http://127.0.0.1:\(listener.port!.rawValue)/redirect-target\r\nContent-Length: 0"
            body = ""
        case "status-error":
            headers = "401 Unauthorized\r\nContent-Length: 0"
            body = ""
        case "declared-large":
            headers = "200 OK\r\nContent-Length: 65537"
            body = String(repeating: "x", count: 65_537)
        case "streamed-large":
            headers = "200 OK"
            body = String(repeating: "x", count: 65_537)
        default:
            headers = "200 OK\r\nContent-Length: \(fixture.utf8.count)"
            body = fixture
        }
        connection.send(
            content: Data("HTTP/1.1 \(headers)\r\nConnection: close\r\n\r\n\(body)".utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func finishClose() {
        guard cancelled, peers.isEmpty else { return }
        closed?.resume()
        closed = nil
    }
}

@MainActor
private final class KiroTransportExchangeGate {
    var requests: [URLRequest] = []
    let started = KiroTransportEvent<URLRequest>()
    let finished = KiroTransportEvent<Void>()
    private var continuation: CheckedContinuation<Data, Never>?

    func exchange(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        let data = await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.send(request)
        }
        finished.send(())
        return data
    }

    func release(_ data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

@MainActor
private final class KiroTransportRawHTTP {
    private let connection: NWConnection
    private var continuation: CheckedContinuation<String, Error>?
    private var response = Data()

    private init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    static func send(port: UInt16, request: String) async throws -> String {
        let client = KiroTransportRawHTTP(port: port)
        return try await client.send(request)
    }

    private func send(_ request: String) async throws -> String {
        defer {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        // The suite's time limit cancels the task; no fixed-delay test work.
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                                MainActor.assumeIsolated {
                                    if let error { self.finish(.failure(error)) }
                                    else { self.receive() }
                                }
                            })
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, done, error in
            MainActor.assumeIsolated {
                if let data { self.response.append(data) }
                // Content-Length, not EOF, defines completion. A peer may reset
                // after sending its rejection when excess request bytes remain unread.
                if let boundary = self.response.range(of: Data("\r\n\r\n".utf8)),
                   let headers = String(data: self.response[..<boundary.lowerBound], encoding: .utf8),
                   let lengthLine = headers.components(separatedBy: "\r\n").first(where: {
                       $0.lowercased().hasPrefix("content-length:")
                   }),
                   let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                   self.response.count >= boundary.upperBound + length {
                    self.finish(.success(String(decoding: self.response, as: UTF8.self)))
                } else if let error { self.finish(.failure(error)) }
                else if done { self.finish(.failure(URLError(.badServerResponse))) }
                else { self.receive() }
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
