import Testing
@testable import OmoUsage

@Suite("Provider connection controls")
struct ProviderConnectionControlTests {
    @Test
    func failedProviderOffersRetryThenDisconnect() {
        let controls = resolvedControls(
            ProviderConnectionControl.resolve(
                availability: .failed,
                isDisconnected: false
            )
        )

        #expect(controls == [.retry, .disconnect])
    }

    @Test
    func selectsConnectDisconnectAndReconnectStates() {
        #expect(
            resolvedControls(
                ProviderConnectionControl.resolve(
                    availability: .authenticationRequired,
                    isDisconnected: false
                )
            ) == [.connect]
        )
        #expect(
            resolvedControls(
                ProviderConnectionControl.resolve(
                    availability: .available,
                    isDisconnected: false
                )
            ) == [.disconnect]
        )
        #expect(
            resolvedControls(
                ProviderConnectionControl.resolve(
                    availability: .failed,
                    isDisconnected: false
                )
            ) == [.retry, .disconnect]
        )
        #expect(
            resolvedControls(
                ProviderConnectionControl.resolve(
                    availability: .authenticationRequired,
                    isDisconnected: true
                )
            ) == [.reconnect]
        )
    }
}

private func resolvedControls(
    _ control: ProviderConnectionControl
) -> [ProviderConnectionControl] {
    [control]
}

private func resolvedControls(
    _ controls: [ProviderConnectionControl]
) -> [ProviderConnectionControl] {
    controls
}
