import Foundation
import Observation

struct UsageDashboardControlState: Equatable, Sendable {
    let providerOrder: [ProviderID]
    let disconnectedProviders: Set<ProviderID>
    let isRefreshing: Bool
}

@Observable
@MainActor
final class UsageDashboardViewModel {
    @ObservationIgnored
    private let providers: [any UsageProvider]
    @ObservationIgnored
    private let now: @Sendable () -> Date
    @ObservationIgnored
    private let persistProviderOrder: ([ProviderID]) -> Void
    @ObservationIgnored
    private let persistDisconnectedProviders: (Set<ProviderID>) -> Void
    @ObservationIgnored
    private let publishSnapshot: @MainActor (DashboardSnapshot) -> Void
    @ObservationIgnored
    private let publishControlState:
        @MainActor (UsageDashboardControlState) -> Void

    private(set) var snapshot: DashboardSnapshot
    private(set) var isRefreshing = false
    @ObservationIgnored
    private var refreshAfterCurrent = false
    private(set) var providerOrder: [ProviderID]
    private(set) var disconnectedProviders: Set<ProviderID>
    private(set) var connectionStates: [
        ProviderID: ProviderAvailability
    ] = [:]

    init(
        providers: [any UsageProvider],
        providerOrder: [ProviderID] = ProviderID.allCases,
        persistProviderOrder: @escaping ([ProviderID]) -> Void = { _ in },
        disconnectedProviders: Set<ProviderID> = [],
        persistDisconnectedProviders: @escaping (
            Set<ProviderID>
        ) -> Void = { _ in },
        publishSnapshot: @escaping @MainActor (
            DashboardSnapshot
        ) -> Void = { _ in },
        publishControlState: @escaping @MainActor (
            UsageDashboardControlState
        ) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.providers = providers
        self.providerOrder = ProviderDisplayOrder.repaired(
            providerOrder
        )
        self.persistProviderOrder = persistProviderOrder
        self.disconnectedProviders = disconnectedProviders
        self.persistDisconnectedProviders = persistDisconnectedProviders
        self.publishSnapshot = publishSnapshot
        self.publishControlState = publishControlState
        self.now = now
        snapshot = DashboardSnapshot(providers: [], refreshedAt: now())
        connectionStates = Dictionary(
            uniqueKeysWithValues: disconnectedProviders.map {
                ($0, .authenticationRequired)
            }
        )
        publishCurrentControlState()
    }

    func setProviderOrder(_ order: [ProviderID]) {
        let repaired = ProviderDisplayOrder.repaired(order)
        guard repaired != providerOrder else { return }
        providerOrder = repaired
        persistProviderOrder(providerOrder)
        setSnapshot(.ordered(
            providers: snapshot.providers,
            refreshedAt: snapshot.refreshedAt,
            providerOrder: providerOrder
        ))
        publishCurrentControlState()
    }

    func moveProvider(
        _ provider: ProviderID,
        by offset: Int
    ) {
        guard
            let source = providerOrder.firstIndex(of: provider)
        else {
            return
        }
        let destination = source + offset
        guard providerOrder.indices.contains(destination) else {
            return
        }
        providerOrder.swapAt(source, destination)
        persistProviderOrder(providerOrder)
        setSnapshot(.ordered(
            providers: snapshot.providers,
            refreshedAt: snapshot.refreshedAt,
            providerOrder: providerOrder
        ))
        publishCurrentControlState()
    }

    func isDisconnected(_ provider: ProviderID) -> Bool {
        disconnectedProviders.contains(provider)
    }

    func disconnectProvider(_ provider: ProviderID) {
        guard disconnectedProviders.insert(provider).inserted else {
            return
        }
        persistDisconnectedProviders(disconnectedProviders)
        connectionStates[provider] = .authenticationRequired
        setSnapshot(.ordered(
            providers: snapshot.providers.filter {
                $0.provider != provider
            },
            refreshedAt: snapshot.refreshedAt,
            providerOrder: providerOrder
        ))
        publishCurrentControlState()
    }

    func reconnectProvider(_ provider: ProviderID) {
        guard disconnectedProviders.remove(provider) != nil else {
            return
        }
        persistDisconnectedProviders(disconnectedProviders)
        connectionStates[provider] = .authenticationRequired
        if isRefreshing {
            refreshAfterCurrent = true
        }
        publishCurrentControlState()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        publishCurrentControlState()
        defer {
            isRefreshing = false
            publishCurrentControlState()
        }

        repeat {
            refreshAfterCurrent = false
            let fetchNow = now()
            let results = await withTaskGroup(
                of: ProviderFetchResult.self,
                returning: [ProviderFetchResult].self
            ) { group in
                for provider in providers
                where !disconnectedProviders.contains(provider.id) {
                    group.addTask {
                        do {
                            let usage = try await provider.fetch(now: fetchNow)
                            return ProviderFetchResult(
                                id: provider.id,
                                usage: usage.availability == .available
                                    ? usage
                                    : nil,
                                availability: usage.availability
                            )
                        } catch is CancellationError {
                            return ProviderFetchResult(
                                id: provider.id,
                                usage: nil,
                                availability: .failed,
                                wasCancelled: true
                            )
                        } catch {
                            return ProviderFetchResult(
                                id: provider.id,
                                usage: nil,
                                availability: Self.availability(for: error),
                                retainsPreviousUsage:
                                    Self.retainsPreviousUsage(for: error)
                            )
                        }
                    }
                }

                var values: [ProviderFetchResult] = []
                for await result in group {
                    values.append(result)
                }
                return values
            }
            guard
                !Task.isCancelled,
                !results.contains(where: \.wasCancelled)
            else {
                return
            }

            let byProvider = Dictionary(
                uniqueKeysWithValues: results.map { ($0.id, $0) }
            )
            connectionStates = Dictionary(
                uniqueKeysWithValues: ProviderID.allCases.map { provider in
                    (
                        provider,
                        disconnectedProviders.contains(provider)
                            ? .authenticationRequired
                            : byProvider[provider]?.availability ?? .unavailable
                    )
                }
            )
            let previous = Dictionary(
                uniqueKeysWithValues: snapshot.providers.map {
                    ($0.provider, $0)
                }
            )
            let usages: [ProviderUsage] = ProviderID.allCases.compactMap {
                provider -> ProviderUsage? in
                guard !disconnectedProviders.contains(provider) else {
                    return nil
                }
                guard let result = byProvider[provider] else {
                    return nil
                }
                if let usage = result.usage {
                    return usage
                }
                if
                    result.availability == .failed
                        || result.retainsPreviousUsage
                {
                    return previous[provider]
                }
                return nil
            }
            setSnapshot(.ordered(
                providers: usages,
                refreshedAt: now(),
                providerOrder: providerOrder
            ))
        } while refreshAfterCurrent && !Task.isCancelled
    }

    private func setSnapshot(_ snapshot: DashboardSnapshot) {
        self.snapshot = snapshot
        publishSnapshot(snapshot)
    }

    private func publishCurrentControlState() {
        publishControlState(
            UsageDashboardControlState(
                providerOrder: providerOrder,
                disconnectedProviders: disconnectedProviders,
                isRefreshing: isRefreshing
            )
        )
    }

    nonisolated
    private static func availability(
        for error: any Error
    ) -> ProviderAvailability {
        if let error = error as? CredentialDiscoveryError {
            switch error {
            case .notFound:
                return .authenticationRequired
            case .malformed, .expired:
                return .authenticationRequired
            }
        }
        if case ProviderTransportError.authenticationRequired = error {
            return .authenticationRequired
        }
        return .failed
    }

    nonisolated
    private static func retainsPreviousUsage(
        for error: any Error
    ) -> Bool {
        guard let error = error as? CredentialDiscoveryError else {
            if case ProviderTransportError.authenticationRequired = error {
                return false
            }
            return true
        }
        switch error {
        case .notFound:
            return false
        case .malformed, .expired:
            return true
        }
    }
}

private struct ProviderFetchResult: Sendable {
    let id: ProviderID
    let usage: ProviderUsage?
    let availability: ProviderAvailability
    var wasCancelled = false
    var retainsPreviousUsage = false
}
