import Foundation
import Testing
@testable import OmoUsage

@Suite("Provider setup truthfulness")
struct ProviderSetupTruthfulnessTests {
    @Test
    func authBindingMatchesAllTenProviders() throws {
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
                .copilot, .devin, .grok
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

    @Test
    @MainActor
    func browserHelpOutcomeIsNeverAuthenticated() {
        let coordinator = ProviderConnectionCoordinator()
        coordinator.record(
            .success(.openedFallback(URL(string: "https://example.com")!)),
            for: .codex
        )

        #expect(coordinator.state(for: .codex) == .failed)
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
        #expect(coordinator.state(for: .claude) == .authenticated)
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
    func reconnectDoesNotRefreshBeforeApplicationActivation() {
        var events: [String] = []

        ProviderConnectionControl.performReconnect(
            provider: .claude,
            reenable: { events.append("reenable-\($0.rawValue)") },
            startConnection: { events.append("start-\($0.rawValue)") }
        )

        #expect(events == ["reenable-claude", "start-claude"])
    }

    @Test
    func openCodeHasAccountQualifiedPrivateKeyStorage() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "OpenCodeAccountKey-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let accountID = AccountID()
        let store = try #require(
            ProviderAPIKeyStore.live(
                for: .opencode,
                accountID: accountID,
                home: home,
                environment: [:]
            )
        )

        try store.save("account-opencode-key")

        #expect(
            store.configURL.path.contains(
                "/accounts/\(accountID.rawValue)/opencode.json"
            )
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: store.configURL.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: store.configURL.deletingLastPathComponent().path
        )
        #expect(fileAttributes[.posixPermissions] as? Int == 0o600)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
    }

    @Test
    func openCodeEnvironmentKeyPrecedesSavedKey() throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "OpenCodeEnvironmentKey-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let stored = try #require(
            ProviderAPIKeyStore.live(
                for: .opencode,
                home: home,
                environment: [:]
            )
        )
        try stored.save("saved-opencode-key")
        let resolved = try #require(
            ProviderAPIKeyStore.live(
                for: .opencode,
                home: home,
                environment: ["OPENCODE_API_KEY": "environment-key"]
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
        let store = try #require(
            ProviderAPIKeyStore.live(
                for: .opencode,
                home: home,
                environment: [:]
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
            homeDirectory: home,
            commandPaths: []
        )

        #expect(try discovery.opencode().accessToken == "omo-opencode-key")
    }
}

private struct TruthfulnessKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? { nil }
}
