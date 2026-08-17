import Testing
@testable import OmoUsage

@Suite("Provider connection controls")
struct ProviderConnectionControlTests {
    @Test
    func selectsConnectDisconnectAndReconnectStates() {
        #expect(
            ProviderConnectionControl.resolve(
                availability: .authenticationRequired,
                isDisconnected: false
            ) == .connect
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: .available,
                isDisconnected: false
            ) == .disconnect
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: .failed,
                isDisconnected: false
            ) == .retry
        )
        #expect(
            ProviderConnectionControl.resolve(
                availability: .authenticationRequired,
                isDisconnected: true
            ) == .reconnect
        )
    }
}
