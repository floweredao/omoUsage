import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
@MainActor
struct ProviderAccountAdditionCoordinatorTests {
    @Test
    func kiroTokenRenewalDoesNotAddTheSameProfileAgain() throws {
        let kiro = try #require(ProviderID(rawValue: "kiro"))
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        let original = try CredentialSnapshot(
            provider: kiro, accessToken: "kiro-original", refreshToken: nil,
            accountReference: "arn:aws:codewhisperer:us-east-1:123456789012:profile/original",
            planName: nil, expiresAt: nil, source: .file
        ).encodedSecret()
        let renewed = try CredentialSnapshot(
            provider: kiro, accessToken: "kiro-renewed", refreshToken: nil,
            accountReference: "arn:aws:codewhisperer:us-east-1:123456789012:profile/original",
            planName: nil, expiresAt: nil, source: .file
        ).encodedSecret()
        fixture.capture[kiro] = .success(original)
        #expect(coordinator.addAccount(provider: kiro, label: "Work", key: nil) == .waitingForCompanion)
        fixture.capture[kiro] = .success(renewed)
        #expect(coordinator.checkAgain() == .credentialUnchanged)
        #expect(fixture.controller.accounts.isEmpty)
    }

    @Test
    func kiroAdditionPinsPrimaryBeforeSwitchingCompanionProfile() throws {
        let kiro = try #require(ProviderID(rawValue: "kiro"))
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        let original = try CredentialSnapshot(
            provider: kiro, accessToken: "kiro-original", refreshToken: nil,
            accountReference: "arn:aws:codewhisperer:us-east-1:123456789012:profile/original",
            planName: nil, expiresAt: nil, source: .file
        ).encodedSecret()
        let other = try CredentialSnapshot(
            provider: kiro, accessToken: "kiro-other", refreshToken: nil,
            accountReference: "arn:aws:codewhisperer:us-east-1:123456789012:profile/other",
            planName: nil, expiresAt: nil, source: .file
        ).encodedSecret()
        fixture.capture[kiro] = .success(original)
        #expect(coordinator.addAccount(provider: kiro, label: "Work", key: nil) == .waitingForCompanion)
        #expect(fixture.keyStore(kiro, .legacy)?.load() == original)
        fixture.capture[kiro] = .success(other)
        #expect(coordinator.checkAgain() == .addedAccount("Work"))
        #expect(fixture.keyStore(kiro, .legacy)?.load() == original)
        let added = try #require(fixture.controller.accounts.first)
        #expect(fixture.keyStore(kiro, added.accountProviderID.accountID)?.load() == other)
    }

    @Test
    func kiroExplicitImportRenewsOnlyTheSelectedProfile() throws {
        let kiro = try #require(ProviderID(rawValue: "kiro"))
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func secret(_ token: String, profile: String) throws -> String {
            try CredentialSnapshot(
                provider: kiro, accessToken: token, refreshToken: nil,
                accountReference: "arn:aws:codewhisperer:us-east-1:123456789012:profile/\(profile)",
                planName: nil, expiresAt: now.addingTimeInterval(3_600), source: .file
            ).encodedSecret()
        }
        let original = try secret("kiro-original", profile: "original")
        let renewed = try secret("kiro-renewed", profile: "original")
        let other = try secret("kiro-other", profile: "other")
        let account = try fixture.controller.addCapturedCompanionAccount(
            provider: kiro, label: "Work", encodedSecret: original
        )
        let identity = account
        try fixture.controller.importKiroCredential(renewed, for: identity, now: now)
        #expect(fixture.keyStore(kiro, account.accountID)?.load() == renewed)
        #expect(throws: ProviderAccountRegistryControllerError.credentialUnavailable) {
            try fixture.controller.importKiroCredential(other, for: identity, now: now)
        }
        #expect(fixture.keyStore(kiro, account.accountID)?.load() == renewed)
        #expect(fixture.keyStore(kiro, .legacy)?.load() == nil)
    }

    @Test
    func launchesCompanionBeforePersistingAnyAccount() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)

        let outcome = coordinator.addAccount(
            provider: .codex,
            label: "Work",
            key: nil
        )

        #expect(outcome == .waitingForCompanion)
        #expect(fixture.events == ["capture:codex", "launch:codex"])
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.legacyCodexSecret == fixture.codexSecretA)
        #expect(fixture.refreshCount == 0)
        #expect(coordinator.pending?.provider == .codex)
        #expect(coordinator.pending?.label == "Work")

        let fingerprint = try #require(
            coordinator.pending?.credentialFingerprint
        )
        #expect(fingerprint.count == 64)
        #expect(!fixture.codexSecretA.contains(fingerprint))
        #expect(
            fingerprint.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
        )

        // One pending companion addition globally: a second companion
        // Add must not launch anything while the first one waits.
        #expect(
            coordinator.addAccount(
                provider: .claude,
                label: "Personal",
                key: nil
            ) == .additionInProgress
        )
        #expect(fixture.events == ["capture:codex", "launch:codex"])
        #expect(coordinator.pending?.provider == .codex)
    }

    @Test
    func unchangedCredentialRemainsPendingWithoutPersisting() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )
        fixture.events.removeAll()

        #expect(coordinator.checkAgain() == .credentialUnchanged)

        #expect(coordinator.pending?.provider == .codex)
        #expect(coordinator.pending?.label == "Work")
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.legacyCodexSecret == fixture.codexSecretA)
        #expect(fixture.refreshCount == 0)
        #expect(fixture.events == ["capture:codex"])

        fixture.capture[.codex] = .failure(
            CredentialDiscoveryError.notFound(.codex)
        )

        #expect(coordinator.checkAgain() == .credentialMissing)

        #expect(coordinator.pending?.provider == .codex)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.legacyCodexSecret == fixture.codexSecretA)
        #expect(fixture.refreshCount == 0)
    }

    @Test
    func changedCredentialPreservesLegacyAndAddsFreshAccount() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)

        #expect(coordinator.addAccount(provider: .codex, label: "Work", key: nil) == .waitingForCompanion)
        fixture.capture[.codex] = .success(fixture.codexSecretB)
        #expect(coordinator.checkAgain() == .addedAccount("Work"))

        #expect(fixture.legacyCodexSecret == fixture.codexSecretA)
        let account = try #require(fixture.controller.accounts.first)
        #expect(fixture.keyStore(.codex, account.accountProviderID.accountID)?.load() == fixture.codexSecretB)
    }

    @Test
    func legacyPreservationFailurePreventsLaunch() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        fixture.keychain.failWritesToAccount = "codex/\(AccountID.legacy.rawValue)"
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)

        #expect(coordinator.addAccount(provider: .codex, label: "Work", key: nil) == .credentialUnavailable)
        #expect(fixture.events == ["capture:codex"])
        #expect(coordinator.pending == nil)
    }

    @Test
    func repeatedCodexAdditionKeepsOriginalLegacySnapshot() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(coordinator.addAccount(provider: .codex, label: "Work", key: nil) == .waitingForCompanion)
        fixture.capture[.codex] = .success(fixture.codexSecretB)
        #expect(coordinator.checkAgain() == .addedAccount("Work"))

        #expect(coordinator.addAccount(provider: .codex, label: "Third", key: nil) == .waitingForCompanion)
        #expect(fixture.legacyCodexSecret == fixture.codexSecretA)
    }

    @Test
    func codexRotationIsNotAnotherAccount() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(coordinator.addAccount(provider: .codex, label: "Work", key: nil) == .waitingForCompanion)
        let original = try CredentialSnapshot(encodedSecret: fixture.codexSecretA, provider: .codex)
        fixture.capture[.codex] = .success(try original.rotated(
            accessToken: "new-token-for-the-same-account",
            refreshToken: "new-refresh-for-the-same-account",
            expiresAt: original.expiresAt?.addingTimeInterval(3_600)
        ).encodedSecret())

        #expect(coordinator.checkAgain() == .credentialUnchanged)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.refreshCount == 0)
        #expect(coordinator.isWaitingForCompanion)
    }

    @Test
    func changedCredentialPersistsFreshAccountAndRequestsRefresh() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )
        fixture.capture[.codex] = .success(fixture.codexSecretB)

        #expect(
            coordinator.applicationDidBecomeActive()
                == .addedAccount("Work")
        )

        #expect(coordinator.pending == nil)
        #expect(fixture.refreshCount == 1)
        let account = try #require(fixture.controller.accounts.first)
        #expect(fixture.controller.accounts.count == 1)
        #expect(account.provider == .codex)
        #expect(account.label == "Work")
        #expect(account.accountProviderID.accountID != .legacy)
        #expect(
            account.accountProviderID.accountID
                == fixture.nextAccountIDs[0]
        )
        #expect(
            fixture.keyStore(
                .codex,
                account.accountProviderID.accountID
            )?.load() == fixture.codexSecretB
        )

        // A later activation must not add a second account or ask for
        // another refresh: the pending addition is already finished.
        #expect(coordinator.applicationDidBecomeActive() == .ignored)
        #expect(fixture.controller.accounts.count == 1)
        #expect(fixture.refreshCount == 1)
    }

    @Test
    func cancelledAdditionIgnoresLaterActivation() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )

        coordinator.cancel()
        #expect(coordinator.pending == nil)

        fixture.capture[.codex] = .success(fixture.codexSecretB)

        #expect(coordinator.applicationDidBecomeActive() == .ignored)
        #expect(coordinator.checkAgain() == .ignored)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.legacyCodexSecret == fixture.codexSecretA)
        #expect(fixture.refreshCount == 0)
    }

    @Test
    func apiKeyAdditionRemainsImmediateWithoutLaunchingCompanion() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()

        let outcome = coordinator.addAccount(
            provider: .openrouter,
            label: "Team",
            key: "openrouter-secret"
        )

        #expect(outcome == .addedAccount("Team"))
        #expect(fixture.events.isEmpty)
        #expect(coordinator.pending == nil)
        #expect(fixture.refreshCount == 1)
        let account = try #require(fixture.controller.accounts.first)
        #expect(account.provider == .openrouter)
        #expect(
            fixture.keyStore(
                .openrouter,
                account.accountProviderID.accountID
            )?.load() == "openrouter-secret"
        )

        // An API-key account stays addable while a companion addition
        // is still waiting for its credential.
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )

        #expect(
            coordinator.addAccount(
                provider: .zai,
                label: "Personal",
                key: "zai-secret"
            ) == .addedAccount("Personal")
        )
        #expect(fixture.refreshCount == 2)
        #expect(coordinator.pending?.provider == .codex)
        #expect(
            fixture.controller.accounts.map(\.provider)
                == [.openrouter, .zai]
        )
    }

    @Test
    func rejectsInvalidLabelBeforeLaunchingCompanion() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .success(fixture.codexSecretA)

        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "person@example.com",
                key: nil
            ) == .invalidLabel
        )

        #expect(fixture.events.isEmpty)
        #expect(coordinator.pending == nil)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.keychain.isEmpty)
    }

    @Test
    func unreadableBaselineCredentialNeverLaunchesOrPersists() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .failure(
            CredentialDiscoveryError.malformed(.codex)
        )

        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .credentialUnavailable
        )

        #expect(fixture.events == ["capture:codex"])
        #expect(coordinator.pending == nil)
        #expect(fixture.controller.accounts.isEmpty)
        #expect(fixture.keychain.isEmpty)
    }

    @Test
    func missingBaselineCaptureStillWaitsForTheFirstCredential() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator()
        fixture.capture[.codex] = .failure(
            CredentialDiscoveryError.notFound(.codex)
        )

        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )
        #expect(coordinator.pending?.credentialFingerprint == nil)

        fixture.capture[.codex] = .success(fixture.codexSecretA)

        #expect(coordinator.checkAgain() == .addedAccount("Work"))
        #expect(
            fixture.keyStore(
                .codex,
                try #require(
                    fixture.controller.accounts.first
                ).accountProviderID.accountID
            )?.load() == fixture.codexSecretA
        )
    }

    @Test
    func failedPersistenceKeepsTheAdditionWaiting() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let coordinator = fixture.makeCoordinator(
            failingAfter: .secretStaged
        )
        fixture.capture[.codex] = .success(fixture.codexSecretA)
        #expect(
            coordinator.addAccount(
                provider: .codex,
                label: "Work",
                key: nil
            ) == .waitingForCompanion
        )
        fixture.capture[.codex] = .success(fixture.codexSecretB)

        #expect(coordinator.checkAgain() == .failed)

        #expect(coordinator.pending?.provider == .codex)
        #expect(fixture.controller.accounts.isEmpty)
        // The rolled-back mutation leaves no usable account secret; the
        // staged item stays for the journal to reconcile.
        #expect(
            fixture.keyStore(
                .codex,
                fixture.nextAccountIDs[0]
            )?.load() == nil
        )
        #expect(fixture.refreshCount == 0)
    }
}

@Suite(.serialized)
@MainActor
struct CodexAccountAdditionRotationTests {
    @Test(arguments: [false, true])
    func lateRefreshCannotOverwriteRelogin(pinned: Bool) throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_785_675_000)
        let legacy = AccountProviderID(accountID: .legacy, providerID: .codex)
        let authURL = fixture.rootURL.appending(path: "auth.json")
        let original = CodexPinRotationURLProtocol.credential(token: "old-access", account: "original")
        try Data(original.utf8).write(to: authURL)
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: fixture.rootURL.appending(path: "missing.json"), codex: authURL),
            environment: [:], keychain: fixture.keychain, providerKeychain: fixture.keychain,
            homeDirectory: fixture.homeURL, commandPaths: []
        )
        if pinned {
            try fixture.controller.preserveLegacyCodexCredentialIfAbsent(
                discovery.captureCredential(for: .codex, now: now)
            )
        }
        let inFlight = try discovery.codex(now: now)
        let replacement = CodexPinRotationURLProtocol.credential(token: "fresh-login", account: "replacement")
        try Data(replacement.utf8).write(to: authURL)
        if pinned {
            try fixture.controller.replaceLegacyCodexCredential(
                discovery.captureCredential(for: .codex, now: now)
            )
        }

        #expect(throws: CredentialDiscoveryError.malformed(.codex)) {
            try discovery.persistCodexCredential(
                accessToken: "late-access", refreshToken: "late-refresh",
                idToken: nil, lastRefresh: now, replacing: inFlight
            )
        }
        #expect(try String(contentsOf: authURL, encoding: .utf8) == replacement)
        if pinned {
            #expect(try discovery.snapshotStore.snapshot(for: legacy)?.accessToken == "fresh-login")
            #expect(try discovery.snapshotStore.snapshot(for: legacy)?.accountReference == "replacement")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [CredentialSource.file, .keychain])
    func reloggedMainSurvivesAddingAnotherAccount(source: CredentialSource) async throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_785_675_000)
        let legacy = AccountProviderID(accountID: .legacy, providerID: .codex)
        let stale = CredentialSnapshot(
            provider: .codex,
            accessToken: CodexPinRotationURLProtocol.jwt(expiration: now.addingTimeInterval(1_800)),
            refreshToken: "revoked-refresh",
            accountReference: "original",
            planName: nil,
            expiresAt: now.addingTimeInterval(1_800),
            source: source
        )
        try fixture.controller.preserveLegacyCodexCredentialIfAbsent(stale.encodedSecret())
        let authURL = fixture.rootURL.appending(path: "auth.json")
        func writeCompanion(token: String, account: String) throws {
            let raw = CodexPinRotationURLProtocol.credential(token: token, account: account)
            if source == .file {
                try Data(raw.utf8).write(to: authURL)
            } else {
                try fixture.keychain.set(raw, service: "Codex Auth", account: "")
            }
        }
        let freshAccess = CodexPinRotationURLProtocol.jwt(expiration: now.addingTimeInterval(3_600))
        try writeCompanion(token: freshAccess, account: "original")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: fixture.rootURL.appending(path: "missing.json"), codex: authURL),
            environment: [:],
            keychain: fixture.keychain,
            providerKeychain: fixture.keychain,
            keychainWriter: CodexPinRotationWriter(keychain: fixture.keychain),
            homeDirectory: fixture.homeURL,
            commandPaths: []
        )
        let coordinator = ProviderAccountAdditionCoordinator(
            controller: fixture.controller,
            captureCredential: { try discovery.captureCredential(for: $0, now: now) },
            launchCompanion: { _ in .success(.launched) },
            onAccountAdded: {}
        )
        #expect(coordinator.addAccount(provider: .codex, label: "Work", key: nil) == .waitingForCompanion)
        #expect(try discovery.snapshotStore.snapshot(for: legacy)?.accessToken == freshAccess)
        try writeCompanion(token: "replacement-access", account: "replacement")
        #expect(coordinator.checkAgain() == .addedAccount("Work"))
        let added = try #require(fixture.controller.accounts.first?.accountProviderID)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexPinRotationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        _ = CodexPinRotationURLProtocol.reset()
        defer { CodexPinRotationURLProtocol.completeRefresh() }
        let model = UsageDashboardViewModel(
            providers: [legacy, added].map {
                CodexUsageProvider(
                    discovery: discovery,
                    http: providerHTTPTestClient(session: session),
                    accountID: $0.accountID
                )
            },
            accountProviderOrder: [legacy, added],
            now: { now }
        )
        await model.refresh()
        #expect(Set(model.snapshot.providers.map(\.accountProviderID)) == [legacy, added])
        #expect(model.accountConnectionStates[legacy] == .available)
        #expect(model.snapshot.providers.first { $0.accountProviderID == legacy }?
            .groups.flatMap(\.meters).first?.percentRemaining == 80)
        #expect(model.snapshot.providers.first { $0.accountProviderID == added }?
            .groups.flatMap(\.meters).first?.percentRemaining == 30)
        #expect(CodexPinRotationURLProtocol.refreshCount == 0)
        #expect(try discovery.codex(now: now).accessToken == freshAccess)
        #expect(try discovery.codex(accountID: added.accountID, now: now).accessToken == "replacement-access")
    }

    @Test
    func newerSameIdentityCompanionRepairsPinnedCredential() throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_785_675_000)
        let legacy = AccountProviderID(accountID: .legacy, providerID: .codex)
        let stale = CredentialSnapshot(
            provider: .codex, accessToken: "stale-main", refreshToken: "revoked-refresh",
            accountReference: "original", planName: nil,
            expiresAt: now.addingTimeInterval(1_800), source: .file
        )
        try fixture.controller.preserveLegacyCodexCredentialIfAbsent(stale.encodedSecret())
        let authURL = fixture.rootURL.appending(path: "auth.json")
        let freshAccess = CodexPinRotationURLProtocol.jwt(expiration: now.addingTimeInterval(3_600))
        try Data(CodexPinRotationURLProtocol.credential(token: freshAccess, account: "original").utf8).write(to: authURL)
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: fixture.rootURL.appending(path: "missing.json"), codex: authURL),
            environment: [:], keychain: fixture.keychain, providerKeychain: fixture.keychain,
            homeDirectory: fixture.homeURL, commandPaths: []
        )
        #expect(try discovery.codex(now: now).accessToken == freshAccess)
        #expect(discovery.codexCandidates(now: now).first?.accessToken == freshAccess)
        #expect(try discovery.snapshotStore.snapshot(for: legacy)?.accessToken == freshAccess)
        try FileManager.default.removeItem(at: authURL)
        #expect(try discovery.codex(now: now).accessToken == freshAccess)
    }

    @Test(arguments: ["older", "foreign", "missing-identity"])
    func staleOrForeignCompanionCannotReplacePinnedCredential(kind: String) throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_785_675_000)
        let stored = CredentialSnapshot(
            provider: .codex, accessToken: "pinned-main", refreshToken: "pinned-refresh",
            accountReference: "original", planName: nil,
            expiresAt: now.addingTimeInterval(3_600), source: .file
        )
        try fixture.controller.preserveLegacyCodexCredentialIfAbsent(stored.encodedSecret())
        let authURL = fixture.rootURL.appending(path: "auth.json")
        let candidate = CodexPinRotationURLProtocol.jwt(
            expiration: now.addingTimeInterval(kind == "older" ? 1_800 : 7_200)
        )
        let account = kind == "older" ? "original" : kind == "foreign" ? "replacement" : ""
        try Data(CodexPinRotationURLProtocol.credential(token: candidate, account: account).utf8).write(to: authURL)
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: fixture.rootURL.appending(path: "missing.json"), codex: authURL),
            environment: [:], keychain: fixture.keychain, providerKeychain: fixture.keychain,
            homeDirectory: fixture.homeURL, commandPaths: []
        )
        try fixture.controller.preserveLegacyCodexCredentialIfAbsent(
            discovery.captureCredential(for: .codex, now: now)
        )
        #expect(try discovery.codex(now: now).accessToken == "pinned-main")
        #expect(discovery.codexCandidates(now: now).first?.accessToken == "pinned-main")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [CredentialSource.file, .keychain])
    func addingAccountDuringRefreshKeepsBothAccountsUsable(
        source: CredentialSource
    ) async throws {
        let fixture = try AdditionFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_785_675_000)
        let authURL = fixture.rootURL.appending(path: "auth.json")
        let original = CodexPinRotationURLProtocol.credential(
            token: CodexPinRotationURLProtocol.jwt(expiration: now.addingTimeInterval(-60)),
            account: "original"
        )
        let replacement = CodexPinRotationURLProtocol.credential(
            token: "replacement-access",
            account: "replacement"
        )
        func writeCompanion(_ secret: String) throws {
            if source == .file {
                try Data(secret.utf8).write(to: authURL)
            } else {
                try fixture.keychain.set(secret, service: "Codex Auth", account: "")
            }
        }
        try writeCompanion(original)
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(
                claude: fixture.rootURL.appending(path: "missing.json"),
                codex: authURL
            ),
            environment: [:],
            keychain: fixture.keychain,
            providerKeychain: fixture.keychain,
            keychainWriter: CodexPinRotationWriter(keychain: fixture.keychain),
            homeDirectory: fixture.homeURL,
            commandPaths: []
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexPinRotationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let http = providerHTTPTestClient(session: session)
        let started = CodexPinRotationURLProtocol.reset()
        let provider = CodexUsageProvider(discovery: discovery, http: http)
        let refresh = Task { try await provider.fetch(now: now) }
        defer {
            CodexPinRotationURLProtocol.completeRefresh()
            refresh.cancel()
        }
        var iterator = started.makeAsyncIterator()
        _ = try #require(await iterator.next())

        // The refresh grant has been consumed, but its response has not yet
        // reached the provider. Official login replaces the companion store.
        let coordinator = ProviderAccountAdditionCoordinator(
            controller: fixture.controller,
            captureCredential: { try discovery.captureCredential(for: $0, now: now) },
            launchCompanion: { _ in .success(.launched) },
            onAccountAdded: {}
        )
        #expect(coordinator.addAccount(provider: .codex, label: "Work", key: nil) == .waitingForCompanion)
        try writeCompanion(replacement)
        #expect(coordinator.checkAgain() == .addedAccount("Work"))
        CodexPinRotationURLProtocol.completeRefresh()
        _ = try await refresh.value

        // Rebuild the real account-scoped providers just as registry changes
        // do in the app, then let the dashboard apply its auth-failure hiding.
        let composition = AppAccountCompositionFactory.make(
            registry: fixture.controller.registry,
            providerFactory: { registry in
                registry.providerReferences.filter { $0.providerID == .codex }.map { identity in
                    CodexUsageProvider(
                        discovery: discovery,
                        http: http,
                        accountID: identity.accountID,
                        accountLabel: registry.accounts.first { $0.id == identity.accountID }!.label
                    )
                }
            }
        )
        let model = UsageDashboardViewModel(
            providers: composition.providers,
            accountProviderOrder: composition.accountProviderOrder,
            disconnectedAccountProviders: composition.disconnected,
            now: { now }
        )
        await model.refresh()

        let legacy = AccountProviderID(accountID: .legacy, providerID: .codex)
        let added = try #require(fixture.controller.accounts.first?.accountProviderID)
        #expect(Set(model.snapshot.providers.map(\.accountProviderID)) == [legacy, added])
        #expect(model.accountConnectionStates[legacy] == .available)
        #expect(model.snapshot.providers.first { $0.accountProviderID == legacy }?
            .groups.flatMap(\.meters).first?.percentRemaining == 80)
        #expect(model.snapshot.providers.first { $0.accountProviderID == added }?
            .groups.flatMap(\.meters).first?.percentRemaining == 30)
        #expect(CodexPinRotationURLProtocol.refreshCount == 1)
        #expect(try discovery.snapshotStore.snapshot(for: legacy)?.refreshToken == "rotated-refresh")
        let currentCompanion = source == .file
            ? try String(contentsOf: authURL, encoding: .utf8)
            : try fixture.keychain.value(service: "Codex Auth", account: "")
        #expect(currentCompanion == replacement)
        #expect(try discovery.snapshotStore.snapshot(for: added)?.accessToken == "replacement-access")
    }
}

private struct CodexPinRotationWriter: KeychainWriting {
    let keychain: AdditionFakeKeychain

    func setValue(_ value: String, service: String, account: String) throws {
        try keychain.set(value, service: service, account: account)
    }
}

private final class CodexPinRotationURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var pending: CodexPinRotationURLProtocol?
    private nonisolated(unsafe) static var continuation: AsyncStream<Void>.Continuation?
    private nonisolated(unsafe) static var requests = 0
    private static let rotatedAccess = jwt(
        expiration: Date(timeIntervalSince1970: 1_785_675_000 + 3_600)
    )

    static var refreshCount: Int { lock.withLock { requests } }

    static func reset() -> AsyncStream<Void> {
        let (stream, signal) = AsyncStream.makeStream(of: Void.self)
        lock.withLock {
            pending = nil
            continuation = signal
            requests = 0
        }
        return stream
    }

    static func completeRefresh() {
        let protocolInstance = lock.withLock {
            defer { pending = nil }
            return pending
        }
        protocolInstance?.respond(200, """
            {"access_token":"\(rotatedAccess)","refresh_token":"rotated-refresh","expires_in":3600}
            """)
    }

    static func credential(token: String, account: String) -> String {
        """
        {"auth_mode":"chatgpt","tokens":{"access_token":"\(token)","refresh_token":"\(account)-refresh","account_id":"\(account)"}}
        """
    }

    static func jwt(expiration: Date) -> String {
        let encoded = Data("{\"exp\":\(Int(expiration.timeIntervalSince1970))}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).fixture-signature"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if request.url?.absoluteString == "https://auth.openai.com/oauth/token" {
            let body = requestBodyData(request).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let first = Self.lock.withLock {
                Self.requests += 1
                guard Self.requests == 1, body.contains("refresh_token=original-refresh") else { return false }
                Self.pending = self
                Self.continuation?.yield()
                Self.continuation?.finish()
                return true
            }
            // OAuth rotation consumes the original grant exactly once.
            if !first { respond(401, #"{"error":"refresh_token_reused"}"#) }
            return
        }
        guard request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage" else {
            respond(404, "{}")
            return
        }
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        let account = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
        let used: Int
        if bearer == "Bearer \(Self.rotatedAccess)", account == "original" {
            used = 20
        } else if bearer == "Bearer replacement-access", account == "replacement" {
            used = 70
        } else {
            respond(401, #"{"error":"unauthorized"}"#)
            return
        }
        respond(200, """
            {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":\(used),"limit_window_seconds":18000,"reset_at":1785682200}}}
            """)
    }

    private func respond(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private final class AdditionFixture {
    let suiteName = "ProviderAccountAdditionCoordinatorTests-\(UUID().uuidString)"
    let rootURL: URL
    let homeURL: URL
    let registryURL: URL
    let defaults: UserDefaults
    let store: ProviderAccountStore
    let keychain = AdditionFakeKeychain()
    let nextAccountIDs = [
        AccountID(rawValue: "00000000-0000-0000-0000-0000000000a1")!,
        AccountID(rawValue: "00000000-0000-0000-0000-0000000000a2")!,
        AccountID(rawValue: "00000000-0000-0000-0000-0000000000a3")!,
        AccountID(rawValue: "00000000-0000-0000-0000-0000000000a4")!
    ]

    var capture: [ProviderID: Result<String, CredentialDiscoveryError>] = [:]
    var launchResult: Result<ProviderSetupOutcome, ProviderSetupError> =
        .success(.launched)
    var events: [String] = []
    private(set) var refreshCount = 0
    private var accountIndex = 0
    private var failingPhase: ProviderMutationPhase?
    private var madeController: ProviderAccountRegistryController?

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        homeURL = rootURL.appending(path: "home", directoryHint: .isDirectory)
        registryURL = rootURL.appending(path: "registry/accounts.json")
        defaults = UserDefaults(suiteName: suiteName)!
        store = ProviderAccountStore(
            registryURL: registryURL,
            defaults: defaults,
            legacyAPIKeyPresence: { _ in false }
        )
        _ = try store.loadOrMigrate()
    }

    var controller: ProviderAccountRegistryController {
        if let madeController { return madeController }
        let created = makeController()
        madeController = created
        return created
    }

    func makeCoordinator(
        failingAfter phase: ProviderMutationPhase? = nil
    ) -> ProviderAccountAdditionCoordinator {
        failingPhase = phase
        return ProviderAccountAdditionCoordinator(
            controller: controller,
            captureCredential: { [unowned self] provider in
                self.events.append("capture:\(provider.rawValue)")
                switch self.capture[provider] {
                case .success(let secret):
                    return secret
                case .failure(let error):
                    throw error
                case nil:
                    throw CredentialDiscoveryError.notFound(provider)
                }
            },
            launchCompanion: { [unowned self] provider in
                self.events.append("launch:\(provider.rawValue)")
                return self.launchResult
            },
            onAccountAdded: { [unowned self] in
                self.refreshCount += 1
            }
        )
    }

    private func makeController() -> ProviderAccountRegistryController {
        let phase = failingPhase
        return ProviderAccountRegistryController(
            store: store,
            registry: try! store.loadOrMigrate(),
            keyStore: { [unowned self] provider, accountID in
                self.keyStore(provider, accountID)
            },
            makeAccountID: { [unowned self] in
                defer { self.accountIndex += 1 }
                return self.nextAccountIDs[self.accountIndex]
            },
            credentialSnapshotStore: { [unowned self] in
                ProviderCredentialSnapshotStore(keychain: self.keychain)
            },
            mutationAfterPhase: { reached in
                if reached == phase { throw AdditionMutationFailure() }
            }
        )
    }

    var codexSecretA: String {
        Self.encodedCodexSecret(accessToken: "codex-access-a")
    }

    var codexSecretB: String {
        Self.encodedCodexSecret(accessToken: "codex-access-b")
    }

    var legacyCodexSecret: String? {
        try? keychain.value(
            service: ProviderAPIKeyStore.serviceName,
            account: "codex/\(AccountID.legacy.rawValue)"
        )
    }

    func keyStore(
        _ provider: ProviderID,
        _ accountID: AccountID
    ) -> ProviderAPIKeyStore? {
        ProviderAPIKeyStore.live(
            for: provider,
            accountID: accountID,
            home: homeURL,
            environment: [:],
            keychain: keychain
        )
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func encodedCodexSecret(accessToken: String) -> String {
        let snapshot = CredentialSnapshot(
            provider: .codex,
            accessToken: accessToken,
            refreshToken: "refresh-\(accessToken)",
            accountReference: "account-\(accessToken)",
            planName: "Plus",
            expiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            source: .file
        )
        return (try? snapshot.encodedSecret()) ?? ""
    }
}

private struct AdditionMutationFailure: Error {}

private final class AdditionFakeKeychain: ProviderKeychain, KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failWritesToAccount: String?

    var isEmpty: Bool { lock.withLock { values.isEmpty } }

    func value(service: String, account: String) throws -> String? {
        lock.withLock { values[service + "|" + account] }
    }

    func set(_ value: String, service: String, account: String) throws {
        if account == failWritesToAccount { throw AdditionMutationFailure() }
        lock.withLock { values[service + "|" + account] = value }
    }

    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: service + "|" + account) }
    }
}
