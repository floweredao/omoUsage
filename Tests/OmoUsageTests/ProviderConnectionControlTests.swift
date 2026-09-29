import Foundation
import Testing
import OmoUsageCore
@testable import OmoUsage

@Suite("Provider connection controls")
struct ProviderConnectionControlTests {
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
    func claudeConnectAndReconnectUseBrowserSignInWithoutTerminal() {
        var events: [String] = []
        ProviderConnectionControl.performConnect(
            provider: .claude,
            startConnection: { events.append("terminal-\($0.rawValue)") },
            startGuardedCodexConnection: { events.append("guarded-\($0.rawValue)") },
            startBrowserConnection: { events.append("browser-\($0.rawValue)") }
        )
        // Claude is re-enabled only after the browser sign-in succeeds.
        ProviderConnectionControl.performReconnect(
            provider: .claude,
            reenable: { events.append("reenable-\($0.rawValue)") },
            startConnection: { events.append("terminal-\($0.rawValue)") },
            startBrowserConnection: { events.append("browser-\($0.rawValue)") }
        )

        #expect(events == ["browser-claude", "browser-claude"])
    }

    @Test
    @MainActor
    func nonClaudeReconnectReenablesThenStartsItsOwnConnection() {
        var events: [String] = []

        ProviderConnectionControl.performReconnect(
            provider: .grok,
            reenable: { events.append("reenable-\($0.rawValue)") },
            startConnection: { events.append("start-\($0.rawValue)") },
            startBrowserConnection: { events.append("browser-\($0.rawValue)") }
        )

        #expect(events == ["reenable-grok", "start-grok"])
    }

    @Test(arguments: [ProviderID.claude, .kiro, .devin])
    @MainActor
    func browserSignInProvidersConnectAndReconnectThroughBrowserOnly(
        _ provider: ProviderID
    ) {
        var events: [String] = []
        ProviderConnectionControl.performConnect(
            provider: provider,
            startConnection: { events.append("start-\($0.rawValue)") },
            startGuardedCodexConnection: { events.append("guarded-\($0.rawValue)") },
            startBrowserConnection: { events.append("browser-\($0.rawValue)") }
        )
        // No re-enable before the sign-in succeeds.
        ProviderConnectionControl.performReconnect(
            provider: provider,
            reenable: { events.append("reenable-\($0.rawValue)") },
            startConnection: { events.append("start-\($0.rawValue)") },
            startBrowserConnection: { events.append("browser-\($0.rawValue)") }
        )

        #expect(events == ["browser-\(provider.rawValue)", "browser-\(provider.rawValue)"])
    }

    @Test
    @MainActor
    func disconnectCancelsWaitingReconnectBeforeDisconnecting() {
        var events: [String] = []
        ProviderConnectionControl.performDisconnect(
            provider: .codex,
            isAwaitingReconnect: true,
            cancelReconnect: { events.append("cancel") },
            disconnect: { events.append("disconnect-\($0.rawValue)") }
        )
        #expect(events == ["cancel", "disconnect-codex"])

        events.removeAll()
        ProviderConnectionControl.performDisconnect(
            provider: .codex,
            isAwaitingReconnect: false,
            cancelReconnect: { events.append("cancel") },
            disconnect: { events.append("disconnect-\($0.rawValue)") }
        )
        #expect(events == ["disconnect-codex"])
    }

    @Test
    @MainActor
    func retryIgnoresTapsWhileItsRetryIsInFlight() {
        var events: [String] = []
        ProviderConnectionControl.performRetry(
            provider: .cursor,
            isInFlight: true,
            refresh: { events.append("refresh-\($0.rawValue)") }
        )
        #expect(events.isEmpty)
    }
}

