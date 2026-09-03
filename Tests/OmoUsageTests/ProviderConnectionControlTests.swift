import Foundation
import Testing
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
    func claudeRetryReauthorizesBeforeRefreshing() {
        var events: [String] = []

        ProviderConnectionControl.performRetry(
            provider: .claude,
            reauthorizeClaude: {
                events.append("authorize-\($0.rawValue)")
            },
            refresh: {
                events.append("refresh-\($0.rawValue)")
            }
        )

        #expect(events == ["authorize-claude"])
    }

    @Test
    @MainActor
    func nonClaudeRetryUsesDirectRefresh() {
        var events: [String] = []

        ProviderConnectionControl.performRetry(
            provider: .codex,
            reauthorizeClaude: {
                events.append("authorize-\($0.rawValue)")
            },
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
