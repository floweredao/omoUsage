import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite(.serialized)
struct AccountSettingsDataTests {
    @Test
    func additionalCodexFetchDoesNotInheritPrimaryTier() async throws {
        let fixture = try AccountSettingsFixture()
        defer { fixture.remove() }
        fixture.defaults.set("20x", forKey: CodexPlanMultiplierStore.defaultsKey)
        let account = AccountID()
        try fixture.discovery.snapshotStore.save(
            CredentialSnapshot(
                provider: .codex,
                accessToken: "fixture-access-token",
                refreshToken: nil,
                accountReference: "fixture-owner",
                planName: nil,
                expiresAt: nil,
                source: .file
            ),
            for: AccountProviderID(accountID: account, providerID: .codex)
        )
        let usage = try await CodexUsageProvider(
            discovery: fixture.discovery,
            http: fixture.http,
            accountID: account,
            defaults: fixture.defaults
        ).fetch(now: fixture.now)
        #expect(usage.planName == "Pro")
    }

    @Test @MainActor
    func aliasesPersistPerProviderWithoutChangingIdentityOrSecrets() throws {
        let fixture = try AccountSettingsFixture()
        defer { fixture.remove() }
        let controller = try fixture.controller()
        let codex = AccountProviderID(accountID: .legacy, providerID: .codex)
        let claude = AccountProviderID(accountID: .legacy, providerID: .claude)
        let additional = try controller.addAPIKeyAccount(
            provider: .openrouter, label: "Work", key: "fixture-private-key"
        )
        let original = try #require(controller.registry)
        try controller.renameAccount(codex, label: " Personal Codex ")
        try controller.renameAccount(additional, label: "Billing")
        try controller.saveDisconnected([codex])
        try controller.saveOrder(original.displayOrder.reversed())
        let reloaded = try fixture.controller()
        #expect(reloaded.settingsAccounts(for: .codex).first?.label == "Personal Codex")
        #expect(reloaded.settingsAccounts(for: .claude).first?.label == AccountLabel.defaultValue)
        #expect(reloaded.accounts.first?.label == "Billing")
        #expect(reloaded.registry?.providerReferences == original.providerReferences)
        #expect(reloaded.registry?.accounts.map(\.id) == original.accounts.map(\.id))
        #expect(try fixture.keychain.value(
            service: ProviderAPIKeyStore.serviceName,
            account: ProviderCredentialSnapshotStore.account(for: additional)
        ) == "fixture-private-key")
        let providers = ProviderFactory.current(
            registry: try #require(reloaded.registry),
            environment: ["OMO_USAGE_FIXTURE_MODE": "1"],
            defaults: fixture.defaults
        )
        #expect(providers.first { $0.accountProviderID == codex }?.accountLabel == "Personal Codex")
        #expect(providers.first { $0.accountProviderID == claude }?.accountLabel == AccountLabel.defaultValue)
        #expect(providers.first { $0.accountProviderID == additional }?.accountLabel == "Billing")
    }

    @Test @MainActor
    func invalidAndDuplicateAliasesLeaveRegistryUnchanged() throws {
        let fixture = try AccountSettingsFixture()
        defer { fixture.remove() }
        let controller = try fixture.controller()
        let primary = AccountProviderID(accountID: .legacy, providerID: .openrouter)
        let additional = try controller.addAPIKeyAccount(
            provider: .openrouter, label: "Work", key: "fixture-key"
        )
        let original = controller.registry
        for invalid in [" ", "work", "raw@example.com", "../private"] {
            #expect(throws: ProviderAccountRegistryControllerError.invalidLabel) {
                try controller.renameAccount(primary, label: invalid)
            }
        }
        #expect(throws: ProviderAccountRegistryControllerError.invalidLabel) {
            try controller.renameAccount(additional, label: AccountLabel.defaultValue)
        }
        #expect(throws: ProviderAccountRegistryControllerError.accountNotFound) {
            try controller.renameAccount(
                AccountProviderID(accountID: AccountID(), providerID: .codex),
                label: "Unknown"
            )
        }
        #expect(controller.registry == original)
        try controller.renameAccount(primary, label: "Primary Router")
        #expect(throws: ProviderAccountRegistryControllerError.invalidLabel) {
            try controller.addAPIKeyAccount(
                provider: .openrouter, label: "primary router", key: "must-not-persist"
            )
        }
    }

    @Test @MainActor
    func settingsIncludesEveryPrimaryWithoutChangingAdditionalConsumer() throws {
        let fixture = try AccountSettingsFixture()
        defer { fixture.remove() }
        let controller = try fixture.controller()
        #expect(controller.accounts.isEmpty)
        for provider in ProviderID.allCases {
            let rows = controller.settingsAccounts(for: provider)
            #expect(rows.count == 1)
            #expect(rows.first?.isPrimary == true)
            #expect(rows.first?.accountProviderID == AccountProviderID(
                accountID: .legacy, providerID: provider
            ))
            #expect(rows.first?.maskedIdentity == nil)
        }
    }

    @Test @MainActor
    func codexTiersPersistIndependentlyAndReachComposedFetches() async throws {
        let fixture = try AccountSettingsFixture()
        defer { fixture.remove() }
        let controller = try fixture.controller()
        let primary = AccountProviderID(accountID: .legacy, providerID: .codex)
        let snapshot = CredentialSnapshot(
            provider: .codex, accessToken: "fixture-token", refreshToken: nil,
            accountReference: "fixture-owner", planName: nil, expiresAt: nil, source: .file
        )
        try fixture.discovery.snapshotStore.save(snapshot, for: primary)
        let extra = try controller.addCapturedCompanionAccount(
            provider: .codex, label: "Work", encodedSecret: snapshot.encodedSecret()
        )
        let mainStore = CodexPlanMultiplierStore(defaults: fixture.defaults)
        let extraStore = CodexPlanMultiplierStore(defaults: fixture.defaults, accountID: extra.accountID)
        mainStore.save(.twentyX)
        #expect(extraStore.load() == .automatic)
        extraStore.save(.fiveX)
        #expect(mainStore.load() == .twentyX)
        #expect(fixture.defaults.string(forKey: CodexPlanMultiplierStore.defaultsKey) == "20x")
        let providers = ProviderFactory.current(
            registry: try #require(controller.registry),
            environment: [:], defaults: fixture.defaults,
            discovery: fixture.discovery, http: fixture.http
        ).filter { $0.id == .codex }
        var usages: [ProviderUsage] = []
        for provider in providers {
            usages.append(try await provider.fetch(now: fixture.now))
        }
        #expect(usages.map(\.planName) == ["Pro 20x", "Pro 5x"])
        extraStore.save(.automatic)
        #expect(mainStore.load() == .twentyX)
        #expect(extraStore.load() == .automatic)
    }

    @Test @MainActor
    func identityUsesCapturedEmailAndNeverLeaksIntoRegistryOrUsage() async throws {
        let fixture = try AccountSettingsFixture()
        defer { fixture.remove() }
        let email = "person@example.com"
        let payload = try JSONSerialization.data(withJSONObject: ["email": email])
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let auth = #"{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-token","account_id":"fixture-owner","id_token":"header.\#(payload).signature"}}"#
        try Data(auth.utf8).write(to: fixture.discovery.paths.codex)
        let controller = try fixture.controller()
        #expect(controller.settingsAccounts(for: .codex).first?.maskedIdentity == "p***n@e***e.com")
        let captured = try fixture.discovery.captureCredential(for: .codex, now: fixture.now)
        let extra = try controller.addCapturedCompanionAccount(
            provider: .codex, label: "Extra", encodedSecret: captured
        )
        try FileManager.default.removeItem(at: fixture.discovery.paths.codex)
        #expect(controller.settingsAccounts(for: .codex).last?.maskedIdentity == "p***n@e***e.com")
        #expect(controller.settingsAccounts(for: .codex).first?.maskedIdentity == nil)
        try fixture.discovery.rotateSnapshot(
            extra, accessToken: "rotated-fixture-token", refreshToken: nil, expiresAt: nil
        )
        #expect(controller.settingsAccounts(for: .codex).last?.maskedIdentity == "p***n@e***e.com")
        let registry = try #require(controller.registry)
        let registryText = String(decoding: try JSONEncoder().encode(registry), as: UTF8.self)
        #expect(!registryText.contains(email))
        #expect(!registryText.contains("fixture-token"))
        let usage = try await CodexUsageProvider(
            discovery: fixture.discovery, http: fixture.http, accountID: extra.accountID
        ).fetch(now: fixture.now)
        #expect(!String(describing: usage).contains(email))
    }

    @Test(arguments: ["a@b.co", "ab@cd.com", "not-email", "a b@example.com",
                      "name@example.com\nsecret", "name@localhost", "token/path@example.com"])
    func identityMaskDoesNotExposeShortOrInvalidIdentifiers(_ email: String) {
        let masked = MaskedAccountIdentity.email(email)
        #expect(masked != email)
        if email == "a@b.co" || email == "ab@cd.com" {
            #expect(masked == "***@***.\(email == "a@b.co" ? "co" : "com")")
        } else {
            #expect(masked == nil)
        }
    }

    @Test
    func oldSnapshotDerivesIdentityFromOwnTokenWithoutFollowingCompanion() throws {
        let fixture = try AccountSettingsFixture()
        defer { fixture.remove() }
        let claims = try JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/profile": ["email": "person@example.com"]
        ]).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let old = #"{"version":1,"provider":"codex","accessToken":"header.\#(claims).signature","accountReference":"old-owner","source":"file"}"#
        let primary = AccountProviderID(accountID: .legacy, providerID: .codex)
        try fixture.keychain.set(
            old, service: ProviderAPIKeyStore.serviceName,
            account: ProviderCredentialSnapshotStore.account(for: primary)
        )
        let otherClaims = try JSONSerialization.data(withJSONObject: ["email": "wrong@example.com"])
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        let mutable = #"{"auth_mode":"chatgpt","tokens":{"access_token":"other-token","id_token":"header.\#(otherClaims).signature"}}"#
        try Data(mutable.utf8).write(to: fixture.discovery.paths.codex)
        #expect(fixture.discovery.maskedIdentity(for: primary, now: fixture.now) == "p***n@e***e.com")
        let extra = AccountProviderID(accountID: AccountID(), providerID: .codex)
        #expect(fixture.discovery.maskedIdentity(for: extra, now: fixture.now) == nil)
        try fixture.discovery.rotateSnapshot(
            primary, accessToken: "opaque-rotated-token", refreshToken: nil, expiresAt: nil
        )
        #expect(fixture.discovery.maskedIdentity(for: primary, now: fixture.now) == "p***n@e***e.com")
        try fixture.keychain.set(
            "malformed-secret", service: ProviderAPIKeyStore.serviceName,
            account: ProviderCredentialSnapshotStore.account(for: primary)
        )
        #expect(fixture.discovery.maskedIdentity(for: primary, now: fixture.now) == nil)
    }
}

private final class AccountSettingsFixture {
    let suiteName = "AccountSettingsDataTests-\(UUID().uuidString)"
    let home: URL
    let defaults: UserDefaults
    let store: ProviderAccountStore
    let discovery: CredentialDiscovery
    let keychain = AccountSettingsKeychain()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let http: ProviderHTTP

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        store = ProviderAccountStore(
            registryURL: home.appending(path: "registry/accounts.json"),
            defaults: defaults,
            legacyAPIKeyPresence: { _ in false }
        )
        _ = try store.loadOrMigrate()
        discovery = CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: "missing-claude.json"),
                codex: home.appending(path: "codex.json")
            ),
            environment: [:],
            keychain: AccountSettingsMissingKeychain(),
            providerKeychain: keychain,
            homeDirectory: home,
            commandPaths: []
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountSettingsURLProtocol.self]
        http = ProviderHTTP(session: URLSession(configuration: configuration))
    }

    @MainActor
    func controller() throws -> ProviderAccountRegistryController {
        ProviderAccountRegistryController(
            store: store,
            registry: try store.loadOrMigrate(),
            keyStore: { [self] provider, account in
                ProviderAPIKeyStore.live(
                    for: provider,
                    accountID: account,
                    home: home,
                    environment: [:],
                    keychain: keychain
                )
            },
            maskedIdentity: { [discovery, now] identity in
                discovery.maskedIdentity(for: identity, now: now)
            }
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: home)
    }
}

private struct AccountSettingsMissingKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? { nil }
}

private final class AccountSettingsKeychain: ProviderKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func value(service: String, account: String) throws -> String? {
        lock.withLock { values[service + "|" + account] }
    }
    func set(_ value: String, service: String, account: String) throws {
        lock.withLock { values[service + "|" + account] = value }
    }
    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: service + "|" + account) }
    }
}

private final class AccountSettingsURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000}}}"#
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
