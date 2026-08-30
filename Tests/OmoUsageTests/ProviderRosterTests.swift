import Foundation
import Testing
@testable import OmoUsage

@Suite
struct ProviderRosterTests {
    @Test
    func matchesOpenUsageProviderOrder() {
        #expect(
            ProviderID.allCases == [
                .claude,
                .codex,
                .cursor,
                .antigravity,
                .copilot,
                .devin,
                .grok,
                .opencode,
                .openrouter,
                .zai
            ]
        )
    }

    @Test
    func factoryRegistersEveryProvider() {
        let providers = ProviderFactory.current(environment: [:])
        #expect(providers.map(\.id) == ProviderID.allCases)
    }

    @Test
    func settingsExposeSetupForEveryProvider() {
        #expect(ProviderID.allCases.allSatisfy {
            ProviderSetup.descriptor(for: $0) != nil
        })
        #expect(
            ProviderID.allCases.filter {
                ProviderSetup.descriptor(for: $0)?.acceptsAPIKey == true
            } == [.opencode, .openrouter, .zai]
        )
    }

    @Test
    func savesAndRemovesManualAPIKey() throws {
        try withFixtureDirectory { directory in
            let url = directory.appending(path: "provider.json")
            let store = ProviderAPIKeyStore(
                configURL: url,
                environment: [:],
                environmentNames: []
            )

            try store.save("fixture-secret")
            #expect(store.load() == "fixture-secret")
            #expect(!FileManager.default.fileExists(atPath: url.path))
            try store.remove()
            #expect(store.load() == nil)
        }
    }

    @Test
    func appIconResourceExists() {
        #expect(
            Bundle.module.url(
                forResource: "AppIcon",
                withExtension: "svg"
            ) != nil
        )
    }

    private func withFixtureDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageRosterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

@Suite
struct InteractiveControlTests {
    @Test
    func hoverAndPressHaveDistinctFeedback() {
        #expect(
            InteractiveControlVisualState(
                isHovered: true,
                isPressed: false,
                reduceMotion: false
            ).backgroundOpacity == 0.12
        )
        #expect(
            InteractiveControlVisualState(
                isHovered: true,
                isPressed: true,
                reduceMotion: false
            ).backgroundOpacity == 0.2
        )
        #expect(
            InteractiveControlVisualState(
                isHovered: true,
                isPressed: true,
                reduceMotion: true
            ).scale == 1
        )
    }
}
