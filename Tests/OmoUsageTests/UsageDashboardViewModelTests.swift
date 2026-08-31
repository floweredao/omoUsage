import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct UsageDashboardViewModelTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    @MainActor
    func ordersProvidersAndHidesUnavailableSections() async {
        let viewModel = UsageDashboardViewModel(
            providers: [
                StubUsageProvider(
                    id: .antigravity,
                    result: .success(makeUsage(.antigravity))
                ),
                StubUsageProvider(
                    id: .claude,
                    result: .failure(CredentialDiscoveryError.notFound(.claude))
                ),
                StubUsageProvider(
                    id: .codex,
                    result: .success(makeUsage(.codex))
                )
            ],
            now: { now }
        )

        await viewModel.refresh()

        #expect(
            viewModel.snapshot.providers.map(\.provider)
                == [.codex, .antigravity]
        )
        #expect(
            viewModel.connectionStates[.claude]
                == .authenticationRequired
        )
        #expect(viewModel.connectionStates[.codex] == .available)
        #expect(viewModel.connectionStates[.antigravity] == .available)
        #expect(viewModel.snapshot.refreshedAt == now)
    }

    @Test
    @MainActor
    func credentialCorruptionRequestsAuthenticationInsteadOfRetry() async {
        let viewModel = UsageDashboardViewModel(
            providers: [
                StubUsageProvider(
                    id: .grok,
                    result: .failure(
                        CredentialDiscoveryError.expired(.grok)
                    )
                ),
                StubUsageProvider(
                    id: .opencode,
                    result: .failure(
                        CredentialDiscoveryError.malformed(.opencode)
                    )
                )
            ],
            now: { now }
        )

        await viewModel.refresh()

        #expect(
            viewModel.connectionStates[.grok]
                == .authenticationRequired
        )
        #expect(
            viewModel.connectionStates[.opencode]
                == .authenticationRequired
        )
    }

    @Test
    @MainActor
    func coalescesOverlappingRefreshes() async {
        let (events, signal) = AsyncStream<Void>.makeStream()
        var iterator = events.makeAsyncIterator()
        let gate = ProviderGate()
        let viewModel = UsageDashboardViewModel(
            providers: [
                GatedUsageProvider(
                    id: .claude,
                    usage: makeUsage(.claude),
                    gate: gate,
                    signal: signal
                )
            ],
            now: { now }
        )

        let first = Task { await viewModel.refresh() }
        _ = await iterator.next()

        await viewModel.refresh()

        await gate.open()
        await first.value
        #expect(await gate.callCount == 1)
        #expect(viewModel.isRefreshing == false)
    }

    @Test
    @MainActor
    func reconnectDuringRefreshQueuesAnotherPass() async {
        let (events, signal) = AsyncStream<Void>.makeStream()
        var iterator = events.makeAsyncIterator()
        let gate = ProviderGate()
        let counter = ProviderFetchCounter()
        let viewModel = UsageDashboardViewModel(
            providers: [
                GatedUsageProvider(
                    id: .claude,
                    usage: makeUsage(.claude),
                    gate: gate,
                    signal: signal
                ),
                CountingUsageProvider(
                    id: .codex,
                    usage: makeUsage(.codex),
                    counter: counter
                )
            ],
            disconnectedProviders: [.codex],
            now: { now }
        )

        let refresh = Task { await viewModel.refresh() }
        _ = await iterator.next()

        viewModel.reconnectProvider(.codex)
        await gate.open()
        await refresh.value

        #expect(await counter.count(for: .codex) == 1)
        #expect(viewModel.snapshot.providers.map(\.provider) == [.claude, .codex])
    }

    @Test
    @MainActor
    func publishesControlStateForLocalMutations() {
        var published: [UsageDashboardControlState] = []
        let viewModel = UsageDashboardViewModel(
            providers: [],
            providerOrder: ProviderID.allCases,
            persistProviderOrder: { _ in },
            disconnectedProviders: [.copilot],
            persistDisconnectedProviders: { _ in },
            publishControlState: { published.append($0) },
            now: { now }
        )

        var movedOrder = ProviderID.allCases
        movedOrder.swapAt(0, 1)
        viewModel.setProviderOrder(movedOrder)
        viewModel.disconnectProvider(.codex)
        viewModel.reconnectProvider(.copilot)

        #expect(
            published == [
                UsageDashboardControlState(
                    providerOrder: ProviderID.allCases,
                    disconnectedProviders: [.copilot],
                    isRefreshing: false
                ),
                UsageDashboardControlState(
                    providerOrder: movedOrder,
                    disconnectedProviders: [.copilot],
                    isRefreshing: false
                ),
                UsageDashboardControlState(
                    providerOrder: movedOrder,
                    disconnectedProviders: [.copilot, .codex],
                    isRefreshing: false
                ),
                UsageDashboardControlState(
                    providerOrder: movedOrder,
                    disconnectedProviders: [.codex],
                    isRefreshing: false
                )
            ]
        )
    }

    @Test
    @MainActor
    func publishesRefreshingControlState() async {
        let (events, signal) = AsyncStream<Void>.makeStream()
        var iterator = events.makeAsyncIterator()
        let gate = ProviderGate()
        var published: [UsageDashboardControlState] = []
        let viewModel = UsageDashboardViewModel(
            providers: [
                GatedUsageProvider(
                    id: .claude,
                    usage: makeUsage(.claude),
                    gate: gate,
                    signal: signal
                )
            ],
            publishControlState: { published.append($0) },
            now: { now }
        )

        let first = Task { await viewModel.refresh() }
        _ = await iterator.next()

        await viewModel.refresh()
        #expect(published.map(\.isRefreshing) == [false, true])

        await gate.open()
        await first.value

        #expect(published.map(\.isRefreshing) == [false, true, false])
        #expect(await gate.callCount == 1)
    }

    @Test
    @MainActor
    func timestampsSnapshotWhenRefreshCompletes() async {
        let initializedAt = now.addingTimeInterval(-10)
        let startedAt = now.addingTimeInterval(-5)
        let completedAt = now
        let clock = SequentialClock(
            [initializedAt, startedAt, completedAt]
        )
        let viewModel = UsageDashboardViewModel(
            providers: [
                StubUsageProvider(
                    id: .codex,
                    result: .success(makeUsage(.codex))
                )
            ],
            now: clock.now
        )

        await viewModel.refresh()

        #expect(viewModel.snapshot.refreshedAt == completedAt)
    }

    @Test
    @MainActor
    func publishesTheCompletedSnapshotForCompanionDevices() async {
        var published: [DashboardSnapshot] = []
        let viewModel = UsageDashboardViewModel(
            providers: [
                StubUsageProvider(
                    id: .codex,
                    result: .success(makeUsage(.codex))
                )
            ],
            publishSnapshot: { published.append($0) },
            now: { now }
        )

        await viewModel.refresh()

        #expect(published == [viewModel.snapshot])
    }

    @Test
    @MainActor
    func usesPersistedProviderDisplayOrderAndRepairsMissingProviders() async {
        let order = ProviderDisplayOrder.repaired(
            rawValues: ["codex", "unknown-provider"]
        )
        var persisted: [[ProviderID]] = []
        let viewModel = UsageDashboardViewModel(
            providers: [
                StubUsageProvider(
                    id: .claude,
                    result: .success(makeUsage(.claude))
                ),
                StubUsageProvider(
                    id: .codex,
                    result: .success(makeUsage(.codex))
                ),
                StubUsageProvider(
                    id: .cursor,
                    result: .success(makeUsage(.cursor))
                )
            ],
            providerOrder: order,
            persistProviderOrder: { persisted.append($0) },
            now: { now }
        )

        await viewModel.refresh()

        #expect(
            order
                == [
                    .codex,
                    .claude,
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
        #expect(
            viewModel.snapshot.providers.map(\.provider)
                == [.codex, .claude, .cursor]
        )
        let refreshedAt = viewModel.snapshot.refreshedAt

        viewModel.moveProvider(.claude, by: 1)

        #expect(
            viewModel.snapshot.providers.map(\.provider)
                == [.codex, .cursor, .claude]
        )
        #expect(viewModel.snapshot.refreshedAt == refreshedAt)
        #expect(persisted == [viewModel.providerOrder])
    }

    @Test
    @MainActor
    func cancelledRefreshDoesNotPublishFailureOrTimestamp() async {
        let gate = ProviderGate()
        let (events, signal) = AsyncStream<Void>.makeStream()
        let initial = Date(timeIntervalSince1970: 1_000)
        let clock = SequentialClock([
            initial,
            initial.addingTimeInterval(1),
            initial.addingTimeInterval(2)
        ])
        let provider = GatedUsageProvider(
            id: .codex,
            usage: makeUsage(.codex),
            gate: gate,
            signal: signal
        )
        let viewModel = UsageDashboardViewModel(
            providers: [provider],
            now: clock.now
        )
        let refresh = Task { await viewModel.refresh() }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()

        refresh.cancel()
        await gate.open()
        await refresh.value

        #expect(viewModel.snapshot.providers.isEmpty)
        #expect(viewModel.snapshot.refreshedAt == initial)
        #expect(viewModel.connectionStates.isEmpty)
        #expect(!viewModel.isRefreshing)
        signal.finish()
    }

    @Test
    @MainActor
    func disconnectSkipsProviderAndReconnectRestoresIt() async {
        let counter = ProviderFetchCounter()
        var persisted: Set<ProviderID> = []
        let viewModel = UsageDashboardViewModel(
            providers: [
                CountingUsageProvider(
                    id: .claude,
                    usage: makeUsage(.claude),
                    counter: counter
                ),
                CountingUsageProvider(
                    id: .codex,
                    usage: makeUsage(.codex),
                    counter: counter
                )
            ],
            disconnectedProviders: [.claude],
            persistDisconnectedProviders: { persisted = $0 },
            now: { self.now }
        )

        await viewModel.refresh()

        #expect(await counter.count(for: .claude) == 0)
        #expect(await counter.count(for: .codex) == 1)
        #expect(viewModel.snapshot.providers.map(\.provider) == [.codex])
        #expect(
            viewModel.connectionStates[.claude]
                == .authenticationRequired
        )

        viewModel.reconnectProvider(.claude)
        #expect(persisted.isEmpty)
        await viewModel.refresh()

        #expect(await counter.count(for: .claude) == 1)
        #expect(viewModel.snapshot.providers.map(\.provider) == [
            .claude,
            .codex
        ])

        viewModel.disconnectProvider(.claude)
        #expect(persisted == [.claude])
        #expect(viewModel.snapshot.providers.map(\.provider) == [.codex])
    }

    private func makeUsage(_ provider: ProviderID) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            planName: "Test",
            groups: [],
            availability: .available,
            updatedAt: now
        )
    }
}

private final class SequentialClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]

    init(_ values: [Date]) {
        self.values = values
    }

    func now() -> Date {
        lock.withLock {
            values.removeFirst()
        }
    }
}

private struct StubUsageProvider: UsageProvider {
    let id: ProviderID
    let result: Result<ProviderUsage, any Error>

    func fetch(now: Date) async throws -> ProviderUsage {
        try result.get()
    }
}

private actor ProviderFetchCounter {
    private var counts: [ProviderID: Int] = [:]

    func record(_ provider: ProviderID) {
        counts[provider, default: 0] += 1
    }

    func count(for provider: ProviderID) -> Int {
        counts[provider, default: 0]
    }
}

private struct CountingUsageProvider: UsageProvider {
    let id: ProviderID
    let usage: ProviderUsage
    let counter: ProviderFetchCounter

    func fetch(now: Date) async throws -> ProviderUsage {
        await counter.record(id)
        return usage
    }
}

private struct GatedUsageProvider: UsageProvider {
    let id: ProviderID
    let usage: ProviderUsage
    let gate: ProviderGate
    let signal: AsyncStream<Void>.Continuation

    func fetch(now: Date) async throws -> ProviderUsage {
        signal.yield()
        await gate.wait()
        try Task.checkCancellation()
        return usage
    }
}

private actor ProviderGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var callCount = 0

    func wait() async {
        callCount += 1
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}
