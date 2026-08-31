import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct LastGoodUsageReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    @MainActor
    func keepsLastGoodUsageAfterServiceUnavailable() async {
        await expectLastGoodUsageIsRetained(after: .serviceUnavailable)
    }

    @Test
    @MainActor
    func keepsLastGoodUsageAfterNetworkFailure() async {
        await expectLastGoodUsageIsRetained(after: .network)
    }

    @Test
    @MainActor
    func keepsLastGoodUsageAfterTransientInvalidResponse() async {
        await expectLastGoodUsageIsRetained(after: .invalidResponse)
    }

    @Test
    @MainActor
    func authenticationFailureRemovesPriorUsage() async {
        await expectPriorUsageIsRemoved(after: .authenticationRequired)
    }

    @Test
    @MainActor
    func missingCredentialRemovesPriorUsage() async {
        await expectPriorUsageIsRemoved(after: .credentialNotFound)
    }

    @Test
    @MainActor
    func malformedCredentialRetainsUsageAndRequestsAuthentication() async {
        await expectLastGoodUsageIsRetained(
            after: .credentialMalformed,
            availability: .authenticationRequired
        )
    }

    @Test
    @MainActor
    func expiredCredentialRetainsPriorUsageAndRequestsAuthentication() async {
        await expectLastGoodUsageIsRetained(
            after: .credentialExpired,
            availability: .authenticationRequired
        )
    }

    @MainActor
    private func expectLastGoodUsageIsRetained(
        after failure: StatefulProviderFailure,
        availability: ProviderAvailability = .failed
    ) async {
        let usage = makeUsage()
        let provider = GatedStatefulUsageProvider(
            id: .codex,
            usage: usage,
            failure: failure
        )
        let viewModel = UsageDashboardViewModel(
            providers: [provider],
            now: { now }
        )

        let refreshed = usage.recordingRefreshAttempt(at: now)
        await refresh(viewModel, using: provider, call: 1)
        #expect(viewModel.snapshot.providers == [refreshed])
        #expect(viewModel.connectionStates[.codex] == .available)

        let refresh = Task { @MainActor in
            await viewModel.refresh()
        }
        await provider.waitUntilFetchStarts(call: 2)
        #expect(viewModel.snapshot.providers == [refreshed])
        await provider.release(call: 2)
        await refresh.value

        let retained = viewModel.snapshot.providers.first
        #expect(viewModel.snapshot.providers.count == 1)
        #expect(retained?.groups == usage.groups)
        #expect(retained?.planName == usage.planName)
        #expect(retained?.availability == usage.availability)
        #expect(retained?.lastSuccessfulAt == usage.lastSuccessfulAt)
        #expect(retained?.freshness == .stale)
        #expect(viewModel.connectionStates[.codex] == availability)
    }

    @MainActor
    private func expectPriorUsageIsRemoved(
        after failure: StatefulProviderFailure
    ) async {
        let usage = makeUsage()
        let provider = GatedStatefulUsageProvider(
            id: .codex,
            usage: usage,
            failure: failure
        )
        let viewModel = UsageDashboardViewModel(
            providers: [provider],
            now: { now }
        )

        await refresh(viewModel, using: provider, call: 1)
        #expect(
            viewModel.snapshot.providers
                == [usage.recordingRefreshAttempt(at: now)]
        )

        await refresh(viewModel, using: provider, call: 2)

        #expect(viewModel.snapshot.providers.isEmpty)
        #expect(
            viewModel.connectionStates[.codex]
                == .authenticationRequired
        )
    }

    @MainActor
    private func refresh(
        _ viewModel: UsageDashboardViewModel,
        using provider: GatedStatefulUsageProvider,
        call: Int
    ) async {
        let refresh = Task { @MainActor in
            await viewModel.refresh()
        }
        await provider.waitUntilFetchStarts(call: call)
        await provider.release(call: call)
        await refresh.value
    }

    private func makeUsage() -> ProviderUsage {
        ProviderUsage(
            provider: .codex,
            planName: "Test",
            groups: [
                UsageGroup(
                    id: "codex.usage",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "codex.week",
                            title: "Weekly",
                            period: .week,
                            percentRemaining: 73
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }
}

private enum StatefulProviderFailure: Sendable {
    case serviceUnavailable
    case network
    case invalidResponse
    case authenticationRequired
    case credentialNotFound
    case credentialMalformed
    case credentialExpired

    func throwError(for provider: ProviderID) throws {
        switch self {
        case .serviceUnavailable:
            throw ProviderTransportError.requestFailed(provider, 503)
        case .network:
            throw URLError(.notConnectedToInternet)
        case .invalidResponse:
            throw ProviderTransportError.invalidResponse(provider)
        case .authenticationRequired:
            throw ProviderTransportError.authenticationRequired(provider)
        case .credentialNotFound:
            throw CredentialDiscoveryError.notFound(provider)
        case .credentialMalformed:
            throw CredentialDiscoveryError.malformed(provider)
        case .credentialExpired:
            throw CredentialDiscoveryError.expired(provider)
        }
    }
}

private actor GatedStatefulUsageProvider: UsageProvider {
    nonisolated let id: ProviderID

    private let usage: ProviderUsage
    private let failure: StatefulProviderFailure
    private var fetchCount = 0
    private var startedCalls: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedCalls: Set<Int> = []
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(
        id: ProviderID,
        usage: ProviderUsage,
        failure: StatefulProviderFailure
    ) {
        self.id = id
        self.usage = usage
        self.failure = failure
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        fetchCount += 1
        let call = fetchCount
        startedCalls.insert(call)
        startWaiters.removeValue(forKey: call)?.forEach { $0.resume() }

        if releasedCalls.remove(call) == nil {
            await withCheckedContinuation { continuation in
                releaseWaiters[call] = continuation
            }
        }

        if call == 1 {
            return usage
        }
        try failure.throwError(for: id)
        throw CancellationError()
    }

    func waitUntilFetchStarts(call: Int) async {
        guard !startedCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[call, default: []].append(continuation)
        }
    }

    func release(call: Int) {
        if let waiter = releaseWaiters.removeValue(forKey: call) {
            waiter.resume()
        } else {
            releasedCalls.insert(call)
        }
    }
}
