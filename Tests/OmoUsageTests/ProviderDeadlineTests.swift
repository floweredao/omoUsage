import Foundation
import Testing
@testable import OmoUsage

@Suite
struct ProviderDeadlineTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    @MainActor
    func timedOutProviderRetainsStaleUsageWhilePeerPublishes() async throws {
        let deadline = ProviderDeadlineTestGate()
        let provider = ProviderDeadlineScriptedProvider(
            id: .claude,
            first: makeUsage(.claude)
        )
        let peer = ProviderDeadlineMutableProvider(
            id: .codex,
            usage: makeUsage(.codex)
        )
        let viewModel = UsageDashboardViewModel(
            providers: [provider, peer],
            providerDeadline: 30,
            sleep: deadline.sleep,
            now: { now }
        )
        await viewModel.refresh()
        await deadline.waitUntilCompletions(2)

        await peer.setUsage(makeUsage(.codex, plan: "Updated"))
        let refresh = Task { @MainActor in await viewModel.refresh() }
        await provider.waitUntilSecondFetchStarts()
        await deadline.waitUntilSleepStarts()
        deadline.fire()
        await refresh.value

        let claude = try #require(
            viewModel.snapshot.providers.first { $0.provider == .claude }
        )
        let codex = try #require(
            viewModel.snapshot.providers.first { $0.provider == .codex }
        )
        #expect(claude.freshness == .stale)
        #expect(claude.refreshFailure == .network)
        #expect(codex.planName == "Updated")
        #expect(codex.freshness == .current)
        #expect(viewModel.connectionStates[.claude] == .failed)
        #expect(viewModel.connectionStates[.codex] == .available)
        #expect(!viewModel.isRefreshing)
    }

    @Test
    @MainActor
    func cancellationCleansRefreshStateWithoutPublishing() async {
        let deadline = ProviderDeadlineTestGate()
        let provider = ProviderDeadlineAlwaysGatedProvider(id: .claude)
        let initial = now.addingTimeInterval(-1)
        let viewModel = UsageDashboardViewModel(
            providers: [provider],
            providerDeadline: 30,
            sleep: deadline.sleep,
            now: { initial }
        )
        let refresh = Task { @MainActor in await viewModel.refresh() }
        await provider.waitUntilFetchStarts()
        await deadline.waitUntilSleepStarts()

        refresh.cancel()
        await refresh.value

        #expect(!viewModel.isRefreshing)
        #expect(viewModel.snapshot.providers.isEmpty)
        #expect(viewModel.snapshot.refreshedAt == initial)
        #expect(viewModel.connectionStates.isEmpty)
        #expect(await provider.observedCancellation)
    }

    private func makeUsage(
        _ provider: ProviderID,
        plan: String = "Initial"
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            planName: plan,
            groups: [],
            availability: .available,
            updatedAt: now
        )
    }
}

private final class ProviderDeadlineTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepContinuations: [
        UUID: CheckedContinuation<Void, any Error>
    ] = [:]
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionCount = 0
    private var completionWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func sleep(_ duration: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiters = lock.withLock { () -> [
                    CheckedContinuation<Void, Never>
                ] in
                    sleepContinuations[id] = continuation
                    let waiters = sleepWaiters
                    sleepWaiters.removeAll()
                    return waiters
                }
                waiters.forEach { $0.resume() }
                if Task.isCancelled { cancelSleep(id: id) }
            }
        } onCancel: {
            self.cancelSleep(id: id)
        }
    }

    func waitUntilSleepStarts() async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = lock.withLock {
                guard sleepContinuations.isEmpty else { return true }
                sleepWaiters.append(continuation)
                return false
            }
            if alreadyStarted { continuation.resume() }
        }
    }

    func fire() {
        let result: (
            [CheckedContinuation<Void, any Error>],
            [CheckedContinuation<Void, Never>]
        ) = lock.withLock {
            let values = Array(sleepContinuations.values)
            sleepContinuations.removeAll()
            return (values, completed(values.count))
        }
        result.0.forEach { $0.resume() }
        result.1.forEach { $0.resume() }
    }

    func waitUntilCompletions(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let complete = lock.withLock {
                guard completionCount < target else { return true }
                completionWaiters.append((target, continuation))
                return false
            }
            if complete { continuation.resume() }
        }
    }

    private func cancelSleep(id: UUID) {
        let result: (
            CheckedContinuation<Void, any Error>?,
            [CheckedContinuation<Void, Never>]
        ) = lock.withLock {
            guard let value = sleepContinuations.removeValue(forKey: id) else {
                return (nil, [])
            }
            return (value, completed(1))
        }
        result.0?.resume(throwing: CancellationError())
        result.1.forEach { $0.resume() }
    }

    @discardableResult
    private func completed(
        _ count: Int
    ) -> [CheckedContinuation<Void, Never>] {
        completionCount += count
        let ready = completionWaiters.filter { $0.target <= completionCount }
        completionWaiters.removeAll { $0.target <= completionCount }
        return ready.map(\.continuation)
    }
}

private actor ProviderDeadlineScriptedState {
    private var call = 0
    private var secondContinuation: CheckedContinuation<Void, any Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func fetchStarted() async throws {
        call += 1
        guard call == 2 else { return }
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                secondContinuation = continuation
                if Task.isCancelled {
                    secondContinuation = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { await self.cancelSecondFetch() }
        }
    }

    func waitUntilSecondFetchStarts() async {
        guard call < 2 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func cancelSecondFetch() {
        secondContinuation?.resume(throwing: CancellationError())
        secondContinuation = nil
    }
}

private struct ProviderDeadlineScriptedProvider: UsageProvider {
    let id: ProviderID
    let first: ProviderUsage
    private let state = ProviderDeadlineScriptedState()

    func fetch(now: Date) async throws -> ProviderUsage {
        try await state.fetchStarted()
        return first
    }

    func waitUntilSecondFetchStarts() async {
        await state.waitUntilSecondFetchStarts()
    }
}

private actor ProviderDeadlineMutableState {
    var usage: ProviderUsage

    init(usage: ProviderUsage) { self.usage = usage }

    func setUsage(_ usage: ProviderUsage) {
        self.usage = usage
    }
}

private struct ProviderDeadlineMutableProvider: UsageProvider {
    let id: ProviderID
    private let state: ProviderDeadlineMutableState

    init(id: ProviderID, usage: ProviderUsage) {
        self.id = id
        state = ProviderDeadlineMutableState(usage: usage)
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        await state.usage
    }

    func setUsage(_ usage: ProviderUsage) async {
        await state.setUsage(usage)
    }
}

private actor ProviderDeadlineCancellationState {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelled = false

    func wait() async throws {
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { value in
                continuation = value
                if Task.isCancelled {
                    continuation = nil
                    cancelled = true
                    value.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private struct ProviderDeadlineAlwaysGatedProvider: UsageProvider {
    let id: ProviderID
    private let state = ProviderDeadlineCancellationState()

    func fetch(now: Date) async throws -> ProviderUsage {
        try await state.wait()
        throw CancellationError()
    }

    func waitUntilFetchStarts() async { await state.waitUntilStarted() }
    var observedCancellation: Bool { get async { await state.cancelled } }
}
