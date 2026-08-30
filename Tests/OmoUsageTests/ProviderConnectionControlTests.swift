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
    func reconnectReenablesAndStartsWithoutRefreshing() {
        var events: [String] = []

        ProviderConnectionControl.performReconnect(
            provider: .claude,
            reenable: {
                events.append("reenable-\($0.rawValue)")
            },
            startConnection: {
                events.append("start-\($0.rawValue)")
            }
        )

        #expect(events == ["reenable-claude", "start-claude"])
    }
}
