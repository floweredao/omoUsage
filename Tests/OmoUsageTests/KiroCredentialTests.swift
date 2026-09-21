import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct KiroCredentialTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let arn = "arn:aws:codewhisperer:us-east-1:123456789012:profile/test-profile"

    @Test
    func captureMissingOfficialCredentialIsTyped() throws {
        let kiro = try #require(ProviderID(rawValue: "kiro"))
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("KiroCredentialTests-\(UUID().uuidString)")
        let discovery = discovery(home: home)
        #expect(throws: CredentialDiscoveryError.notFound(kiro)) {
            try discovery.captureCredential(
                for: kiro,
                now: Date(timeIntervalSince1970: 1_790_000_000)
            )
        }
    }

    @Test(arguments: [nil, "/isolated/kiro", "relative/kiro", "~/kiro"])
    func readsOnlyOfficialDatabaseWithAbsoluteOverride(_ override: String?) throws {
        let home = URL(fileURLWithPath: "/isolated/home")
        let expected = override?.hasPrefix("/") == true
            ? "\(override!)/data.sqlite3"
            : "/isolated/home/Library/Application Support/kiro-cli/data.sqlite3"
        let credential = try discovery(
            home: home, environment: override.map { ["KIRO_DATA_DIR": $0] } ?? [:]
        ).mutableKiroCredential(now: now) { database, sql in
            #expect(database.path == expected)
            switch sql {
            case "SELECT value FROM auth_kv WHERE key='kirocli:odic:token';":
                return #"{"access_token":"fixture-access","refresh_token":"do-not-copy","expires_at":"2099-01-01T00:00:00.123456Z"}"#
            case "SELECT value FROM state WHERE key='api.codewhisperer.profile';":
                return #"{"arn":"arn:aws:codewhisperer:us-east-1:123456789012:profile/test-profile"}"#
            default:
                Issue.record("Unexpected SQLite query")
                return nil
            }
        }
        #expect(credential.accessToken == "fixture-access")
        #expect(credential.accountID == arn)
        #expect(credential.refreshToken == nil)
        #expect(credential.storage == nil)
        #expect(credential.source == .file)
        #expect(credential.expiresAt != nil)
        #expect(!credential.description.contains("fixture-access"))
    }

    @Test(arguments: [
        #"{"access_token":"token","expires_at":"bad"}"#,
        #"{"access_token":"token","expires_at":true}"#,
        #"{"access_token":"token","expires_at":9999999999}"#,
        #"{"access_token":"token"}"#,
        #"{"access_token":"","expires_at":"2099-01-01T00:00:00Z"}"#,
        #"{"access_token":"bad\nheader","expires_at":"2099-01-01T00:00:00Z"}"#
    ])
    func rejectsMalformedTokenWithoutLosingExpiry(_ token: String) throws {
        #expect(throws: CredentialDiscoveryError.malformed(.kiro)) {
            try discovery().mutableKiroCredential(now: now) { _, sql in
                sql.contains("auth_kv") ? token
                    : #"{"arn":"arn:aws:codewhisperer:us-east-1:123456789012:profile/test-profile"}"#
            }
        }
    }

    @Test
    func expiredAndMissingCredentialsRemainDistinct() throws {
        #expect(throws: CredentialDiscoveryError.expired(.kiro)) {
            try discovery().mutableKiroCredential(now: now) { _, sql in
                sql.contains("auth_kv")
                    ? #"{"access_token":"token","expires_at":"2020-01-01T00:00:00Z"}"#
                    : #"{"arn":"arn:aws:codewhisperer:us-east-1:123456789012:profile/test-profile"}"#
            }
        }
        #expect(throws: CredentialDiscoveryError.notFound(.kiro)) {
            try discovery().mutableKiroCredential(now: now) { _, _ in nil }
        }
        #expect(throws: CredentialDiscoveryError.malformed(.kiro)) {
            try discovery().mutableKiroCredential(now: now) { _, _ in
                throw LocalDataAccessError.commandFailed
            }
        }
    }

    @Test(arguments: [
        "arn:aws-cn:codewhisperer:us-east-1:123:profile/test",
        "arn:aws:other:us-east-1:123:profile/test",
        "arn:aws:codewhisperer:evil.example:123:profile/test",
        "arn:aws:codewhisperer:us-west-2:123:profile/test",
        "arn:aws:codewhisperer:us-east-1:123:profile/",
        "arn:aws:codewhisperer:us-east-1:123:profile/test\n"
    ])
    func rejectsUnsupportedProfile(_ profile: String) {
        #expect(throws: CredentialDiscoveryError.malformed(.kiro)) {
            try CredentialDiscovery.kiroEndpoint(profileARN: profile)
        }
    }

    @Test
    func snapshotsAreAccountIsolatedAndLegacyPinWins() throws {
        let secondary = try #require(AccountID(rawValue: "00000000-0000-0000-0000-000000000002"))
        let snapshot = CredentialSnapshot(
            provider: .kiro, accessToken: "pinned", refreshToken: nil,
            accountReference: arn, planName: nil,
            expiresAt: now.addingTimeInterval(600), source: .file
        )
        for account in [AccountID.legacy, secondary] {
            let identity = AccountProviderID(accountID: account, providerID: .kiro)
            let key = ProviderCredentialSnapshotStore.account(for: identity)
            let reader = KiroEmptyKeychain(values: [key: try snapshot.encodedSecret()])
            let credential = try discovery(keychain: reader).kiro(accountID: account, now: now) { _, _ in
                Issue.record("Pinned account must never read the global CLI")
                return nil
            }
            #expect(credential.accessToken == "pinned")
            #expect(credential.storage == .accountSnapshot(identity))
        }
        #expect(throws: CredentialDiscoveryError.notFound(.kiro)) {
            try discovery().kiro(accountID: secondary, now: now) { _, _ in
                Issue.record("Missing secondary snapshot must not fall back")
                return nil
            }
        }
    }

    @Test
    func mutableCaptureBypassesLegacyPin() throws {
        let snapshot = CredentialSnapshot(
            provider: .kiro, accessToken: "pinned", refreshToken: nil,
            accountReference: arn, planName: nil,
            expiresAt: now.addingTimeInterval(600), source: .file
        )
        let key = ProviderCredentialSnapshotStore.account(
            for: AccountProviderID(accountID: .legacy, providerID: .kiro)
        )
        let credential = try discovery(
            keychain: KiroEmptyKeychain(values: [key: try snapshot.encodedSecret()])
        ).mutableKiroCredential(now: now) { _, sql in
            sql.contains("auth_kv")
                ? #"{"access_token":"new-profile","expires_at":"2099-01-01T00:00:00Z"}"#
                : #"{"arn":"arn:aws:codewhisperer:eu-central-1:123456789012:profile/new"}"#
        }
        #expect(credential.accessToken == "new-profile")
        #expect(credential.accountID?.hasSuffix("/new") == true)
    }

    private func discovery(
        home: URL = URL(fileURLWithPath: "/isolated/kiro-test-home"),
        environment: [String: String] = [:],
        keychain: KiroEmptyKeychain = KiroEmptyKeychain()
    ) -> CredentialDiscovery {
        CredentialDiscovery(
            paths: CredentialPaths(claude: home.appendingPathComponent("claude"), codex: home.appendingPathComponent("codex")),
            environment: environment,
            keychain: keychain,
            homeDirectory: home,
            commandPaths: []
        )
    }
}

private struct KiroEmptyKeychain: KeychainReading {
    var values: [String: String] = [:]
    func value(service: String, account: String) throws -> String? { values[account] }
}
