import Foundation
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

    @Test
    @MainActor
    func reconnectStartsConnectionBeforeRefreshing() async {
        var events: [String] = []

        let refresh = ProviderConnectionControl.performReconnect(
            provider: .claude,
            reenable: {
                events.append("reenable-\($0.rawValue)")
            },
            startConnection: {
                events.append("start-\($0.rawValue)")
            },
            refresh: {
                events.append("refresh")
            }
        )
        await refresh.value

        #expect(
            events
                == [
                    "reenable-claude",
                    "start-claude",
                    "refresh"
                ]
        )
    }

    @Test
    @MainActor
    func reconnectUsesOfficialFallbackWhenClaudeCLIIsMissing() async {
        let fallbackURL = URL(string: "https://claude.ai/code")!
        var launchedCommands: [String] = []
        var openedURLs: [URL] = []

        let refresh = ProviderConnectionControl.performReconnect(
            provider: .claude,
            reenable: { _ in },
            startConnection: { provider in
                #expect(provider == .claude)
                let result = ProviderSetup.performTerminal(
                    TerminalLaunchSpecification(
                        executable: "claude",
                        arguments: ["auth", "login"]
                    ),
                    fallbackURL: fallbackURL,
                    environment: ["PATH": ""],
                    isExecutable: { _ in false },
                    launchTerminal: {
                        launchedCommands.append($0)
                        return true
                    },
                    openURL: {
                        openedURLs.append($0)
                        return true
                    }
                )
                #expect(
                    result == .success(.openedFallback(fallbackURL))
                )
            },
            refresh: {}
        )
        await refresh.value

        #expect(launchedCommands.isEmpty)
        #expect(openedURLs == [fallbackURL])
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
