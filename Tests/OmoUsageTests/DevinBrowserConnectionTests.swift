import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct DevinBrowserConnectionTests {
    @Test
    func browserSessionUsesCLIIdentityToRetrieveQuota() async throws {
        let fixture = try DevinCredentialFixture()
        defer { fixture.remove() }
        try fixture.snapshots.save(fixture.snapshot("devin-session-token$browser"), for: fixture.primary)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DevinBrowserQuotaProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let usage = try await DevinUsageProvider(
            discovery: fixture.discovery, http: ProviderHTTP(session: session)
        ).fetch(now: .distantPast)
        #expect(usage.availability == .available)
        #expect(usage.groups.flatMap(\.meters).map(\.percentRemaining) == [70, 40])
    }

    @Test
    @MainActor
    func browserConnectionValidatesBeforeSavingAndReturnsExactAccount() async throws {
        let fixture = try DevinCredentialFixture()
        defer { fixture.remove() }
        let coordinator = DevinBrowserConnectionCoordinator()
        let identity = AccountProviderID(accountID: AccountID(), providerID: .devin)
        var validated = false
        let result = try await coordinator.connect(
            target: .existing(identity),
            authenticate: { fixture.snapshot("browser-verified") },
            validate: { snapshot in
                #expect(snapshot.accessToken == "browser-verified")
                let stored = try fixture.snapshots.snapshot(for: identity)
                #expect(stored == nil)
                validated = true
                return ProviderUsage(provider: .devin, planName: "Pro", groups: [], availability: .available, updatedAt: .distantPast)
            },
            persist: { target, snapshot in
                #expect(validated)
                #expect(target == .existing(identity))
                try fixture.snapshots.save(snapshot, for: identity)
                return identity
            }
        )
        #expect(result == identity)
        #expect(try fixture.snapshots.snapshot(for: identity)?.accessToken == "browser-verified")
        #expect(try fixture.snapshots.snapshot(for: fixture.primary) == nil)
        #expect(coordinator.pending == nil)
    }

    @Test
    @MainActor
    func unavailableUsageNeverReplacesExistingCredential() async throws {
        let fixture = try DevinCredentialFixture()
        defer { fixture.remove() }
        try fixture.snapshots.save(fixture.snapshot("previous"), for: fixture.primary)
        let coordinator = DevinBrowserConnectionCoordinator()
        await #expect(throws: DevinBrowserConnectionError.usageUnavailable) {
            try await coordinator.connect(
                target: .existing(fixture.primary),
                authenticate: { fixture.snapshot("unverified") },
                validate: { _ in
                    ProviderUsage(provider: .devin, planName: "", groups: [], availability: .authenticationRequired, updatedAt: .distantPast)
                },
                persist: { _, snapshot in
                    try fixture.snapshots.save(snapshot, for: fixture.primary)
                    return fixture.primary
                }
            )
        }
        #expect(try fixture.snapshots.snapshot(for: fixture.primary)?.accessToken == "previous")
    }

    @Test
    @MainActor
    func cancellationAfterValidationDoesNotPersistCredential() async throws {
        let fixture = try DevinCredentialFixture()
        defer { fixture.remove() }
        let coordinator = DevinBrowserConnectionCoordinator()
        let task = Task { @MainActor in
            try await coordinator.connect(
                target: .existing(fixture.primary),
                authenticate: { fixture.snapshot("cancelled") },
                validate: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return ProviderUsage(provider: .devin, planName: "Pro", groups: [], availability: .available, updatedAt: .distantPast)
                },
                persist: { _, snapshot in
                    try fixture.snapshots.save(snapshot, for: fixture.primary)
                    return fixture.primary
                }
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try fixture.snapshots.snapshot(for: fixture.primary) == nil)
        #expect(coordinator.pending == nil)
    }

    @Test
    func primaryBrowserCredentialWinsOverCompanionFile() throws {
        let fixture = try DevinCredentialFixture()
        defer { fixture.remove() }
        try fixture.writeCompanion("companion-account")
        try fixture.snapshots.save(fixture.snapshot("browser-account"), for: fixture.primary)

        #expect(try fixture.discovery.devin().accessToken == "browser-account")
    }

    @Test
    func malformedPrimaryBrowserCredentialCannotFallBackToCompanion() throws {
        let fixture = try DevinCredentialFixture()
        defer { fixture.remove() }
        try fixture.writeCompanion("unrelated-companion")
        try fixture.keychain.set(
            "malformed-snapshot",
            service: ProviderAPIKeyStore.serviceName,
            account: ProviderCredentialSnapshotStore.account(for: fixture.primary)
        )

        #expect(throws: CredentialDiscoveryError.malformed(.devin)) {
            try fixture.discovery.devin()
        }
    }

    @Test
    func browserAccountsRemainIsolatedFromPrimaryAndCompanion() throws {
        let fixture = try DevinCredentialFixture()
        defer { fixture.remove() }
        let secondary = AccountProviderID(accountID: AccountID(), providerID: .devin)
        try fixture.writeCompanion("companion-account")
        try fixture.snapshots.save(fixture.snapshot("primary-browser"), for: fixture.primary)
        try fixture.snapshots.save(fixture.snapshot("secondary-browser"), for: secondary)

        #expect(try fixture.discovery.devin(accountID: secondary.accountID).accessToken == "secondary-browser")
        #expect(try fixture.discovery.devin().accessToken == "primary-browser")
        #expect(throws: CredentialDiscoveryError.notFound(.devin)) {
            try fixture.discovery.devin(accountID: AccountID())
        }
    }
}

private struct DevinCredentialFixture {
    let home: URL
    let keychain = DevinTestKeychain()
    let primary = AccountProviderID(accountID: .legacy, providerID: .devin)

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsage-Devin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var snapshots: ProviderCredentialSnapshotStore {
        ProviderCredentialSnapshotStore(keychain: keychain)
    }

    var discovery: CredentialDiscovery {
        CredentialDiscovery(
            paths: CredentialPaths(claude: home.appending(path: "claude"), codex: home.appending(path: "codex")),
            environment: [:],
            keychain: DevinEmptyKeychain(),
            providerKeychain: keychain,
            homeDirectory: home,
            commandPaths: []
        )
    }

    func snapshot(_ token: String) -> CredentialSnapshot {
        CredentialSnapshot(
            provider: .devin, accessToken: token, refreshToken: nil,
            accountReference: nil, planName: nil, expiresAt: nil, source: .keychain
        )
    }

    func writeCompanion(_ token: String) throws {
        let file = home.appending(path: ".local/share/devin/credentials.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "windsurf_api_key = \"\(token)\"".write(to: file, atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

private struct DevinEmptyKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? { nil }
}

private final class DevinBrowserQuotaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let metadata = root?["metadata"] as? [String: String]
        let valid = metadata?["apiKey"] == "devin-session-token$browser"
            && metadata?["ideName"] == "devin-cli"
            && metadata?["ideType"] == "chisel"
            && metadata?["extensionName"] == "chisel"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: valid ? 200 : 403,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("""
        {"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":70,"weeklyQuotaRemainingPercent":40}}}
        """.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DevinTestKeychain: ProviderKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(service: String, account: String) throws -> String? {
        lock.withLock { values[service + "/" + account] }
    }

    func set(_ value: String, service: String, account: String) throws {
        lock.withLock { values[service + "/" + account] = value }
    }

    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: service + "/" + account) }
    }
}
