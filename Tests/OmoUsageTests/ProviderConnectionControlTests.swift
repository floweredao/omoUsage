import Foundation
import Testing
import OmoUsageCore
@testable import OmoUsage

@Suite("Provider connection controls")
struct ProviderConnectionControlTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func officialClaudeLoginUsesAnAppOwnedConfigurationDirectory() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeLoginIsolation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appending(path: ".local/bin/claude")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let output = home.appending(path: "config-directory")
        try """
        #!/bin/sh
        printf '%s' "$CLAUDE_CONFIG_DIR" > '\(output.path)'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )
        let completion = AsyncStream<Bool>.makeStream()
        let receipt = try OfficialLoginReceipt {
            completion.continuation.yield($0)
        }
        defer { receipt.cancel() }
        let result = ProviderSetup.performClaudeLogin(
            receipt: receipt,
            environment: ["PATH": home.path],
            homeDirectory: home,
            launchTerminal: { command in
                let process = Process()
                process.executableURL = URL(filePath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.environment = ["PATH": "/usr/bin:/bin"]
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                } catch {
                    return false
                }
            }
        )
        try #require(result == .success(.launched))
        for await succeeded in completion.stream {
            #expect(succeeded)
            break
        }
        #expect(
            try String(contentsOf: output, encoding: .utf8)
                == home.appending(path: "Library/Application Support/OmoUsage/Claude").path
        )
    }

    @Test
    func failedProviderOffersRetryThenDisconnect() {
        #expect(
            ProviderConnectionControl.resolve(
                availability: .failed,
                isDisconnected: false
            ) == [.retry, .disconnect]
        )
    }

    @Test
    func selectsConnectDisconnectAndReconnectStates() {
        #expect(
            ProviderConnectionControl.resolve(
                availability: .authenticationRequired,
                isDisconnected: false
            ) == [.connect]
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: .available,
                isDisconnected: false
            ) == [.disconnect]
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: .failed,
                isDisconnected: false
            ) == [.retry, .disconnect]
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: .authenticationRequired,
                isDisconnected: true
            ) == [.reconnect]
        )
    }

    @Test
    @MainActor
    func claudeRetryRefreshesWithoutReauthorizing() {
        var events: [String] = []

        ProviderConnectionControl.performRetry(
            provider: .claude,
            refresh: {
                events.append("refresh-\($0.rawValue)")
            }
        )

        #expect(events == ["refresh-claude"])
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func officialClaudeLoginCompletesWithoutActivationAndAuthorizesOnce() async throws {
        let coordinator = ProviderConnectionCoordinator()
        let completion = AsyncStream<Void>.makeStream()
        var receipt: OfficialLoginReceipt?
        var authorizations = 0
        var refreshes = 0
        var availability = ProviderAvailability.authenticationRequired
        let result = coordinator.startClaudeLogin(
            launch: {
                receipt = $0
                return .success(.launched)
            },
            authorize: {
                authorizations += 1
                return .authorized(service: CredentialDiscovery.claudeKeychainService)
            },
            refresh: {
                refreshes += 1
                availability = .available
            },
            availability: { availability },
            didComplete: { completion.continuation.yield(()) }
        )
        #expect(result == .success(.launched))
        await coordinator.applicationDidBecomeActive(
            refresh: { refreshes += 1 },
            availability: { (_: ProviderID) in .available }
        )
        #expect(coordinator.state(for: .claude) == .waitingForCredential)
        #expect(authorizations == 0)
        #expect(refreshes == 0)

        let observed = try #require(receipt)
        try runConnectionReceipt(observed, command: "/usr/bin/true")
        for await _ in completion.stream { break }
        #expect(coordinator.state(for: .claude) == .authenticated)
        #expect(authorizations == 1)
        #expect(refreshes == 1)
        #expect(!FileManager.default.fileExists(atPath: observed.url.path))
        await coordinator.applicationDidBecomeActive(
            refresh: { refreshes += 1 },
            availability: { (_: ProviderID) in .available }
        )
        #expect(authorizations == 1)
        #expect(refreshes == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["/usr/bin/false", "kill -TERM $$", "/usr/bin/true"])
    @MainActor
    func failedLoginOrDeclinedAuthorizationNeverRefreshes(command: String) async throws {
        let coordinator = ProviderConnectionCoordinator()
        let completion = AsyncStream<Void>.makeStream()
        var receipt: OfficialLoginReceipt?
        var authorizations = 0
        var refreshes = 0
        _ = coordinator.startClaudeLogin(
            launch: { receipt = $0; return .success(.launched) },
            authorize: { authorizations += 1; return .cancelled },
            refresh: { refreshes += 1 },
            availability: { .available },
            didComplete: { completion.continuation.yield(()) }
        )
        let observed = try #require(receipt)
        try runConnectionReceipt(observed, command: command)
        for await _ in completion.stream { break }
        #expect(authorizations == (command == "/usr/bin/true" ? 1 : 0))
        #expect(refreshes == 0)
        #expect(coordinator.state(for: .claude) == .failed)
        #expect(!FileManager.default.fileExists(atPath: observed.url.deletingLastPathComponent().path))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor
    func missingOrUnpersistableAuthorizationFailsClosed(persistenceFails: Bool) async throws {
        let coordinator = ProviderConnectionCoordinator()
        let completion = AsyncStream<Void>.makeStream()
        var receipt: OfficialLoginReceipt?
        _ = coordinator.startClaudeLogin(
            launch: { receipt = $0; return .success(.launched) },
            authorize: {
                if persistenceFails { throw ConnectionAuthorizationFailure() }
                return .notFound
            },
            refresh: { Issue.record("Unauthorized refresh") },
            availability: { .available },
            didComplete: { completion.continuation.yield(()) }
        )
        try runConnectionReceipt(try #require(receipt), command: "/usr/bin/true")
        for await _ in completion.stream { break }
        #expect(coordinator.state(for: .claude) == .failed)
    }

    @Test
    @MainActor
    func launchFailureAndCoordinatorTeardownCleanReceipts() throws {
        var coordinator: ProviderConnectionCoordinator? = ProviderConnectionCoordinator()
        var urls: [URL] = []
        let launchFailure = ProviderSetupError.companionRequired(.claude, ["claude"])
        let result = coordinator?.startClaudeLogin(
            launch: { urls.append($0.url); return .failure(launchFailure) },
            authorize: { Issue.record("Authorization after launch failure"); return .cancelled },
            refresh: { Issue.record("Refresh after launch failure") },
            availability: { .available }
        )
        #expect(result == .failure(launchFailure))
        #expect(coordinator?.state(for: .claude) == .companionRequired)
        #expect(!FileManager.default.fileExists(atPath: urls[0].deletingLastPathComponent().path))
        _ = coordinator?.startClaudeLogin(
            launch: { urls.append($0.url); return .success(.launched) },
            authorize: { Issue.record("Authorization after teardown"); return .cancelled },
            refresh: { Issue.record("Refresh after teardown") },
            availability: { .available }
        )
        weak var released = coordinator
        coordinator = nil
        #expect(released == nil)
        #expect(!FileManager.default.fileExists(atPath: urls[1].deletingLastPathComponent().path))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func queuedCompletionFromReplacedAttemptCannotAuthorize() async throws {
        let coordinator = ProviderConnectionCoordinator()
        let completion = AsyncStream<Void>.makeStream()
        var receipts: [OfficialLoginReceipt] = []
        var authorizations: [Int] = []
        for attempt in 0..<2 {
            _ = coordinator.startClaudeLogin(
                launch: { receipts.append($0); return .success(.launched) },
                authorize: {
                    authorizations.append(attempt)
                    return .authorized(service: CredentialDiscovery.claudeKeychainService)
                },
                refresh: {},
                availability: { .available },
                didComplete: { completion.continuation.yield(()) }
            )
            // Queue a real filesystem event without yielding the main actor,
            // then replace the attempt before its callback can execute.
            try Data("success\n".utf8).write(to: receipts[attempt].url)
        }
        for await _ in completion.stream { break }
        #expect(authorizations == [1])
        #expect(coordinator.state(for: .claude) == .authenticated)
        #expect(receipts.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.url.path)
        })
    }

    @Test
    @MainActor
    func replacingOrCancellingClaudeLoginRemovesOldReceipt() throws {
        let coordinator = ProviderConnectionCoordinator()
        var receipts: [OfficialLoginReceipt] = []
        for _ in 0..<2 {
            _ = coordinator.startClaudeLogin(
                launch: { receipts.append($0); return .success(.launched) },
                authorize: { Issue.record("Premature authorization"); return .cancelled },
                refresh: { Issue.record("Premature refresh") },
                availability: { .available }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: receipts[0].url.path))
        #expect(FileManager.default.fileExists(atPath: receipts[1].url.path))
        coordinator.cancelClaudeLogin()
        #expect(!FileManager.default.fileExists(atPath: receipts[1].url.path))
        #expect(coordinator.state(for: .claude) == nil)
    }

    @Test
    @MainActor
    func nonClaudeRetryUsesDirectRefresh() {
        var events: [String] = []

        ProviderConnectionControl.performRetry(
            provider: .codex,
            refresh: {
                events.append("refresh-\($0.rawValue)")
            }
        )

        #expect(events == ["refresh-codex"])
    }

    @Test
    @MainActor
    func explicitClaudeReconnectLaunchesOfficialLogin() {
        var events: [String] = []

        ProviderConnectionControl.performReconnect(
            provider: .claude,
            reenable: {
                events.append("reenable-\($0.rawValue)")
            },
            startConnection: {
                events.append("start-\($0.rawValue)")
            },
            launchOfficialLogin: {
                events.append("login-\($0.rawValue)")
            }
        )

        #expect(events == ["reenable-claude", "login-claude"])
    }
}

@MainActor
private func runConnectionReceipt(_ receipt: OfficialLoginReceipt, command: String) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = ["-c", receipt.wrapping(command)]
    try process.run()
    process.waitUntilExit()
}

private struct ConnectionAuthorizationFailure: Error {}
