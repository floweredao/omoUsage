import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct KiroIntegrationTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func registersKiroWithoutChangingExistingProviderOrder() throws {
        let existing = [
            "claude", "codex", "cursor", "antigravity", "copilot",
            "devin", "grok", "opencode", "openrouter", "zai"
        ]
        let kiro = try #require(ProviderID(rawValue: "kiro"))
        #expect(ProviderID.allCases.filter { $0 != kiro }.map(\.rawValue) == existing)
        #expect(ProviderFactory.current(environment: [:]).map(\.id).contains(kiro))
        #expect(ProviderDisplayOrder.repaired([]).contains(kiro))
        #expect(ProviderContractCatalog.contract(for: kiro).endpoints.count == 1)
    }

    @Test
    func setupUsesIntegratedAuthenticationWithoutRequiringCLI() throws {
        let kiro = try #require(ProviderID(rawValue: "kiro"))
        let descriptor = try #require(ProviderSetup.descriptor(for: kiro))
        #expect(!descriptor.acceptsAPIKey)
        #expect(descriptor.action == .browserOAuth)
    }

    @Test
    func kiroFixtureRoundTripsThroughSanitizedCompanionSnapshot() async throws {
        let kiro = try #require(ProviderID(rawValue: "kiro"))
        let provider = try #require(
            ProviderFactory.current(environment: ["OMO_USAGE_FIXTURE_MODE": "1"])
                .first { $0.id == kiro }
        )
        let usage = try await provider.fetch(now: now)
        #expect(usage.provider == kiro)
        #expect(!usage.groups.isEmpty)
        #expect(usage.groups.flatMap(\.meters).contains { $0.percentRemaining != nil })
        let snapshot = DashboardSnapshot(providers: [usage], refreshedAt: now)
        let encoded = try UsageSnapshotCodec.encode(snapshot)
        let decoded = try UsageSnapshotCodec.decode(encoded)
        #expect(decoded.providers.first?.provider == kiro)
        #expect(decoded.providers.first?.groups == usage.groups)
    }
}
