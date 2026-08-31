import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct MultiAccountRefreshTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)
    private let accountA = AccountID(
        rawValue: "00000000-0000-0000-0000-00000000000a"
    )!
    private let accountB = AccountID(
        rawValue: "00000000-0000-0000-0000-00000000000b"
    )!

    @Test
    @MainActor
    func sameProviderAccountsFetchConcurrentlyAndPublishTwoRows() async {
        let barrier = MultiAccountFetchBarrier(participantCount: 2)
        let providerA = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Account A",
            responses: [.success(makeUsage(planName: "A1"))],
            firstFetchBarrier: barrier
        )
        let providerB = MultiAccountScriptedProvider(
            accountID: accountB,
            accountLabel: "Account B",
            responses: [.success(makeUsage(planName: "B1"))],
            firstFetchBarrier: barrier
        )
        let viewModel = UsageDashboardViewModel(
            providers: [providerA, providerB],
            now: { now }
        )

        await viewModel.refresh()

        #expect(await barrier.arrivalCount == 2)
        #expect(viewModel.snapshot.providers.map(\.accountProviderID) == [
            AccountProviderID(accountID: accountA, providerID: .codex),
            AccountProviderID(accountID: accountB, providerID: .codex)
        ])
        #expect(viewModel.snapshot.providers.map(\.accountLabel) == [
            "Account A", "Account B"
        ])
    }

    @Test
    @MainActor
    func duplicateProviderIdentityFetchesOnlyFirstConfiguredProvider() async {
        let first = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Account A",
            responses: [.success(makeUsage(planName: "First"))]
        )
        let duplicate = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Duplicate",
            responses: [.success(makeUsage(planName: "Second"))]
        )
        let viewModel = UsageDashboardViewModel(
            providers: [first, duplicate],
            now: { now }
        )

        await viewModel.refresh()

        #expect(viewModel.snapshot.providers.map(\.planName) == ["First"])
        #expect(await first.observedFetchCount() == 1)
        #expect(await duplicate.observedFetchCount() == 0)
    }

    @Test
    @MainActor
    func accountRegistryOverridesStaleLegacyDisconnectAfterRosterGrows() {
        let providerA = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Account A",
            responses: []
        )
        let providerB = MultiAccountScriptedProvider(
            accountID: accountB,
            accountLabel: "Account B",
            responses: []
        )
        let identityA = AccountProviderID(
            accountID: accountA,
            providerID: .codex
        )
        let identityB = AccountProviderID(
            accountID: accountB,
            providerID: .codex
        )

        let viewModel = UsageDashboardViewModel(
            providers: [providerA, providerB],
            disconnectedProviders: [.codex],
            disconnectedAccountProviders: [identityA],
            now: { now }
        )

        #expect(viewModel.isDisconnected(identityA))
        #expect(!viewModel.isDisconnected(identityB))
        #expect(viewModel.disconnectedAccountProviders == [identityA])
        #expect(!viewModel.disconnectedProviders.contains(.codex))
    }

    @Test
    @MainActor
    func transientFailureRetainsOnlyThatAccountsLastGoodUsage() async {
        let providerA = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Account A",
            responses: [
                .success(makeUsage(planName: "A1")),
                .failure(URLError(.notConnectedToInternet))
            ]
        )
        let providerB = MultiAccountScriptedProvider(
            accountID: accountB,
            accountLabel: "Account B",
            responses: [
                .success(makeUsage(planName: "B1")),
                .success(makeUsage(planName: "B2"))
            ]
        )
        let viewModel = UsageDashboardViewModel(
            providers: [providerA, providerB],
            now: { now }
        )

        await viewModel.refresh()
        await viewModel.refresh()

        #expect(plansByAccount(in: viewModel) == [
            accountA: "A1",
            accountB: "B2"
        ])
    }

    @Test
    @MainActor
    func authenticationFailureRemovesOnlyThatAccount() async {
        let providerA = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Account A",
            responses: [
                .success(makeUsage(planName: "A1")),
                .failure(
                    ProviderTransportError.authenticationRequired(.codex)
                )
            ]
        )
        let providerB = MultiAccountScriptedProvider(
            accountID: accountB,
            accountLabel: "Account B",
            responses: [
                .success(makeUsage(planName: "B1")),
                .success(makeUsage(planName: "B2"))
            ]
        )
        let viewModel = UsageDashboardViewModel(
            providers: [providerA, providerB],
            now: { now }
        )

        await viewModel.refresh()
        await viewModel.refresh()

        #expect(plansByAccount(in: viewModel) == [accountB: "B2"])
        #expect(
            viewModel.accountConnectionStates[
                AccountProviderID(accountID: accountA, providerID: .codex)
            ] == .authenticationRequired
        )
        #expect(
            viewModel.accountConnectionStates[
                AccountProviderID(accountID: accountB, providerID: .codex)
            ] == .available
        )
    }

    @Test
    @MainActor
    func accountConnectionIntentAffectsOnlyItsCompositeIdentity() async {
        let providerA = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Account A",
            responses: [.success(makeUsage(planName: "A1"))]
        )
        let providerB = MultiAccountScriptedProvider(
            accountID: accountB,
            accountLabel: "Account B",
            responses: [.success(makeUsage(planName: "B1"))]
        )
        let viewModel = UsageDashboardViewModel(
            providers: [providerA, providerB],
            now: { now }
        )
        let identityA = AccountProviderID(
            accountID: accountA,
            providerID: .codex
        )
        let identityB = AccountProviderID(
            accountID: accountB,
            providerID: .codex
        )
        await viewModel.refresh()

        viewModel.disconnectAccountProvider(identityA)

        #expect(viewModel.isDisconnected(identityA))
        #expect(!viewModel.isDisconnected(identityB))
        #expect(viewModel.snapshot.providers.map(\.accountProviderID) == [
            identityB
        ])
        #expect(viewModel.disconnectedProviders.isEmpty)

        viewModel.reconnectAccountProvider(identityA)

        #expect(!viewModel.isDisconnected(identityA))
        #expect(!viewModel.isDisconnected(identityB))
    }

    @Test
    @MainActor
    func accountConnectionIntentPersistsCompositeState() {
        let identityA = AccountProviderID(
            accountID: accountA,
            providerID: .codex
        )
        var persisted: [Set<AccountProviderID>] = []
        let viewModel = UsageDashboardViewModel(
            providers: [],
            persistDisconnectedAccountProviders: {
                persisted.append($0)
            },
            now: { now }
        )

        viewModel.disconnectAccountProvider(identityA)
        #expect(persisted == [[identityA]])

        viewModel.reconnectAccountProvider(identityA)
        #expect(persisted == [[identityA], []])
    }

    @Test
    @MainActor
    func providerConnectionIntentPersistsCompositeBatchOnce() {
        let providerA = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Account A",
            responses: []
        )
        let providerB = MultiAccountScriptedProvider(
            accountID: accountB,
            accountLabel: "Account B",
            responses: []
        )
        let identityA = AccountProviderID(
            accountID: accountA,
            providerID: .codex
        )
        let identityB = AccountProviderID(
            accountID: accountB,
            providerID: .codex
        )
        var persisted: [Set<AccountProviderID>] = []
        let viewModel = UsageDashboardViewModel(
            providers: [providerA, providerB],
            persistDisconnectedAccountProviders: {
                persisted.append($0)
            },
            now: { now }
        )

        viewModel.disconnectProvider(.codex)
        #expect(persisted == [[identityA, identityB]])

        viewModel.reconnectProvider(.codex)
        #expect(persisted == [[identityA, identityB], []])
    }

    @Test
    @MainActor
    func updateProvidersPreservesSiblingLastGoodAndPrunesRemovedState() async {
        let providerA = MultiAccountScriptedProvider(
            accountID: accountA,
            accountLabel: "Account A",
            responses: [.success(makeUsage(planName: "A1"))]
        )
        let providerB = MultiAccountScriptedProvider(
            accountID: accountB,
            accountLabel: "Account B",
            responses: [.success(makeUsage(planName: "B1"))]
        )
        let replacement = MultiAccountScriptedProvider(
            accountID: accountB,
            accountLabel: "Account B",
            responses: []
        )
        let identityA = AccountProviderID(accountID: accountA, providerID: .codex)
        let identityB = AccountProviderID(accountID: accountB, providerID: .codex)
        let viewModel = UsageDashboardViewModel(
            providers: [providerA, providerB],
            accountProviderOrder: [identityA, identityB],
            now: { now }
        )
        await viewModel.refresh()

        viewModel.updateProviders(
            [replacement],
            accountProviderOrder: [identityB, identityA],
            disconnected: []
        )

        #expect(viewModel.accountProviderOrder == [identityB])
        #expect(viewModel.snapshot.providers.map(\.accountProviderID) == [identityB])
        #expect(viewModel.snapshot.providers.first?.planName == "B1")
        #expect(viewModel.accountConnectionStates[identityA] == nil)
        #expect(viewModel.accountConnectionStates[identityB] == .available)
    }

    @Test
    func claudeRefreshCooldownIsIndependentPerAccount() async {
        let cooldown = ClaudeRefreshCooldown(interval: 600)

        await cooldown.recordFailure(for: accountA, at: now)

        #expect(!(await cooldown.allowsAttempt(for: accountA, at: now)))
        #expect(await cooldown.allowsAttempt(for: accountB, at: now))

        await cooldown.recordSuccess(for: accountB)
        #expect(!(await cooldown.allowsAttempt(for: accountA, at: now)))

        await cooldown.recordSuccess(for: accountA)
        #expect(await cooldown.allowsAttempt(for: accountA, at: now))
    }

    private func makeUsage(planName: String) -> ProviderUsage {
        ProviderUsage(
            provider: .codex,
            planName: planName,
            groups: [],
            availability: .available,
            updatedAt: now
        )
    }

    @MainActor
    private func plansByAccount(
        in viewModel: UsageDashboardViewModel
    ) -> [AccountID: String] {
        Dictionary(
            uniqueKeysWithValues: viewModel.snapshot.providers.map {
                ($0.accountID, $0.planName)
            }
        )
    }
}

private actor MultiAccountFetchBarrier {
    private let participantCount: Int
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivalCount = 0

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func arriveAndWait() async {
        arrivalCount += 1
        guard arrivalCount < participantCount else {
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private actor MultiAccountScriptedProvider: UsageProvider {
    nonisolated let id = ProviderID.codex
    nonisolated let accountID: AccountID
    nonisolated let accountLabel: String

    private var responses: [Result<ProviderUsage, any Error>]
    private let firstFetchBarrier: MultiAccountFetchBarrier?
    private var fetchCount = 0

    init(
        accountID: AccountID,
        accountLabel: String,
        responses: [Result<ProviderUsage, any Error>],
        firstFetchBarrier: MultiAccountFetchBarrier? = nil
    ) {
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.responses = responses
        self.firstFetchBarrier = firstFetchBarrier
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        fetchCount += 1
        if fetchCount == 1 {
            await firstFetchBarrier?.arriveAndWait()
        }
        return try responses.removeFirst().get()
    }

    func observedFetchCount() -> Int {
        fetchCount
    }
}
