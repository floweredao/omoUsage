import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite("Provider setup truthfulness")
struct ProviderSetupTruthfulnessTests {
    @Test
    func authBindingMatchesAllProviders() throws {
        let apiKeyProviders = ProviderID.allCases.filter {
            ProviderSetup.descriptor(for: $0)?.acceptsAPIKey == true
        }
        let companionProviders = ProviderID.allCases.filter {
            ProviderSetup.descriptor(for: $0)?.acceptsAPIKey == false
        }

        #expect(apiKeyProviders == [.opencode, .openrouter, .zai])
        #expect(
            companionProviders == [
                .claude, .codex, .cursor, .antigravity,
                .copilot, .devin, .grok, .kiro
            ]
        )
        guard
            case .terminalAlternatives(
                let copilotSpecifications,
                let fallbackURL
            ) = try #require(
                ProviderSetup.descriptor(for: .copilot)
            ).action
        else {
            Issue.record("Copilot must use installed companions")
            return
        }
        #expect(
            copilotSpecifications == [
                TerminalLaunchSpecification(
                    executable: "copilot",
                    arguments: ["login"]
                ),
                TerminalLaunchSpecification(
                    executable: "gh",
                    arguments: ["auth", "login"]
                )
            ]
        )
        #expect(fallbackURL == nil)
    }

    @Test
    func copilotPrefersItsCLIThenGitHubCLIAndRequiresBothWhenMissing() throws {
        guard
            case .terminalAlternatives(
                let specifications,
                let fallbackURL
            ) = try #require(
                ProviderSetup.descriptor(for: .copilot)
            ).action
        else {
            Issue.record("Copilot alternatives are missing")
            return
        }
        var commands: [String] = []
        let preferred = ProviderSetup.performTerminalAlternatives(
            specifications,
            fallbackURL: fallbackURL,
            companionProvider: .copilot,
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            isExecutable: {
                $0 == "/usr/local/bin/copilot"
                    || $0 == "/opt/homebrew/bin/gh"
            },
            launchTerminal: {
                commands.append($0)
                return true
            },
            openURL: { _ in true }
        )
        #expect(preferred == .success(.launched))
        #expect(commands == ["'/usr/local/bin/copilot' 'login'"])

        commands.removeAll()
        let github = ProviderSetup.performTerminalAlternatives(
            specifications,
            fallbackURL: fallbackURL,
            companionProvider: .copilot,
            environment: ["PATH": "/opt/homebrew/bin"],
            isExecutable: { $0 == "/opt/homebrew/bin/gh" },
            launchTerminal: {
                commands.append($0)
                return true
            },
            openURL: { _ in true }
        )
        #expect(github == .success(.launched))
        #expect(commands == ["'/opt/homebrew/bin/gh' 'auth' 'login'"])

        let missing = ProviderSetup.performTerminalAlternatives(
            specifications,
            fallbackURL: fallbackURL,
            companionProvider: .copilot,
            environment: ["PATH": ""],
            isExecutable: { _ in false },
            launchTerminal: { _ in true },
            openURL: { _ in true }
        )
        #expect(
            missing == .failure(
                .companionRequired(.copilot, ["copilot", "gh"])
            )
        )
    }

    @Test
    func missingCodexCompanionReturnsTypedRequirementWithoutOpeningHelp() throws {
        guard
            case .terminal(let specification, let fallbackURL) =
                try #require(ProviderSetup.descriptor(for: .codex)).action
        else {
            Issue.record("Codex must use its installed companion")
            return
        }
        var openedURLs: [URL] = []

        let result = ProviderSetup.performTerminal(
            specification,
            fallbackURL: fallbackURL,
            companionProvider: .codex,
            environment: ["PATH": ""],
            homeDirectory: URL(filePath: "/Users/test"),
            isExecutable: { _ in false },
            launchTerminal: { _ in true },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(
            result == .failure(.companionRequired(.codex, ["codex"]))
        )
        #expect(openedURLs.isEmpty)
    }

    @Test
    func missingCursorAppReturnsTypedRequirementWithoutOpeningFallback() throws {
        guard
            case .application(let specification) =
                try #require(ProviderSetup.descriptor(for: .cursor)).action
        else {
            Issue.record("Cursor must use its installed app")
            return
        }
        var openedApplications: [URL] = []
        var openedURLs: [URL] = []

        let result = ProviderSetup.performApplication(
            specification,
            companionProvider: .cursor,
            resolveApplication: { _ in nil },
            openApplication: {
                openedApplications.append($0)
                return true
            },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(
            result == .failure(.companionRequired(.cursor, ["Cursor"]))
        )
        #expect(openedApplications.isEmpty)
        #expect(openedURLs.isEmpty)
    }

    @Test
    func localizedPendingCopyIsExplicit() {
        let korean = AppStrings(language: .korean)
        let english = AppStrings(language: .english)

        #expect(korean.text(.companionRequired) == "컴패니언 필요")
        #expect(
            english.text(.waitingForCompanionCredentials)
                == "Waiting for companion credentials"
        )
    }

    @Test(arguments: [ProviderID.claude, .codex])
    @MainActor
    func companionAdditionActivationNeverCapturesProtectedClaudeCredential(provider: ProviderID) throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "AdditionActivation-\(UUID().uuidString)")
        let suite = "AdditionActivation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let store = ProviderAccountStore(
            registryURL: home.appending(path: "registry.json"),
            defaults: defaults,
            legacyAPIKeyPresence: { _ in false }
        )
        let controller = ProviderAccountRegistryController(
            store: store,
            registry: try store.loadOrMigrate(),
            keyStore: { _, _ in nil },
            credentialSnapshotStore: { nil }
        )
        var captures = 0
        let coordinator = ProviderAccountAdditionCoordinator(
            controller: controller,
            captureCredential: {
                captures += 1
                throw CredentialDiscoveryError.notFound($0)
            },
            launchCompanion: { _ in .success(.launched) },
            onAccountAdded: { Issue.record("Unexpected account addition") }
        )
        #expect(coordinator.addAccount(provider: provider, label: "Work", key: nil) == .waitingForCompanion)
        #expect(captures == 1)
        let outcome = coordinator.applicationDidBecomeActive()
        #expect(outcome == (provider == .claude ? .ignored : .credentialMissing))
        #expect(captures == (provider == .claude ? 1 : 2))
        // Explicit Check Again retains the existing Claude import policy.
        #expect(coordinator.checkAgain() == .credentialMissing)
        #expect(captures == (provider == .claude ? 2 : 3))
        coordinator.cancel()
        #expect(!coordinator.isWaitingForCompanion)
    }

    @Test
    @MainActor
    func browserHelpOutcomeIsNeverAuthenticated() {
        let coordinator = ProviderConnectionCoordinator()
        coordinator.record(
            .success(.openedFallback(URL(string: "https://example.com")!)),
            for: .codex
        )

        // Opening the official page is neither authenticated nor a failure.
        #expect(coordinator.state(for: .codex) == nil)
    }

    @Test
    @MainActor
    func activationReportsResolvedStatesAndReplacesStaleWaitingFeedback() async {
        let cursor = AccountProviderID(accountID: .legacy, providerID: .cursor)
        let grok = AccountProviderID(accountID: .legacy, providerID: .grok)
        let coordinator = ProviderConnectionCoordinator()
        coordinator.record(.success(.launched), for: .cursor)
        coordinator.record(.success(.launched), for: .grok)

        let resolved = await coordinator.applicationDidBecomeActive(
            refresh: {},
            availability: { (identity: AccountProviderID) in
                identity == cursor ? .available : .authenticationRequired
            }
        )

        #expect(resolved == [cursor: .authenticated, grok: .waitingForCredential])
        let waiting = LocalizedText.key(.waitingForCompanionCredentials)
        // Grok still waits, so the waiting text stays.
        #expect(PendingConnectionFeedback.afterActivation(resolved, current: waiting) == waiting)
        #expect(PendingConnectionFeedback.afterActivation([cursor: .authenticated], current: waiting) == nil)
        #expect(
            PendingConnectionFeedback.afterActivation([cursor: .failed], current: waiting)
                == .key(.connectionVerificationFailed)
        )
        let unrelated = LocalizedText.key(.registryResetSucceeded)
        #expect(PendingConnectionFeedback.afterActivation([cursor: .authenticated], current: unrelated) == unrelated)
        #expect(PendingConnectionFeedback.afterActivation([:], current: waiting) == waiting)
    }

    @Test
    @MainActor
    func codexReconnectOpeningOfficialPageIsNotALaunchFailure() {
        let url = URL(string: "https://chatgpt.com/codex")!
        let coordinator = CodexLegacyReconnectCoordinator(
            captureCredential: { throw CredentialDiscoveryError.notFound(.codex) },
            persistLegacySnapshot: { _ in },
            launchCompanion: { .success(.openedFallback(url)) },
            reenable: {}
        )

        let outcome = coordinator.start()

        #expect(outcome == .openedOfficialGuide(url))
        #expect(!coordinator.isWaiting)
        #expect(
            CodexReconnectFeedback.update(for: outcome, userInitiated: true)
                == .show(.formatted(.openedOfficialAuthentication, ProviderID.codex.displayName))
        )
    }

    @Test
    func codexActivationCheckClearsWaitingOnlyWhenReconnected() {
        #expect(CodexReconnectFeedback.update(for: .reconnected, userInitiated: false) == .clear)
        #expect(CodexReconnectFeedback.update(for: .credentialUnchanged, userInitiated: false) == .keep)
        #expect(CodexReconnectFeedback.update(for: .credentialMissing, userInitiated: false) == .keep)
        #expect(
            CodexReconnectFeedback.update(for: .credentialUnavailable, userInitiated: false)
                == .show(.key(.companionCredentialUnavailable))
        )
        #expect(
            CodexReconnectFeedback.update(for: .credentialUnchanged, userInitiated: true)
                == .show(.key(.companionCredentialUnchanged))
        )
    }

    @Test
    func failedTerminalLaunchNamesTheProviderNotItsExecutable() {
        let result = ProviderSetup.performTerminalAlternatives(
            [TerminalLaunchSpecification(executable: "gh", arguments: ["auth", "login"])],
            fallbackURL: nil,
            companionProvider: .copilot,
            environment: ["PATH": "/opt/homebrew/bin"],
            isExecutable: { $0 == "/opt/homebrew/bin/gh" },
            launchTerminal: { _ in false },
            openURL: { _ in true }
        )
        #expect(result == .failure(.unableToLaunch(ProviderID.copilot.displayName)))
    }

    @Test
    @MainActor
    func launchedCompanionIsWaitingAndNeverImmediatelyAuthenticated() {
        let coordinator = ProviderConnectionCoordinator()

        coordinator.record(.success(.launched), for: .claude)

        #expect(coordinator.state(for: .claude) == .waitingForCredential)
    }

    @Test
    @MainActor
    func activationRefreshMapsAvailabilityTruthfullyAndOnlyOnce() async {
        let coordinator = ProviderConnectionCoordinator()
        for provider in [
            ProviderID.claude, .codex, .cursor, .antigravity
        ] {
            coordinator.record(.success(.launched), for: provider)
        }
        let availability: [ProviderID: ProviderAvailability] = [
            .claude: .available,
            .codex: .authenticationRequired,
            .cursor: .unavailable,
            .antigravity: .failed
        ]
        var refreshCount = 0

        await coordinator.applicationDidBecomeActive(
            refresh: { refreshCount += 1 },
            availability: { availability[$0] }
        )

        #expect(refreshCount == 1)
        // A still-valid old credential is not evidence that CLI login ended.
        #expect(coordinator.state(for: .claude) == .waitingForCredential)
        #expect(coordinator.state(for: .codex) == .waitingForCredential)
        #expect(coordinator.state(for: .cursor) == .waitingForCredential)
        #expect(coordinator.state(for: .antigravity) == .failed)
    }

    @Test
    @MainActor
    func waitingCredentialIsCheckedAgainOnNextActivation() async {
        let coordinator = ProviderConnectionCoordinator()
        coordinator.record(.success(.launched), for: .codex)
        var refreshCount = 0
        var availability = ProviderAvailability.authenticationRequired

        await coordinator.applicationDidBecomeActive(
            refresh: { refreshCount += 1 },
            availability: { (_: ProviderID) in availability }
        )
        #expect(coordinator.state(for: .codex) == .waitingForCredential)
        availability = .available
        await coordinator.applicationDidBecomeActive(
            refresh: { refreshCount += 1 },
            availability: { (_: ProviderID) in availability }
        )

        #expect(refreshCount == 2)
        #expect(coordinator.state(for: .codex) == .authenticated)
    }

    @Test
    @MainActor
    func sameProviderAccountsKeepIndependentConnectionState() async {
        let coordinator = ProviderConnectionCoordinator()
        let first = AccountProviderID(
            accountID: AccountID(),
            providerID: .codex
        )
        let second = AccountProviderID(
            accountID: AccountID(),
            providerID: .codex
        )
        coordinator.record(.success(.launched), for: first)
        coordinator.record(.success(.launched), for: second)

        await coordinator.applicationDidBecomeActive(
            refresh: {},
            availability: { accountProvider in
                accountProvider == first
                    ? .available
                    : .authenticationRequired
            }
        )

        #expect(coordinator.state(for: first) == .authenticated)
        #expect(coordinator.state(for: second) == .waitingForCredential)
    }

    @Test
    @MainActor
    func missingCompanionRemainsRequiredAcrossActivation() async {
        let coordinator = ProviderConnectionCoordinator()
        coordinator.record(
            .failure(.companionRequired(.cursor, ["Cursor"])),
            for: .cursor
        )
        var refreshCount = 0

        await coordinator.applicationDidBecomeActive(
            refresh: { refreshCount += 1 },
            availability: { (_: ProviderID) in .available }
        )

        #expect(refreshCount == 0)
        #expect(coordinator.state(for: .cursor) == .companionRequired)
    }

    @Test
    @MainActor
    func codexConnectUsesGuardedLegacySnapshotReplacement() {
        var events: [String] = []
        ProviderConnectionControl.performConnect(
            provider: .codex,
            startConnection: { events.append("start-\($0.rawValue)") },
            startGuardedCodexConnection: {
                events.append("guarded-\($0.rawValue)")
            },
            startBrowserConnection: {
                events.append("browser-\($0.rawValue)")
            }
        )

        #expect(events == ["guarded-codex"])

        events.removeAll()
        ProviderConnectionControl.performConnect(
            provider: .claude,
            startConnection: { events.append("start-\($0.rawValue)") },
            startGuardedCodexConnection: {
                events.append("guarded-\($0.rawValue)")
            },
            startBrowserConnection: {
                events.append("browser-\($0.rawValue)")
            }
        )
        #expect(events == ["browser-claude"])
    }

    @Test
    @MainActor
    func codexReconnectWaitsForChangedCompanionCredential() throws {
        let secretA = try codexSnapshotSecret("a")
        let mutableSecret = secretA
        var events: [String] = []
        let coordinator = CodexLegacyReconnectCoordinator(
            captureCredential: { mutableSecret },
            persistLegacySnapshot: { _ in events.append("persist") },
            launchCompanion: {
                events.append("launch")
                return .success(.launched)
            },
            reenable: { events.append("reenable") }
        )

        #expect(coordinator.start() == .waitingForCredential)
        #expect(coordinator.checkAgain() == .credentialUnchanged)
        #expect(coordinator.isWaiting)
        #expect(events == ["launch"])
    }

    @Test
    @MainActor
    func codexReconnectReplacesOnlyLegacySnapshotAfterCredentialChanges() throws {
        var mutableSecret = try codexSnapshotSecret("a")
        let secretB = try codexSnapshotSecret("b")
        var persisted: [String] = []
        var reenabled = false
        let coordinator = CodexLegacyReconnectCoordinator(
            captureCredential: { mutableSecret },
            persistLegacySnapshot: { persisted.append($0) },
            launchCompanion: { .success(.launched) },
            reenable: { reenabled = true }
        )

        #expect(coordinator.start() == .waitingForCredential)
        mutableSecret = secretB
        #expect(coordinator.checkAgain() == .reconnected)
        #expect(persisted == [secretB])
        #expect(reenabled)
        #expect(!coordinator.isWaiting)
    }

    @Test
    @MainActor
    func codexReconnectPersistenceFailureStaysDisconnected() throws {
        var mutableSecret = try codexSnapshotSecret("a")
        var reenabled = false
        let coordinator = CodexLegacyReconnectCoordinator(
            captureCredential: { mutableSecret },
            persistLegacySnapshot: { _ in throw TruthfulnessPersistenceFailure() },
            launchCompanion: { .success(.launched) },
            reenable: { reenabled = true }
        )

        #expect(coordinator.start() == .waitingForCredential)
        mutableSecret = try codexSnapshotSecret("b")
        #expect(coordinator.checkAgain() == .credentialUnavailable)
        #expect(!reenabled)
        #expect(coordinator.isWaiting)
    }

    @Test
    @MainActor
    func codexReconnectCancelClearsWaitingWithoutReenablingOrPersisting()
        throws
    {
        let secret = try codexSnapshotSecret("a")
        var events: [String] = []
        let coordinator = CodexLegacyReconnectCoordinator(
            captureCredential: { secret },
            persistLegacySnapshot: { _ in events.append("persist") },
            launchCompanion: {
                events.append("launch")
                return .success(.launched)
            },
            reenable: { events.append("reenable") }
        )

        #expect(coordinator.start() == .waitingForCredential)
        #expect(coordinator.isWaiting)

        coordinator.cancel()

        #expect(!coordinator.isWaiting)
        #expect(coordinator.baselineFingerprint == nil)
        #expect(coordinator.checkAgain() == .ignored)
        #expect(events == ["launch"])
    }

    @Test
    func codexConnectionControlsDisableWhileAccountAdditionWaits() {
        #expect(
            !ProviderConnectionMutationPolicy.allows(
                provider: .codex,
                pendingAddition: .codex
            )
        )
        #expect(
            ProviderConnectionMutationPolicy.allows(
                provider: .claude,
                pendingAddition: .codex
            )
        )
    }

    @Test
    func codexGuardedReconnectWaitingOffersCheckAgainAndCancel() {
        #expect(
            ProviderConnectionControl.resolve(
                availability: nil,
                isDisconnected: true,
                isAwaitingCredential: true
            ) == [.checkAgainConnection, .cancelConnection]
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: .authenticationRequired,
                isDisconnected: false,
                isAwaitingCredential: true
            ) == [.checkAgainConnection, .cancelConnection]
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: nil,
                isDisconnected: true,
                isAwaitingCredential: false
            ) == [.reconnect]
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: .available,
                isDisconnected: false
            ) == [.disconnect]
        )
    }

    @Test
    func codexAddAccountIsBlockedWhileGuardedReconnectWaits() {
        #expect(
            ProviderAccountAdditionRowState.resolve(
                provider: .codex,
                pendingAddition: nil,
                guardedReconnectProvider: .codex
            ) == .blockedByOtherAddition
        )
        #expect(
            ProviderAccountAdditionRowState.resolve(
                provider: .claude,
                pendingAddition: nil,
                guardedReconnectProvider: .codex
            ) == .idle
        )
        #expect(
            ProviderAccountAdditionRowState.resolve(
                provider: .openrouter,
                pendingAddition: nil,
                guardedReconnectProvider: .codex
            ) == .idle
        )
        #expect(
            ProviderAccountAdditionRowState.resolve(
                provider: .codex,
                pendingAddition: nil,
                guardedReconnectProvider: nil
            ) == .idle
        )
        #expect(
            ProviderAccountAdditionRowState.resolve(
                provider: .codex,
                pendingAddition: .codex,
                guardedReconnectProvider: nil
            ) == .waiting
        )
        #expect(
            ProviderAccountAdditionRowState.resolve(
                provider: .claude,
                pendingAddition: .codex,
                guardedReconnectProvider: nil
            ) == .blockedByOtherAddition
        )
        #expect(
            ProviderAccountAdditionRowState.resolve(
                provider: .openrouter,
                pendingAddition: .codex,
                guardedReconnectProvider: nil
            ) == .idle
        )
    }

    @Test
    @MainActor
    func claudeReconnectStartsBrowserSignInWithoutReenablingFirst() {
        var events: [String] = []

        ProviderConnectionControl.performReconnect(
            provider: .claude,
            reenable: { events.append("reenable-\($0.rawValue)") },
            startConnection: { events.append("start-\($0.rawValue)") },
            startBrowserConnection: { events.append("browser-\($0.rawValue)") }
        )

        #expect(events == ["browser-claude"])
    }

    @Test
    func openCodeHasAccountQualifiedPrivateKeyStorage() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "OpenCodeAccountKey-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let accountID = AccountID()
        let keychain = TruthfulnessProviderKeychain()
        let store = try #require(
            ProviderAPIKeyStore.live(
                for: .opencode,
                accountID: accountID,
                home: home,
                environment: [:],
                keychain: keychain
            )
        )

        try store.save("account-opencode-key")

        #expect(store.account == "opencode/\(accountID.rawValue)")
        #expect(store.service == ProviderAPIKeyStore.serviceName)
        #expect(!FileManager.default.fileExists(atPath: store.configURL.path))
    }

    @Test
    func openCodeEnvironmentKeyPrecedesSavedKey() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "OpenCodeEnvironmentKey-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let keychain = TruthfulnessProviderKeychain()
        let stored = try #require(
            ProviderAPIKeyStore.live(
                for: .opencode,
                home: home,
                environment: [:],
                keychain: keychain
            )
        )
        try stored.save("saved-opencode-key")
        let resolved = try #require(
            ProviderAPIKeyStore.live(
                for: .opencode,
                home: home,
                environment: ["OPENCODE_API_KEY": "environment-key"],
                keychain: keychain
            )
        )

        #expect(resolved.loadCredential()?.value == "environment-key")
        #expect(resolved.loadCredential()?.source == .environment)
    }

    @Test
    func openCodeStoredKeyPrecedesOfficialCompanionCredential() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "ProviderSetupTruthfulness-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let keychain = TruthfulnessProviderKeychain()
        let store = try #require(
            ProviderAPIKeyStore.live(
                for: .opencode,
                home: home,
                environment: [:],
                keychain: keychain
            )
        )
        try store.save("omo-opencode-key")
        let official = home.appending(
            path: ".local/share/opencode/auth.json"
        )
        try FileManager.default.createDirectory(
            at: official.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: ["opencode-go": ["key": "official-key"]]
        ).write(to: official)
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: "missing-claude.json"),
                codex: home.appending(path: "missing-codex.json")
            ),
            environment: [:],
            keychain: TruthfulnessKeychain(),
            providerKeychain: keychain,
            homeDirectory: home,
            commandPaths: []
        )

        #expect(try discovery.opencode().accessToken == "omo-opencode-key")
    }
}

private func codexSnapshotSecret(_ marker: String) throws -> String {
    try CredentialSnapshot(
        provider: .codex,
        accessToken: "codex-\(marker)",
        refreshToken: "refresh-\(marker)",
        accountReference: "account-\(marker)",
        planName: nil,
        expiresAt: nil,
        source: .file
    ).encodedSecret()
}

private struct TruthfulnessPersistenceFailure: Error {}

private struct TruthfulnessKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? { nil }
}

private final class TruthfulnessProviderKeychain: ProviderKeychain, @unchecked Sendable {
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
