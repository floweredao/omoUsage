import Foundation
import Observation

struct UsageDashboardControlState: Equatable, Sendable {
    let providerOrder: [ProviderID]
    let disconnectedProviders: Set<ProviderID>
    let accountProviderOrder: [AccountProviderID]
    let accountProviderLabels: [AccountProviderID: String]
    let disconnectedAccountProviders: Set<AccountProviderID>
    let isRefreshing: Bool

    init(
        providerOrder: [ProviderID],
        disconnectedProviders: Set<ProviderID>,
        accountProviderOrder: [AccountProviderID]? = nil,
        accountProviderLabels: [AccountProviderID: String]? = nil,
        disconnectedAccountProviders: Set<AccountProviderID>? = nil,
        isRefreshing: Bool
    ) {
        self.providerOrder = providerOrder
        self.disconnectedProviders = disconnectedProviders
        let requestedAccountProviderOrder = accountProviderOrder
            ?? providerOrder.map {
                AccountProviderID(accountID: .legacy, providerID: $0)
            }
        self.accountProviderOrder = AccountProviderDisplayOrder.repaired(
            requestedAccountProviderOrder,
            configured: requestedAccountProviderOrder
        )
        self.accountProviderLabels = Dictionary(
            uniqueKeysWithValues: self.accountProviderOrder.map { identity in
                (
                    identity,
                    AccountLabel.sanitized(accountProviderLabels?[identity])
                )
            }
        )
        self.disconnectedAccountProviders = disconnectedAccountProviders
            ?? Set(disconnectedProviders.map {
                AccountProviderID(accountID: .legacy, providerID: $0)
            })
        self.isRefreshing = isRefreshing
    }
}

struct AccountProviderOrderingItem: Identifiable, Equatable, Sendable {
    var id: AccountProviderID { accountProviderID }
    let accountProviderID: AccountProviderID
    let provider: ProviderID
    let accountLabel: String
    let showsAccountLabel: Bool
    let availability: ProviderAvailability?
    let isDisconnected: Bool
}

@Observable
@MainActor
final class UsageDashboardViewModel {
    @ObservationIgnored
    private var providers: [any UsageProvider]
    @ObservationIgnored
    private let now: @Sendable () -> Date
    @ObservationIgnored
    private let providerDeadline: TimeInterval
    @ObservationIgnored
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored
    private let persistProviderOrder: ([ProviderID]) -> Void
    @ObservationIgnored
    private let persistAccountProviderOrder: ([AccountProviderID]) -> Void
    @ObservationIgnored
    private var defaultAccountProviderOrder: [AccountProviderID]
    @ObservationIgnored
    private let persistDisconnectedProviders: (Set<ProviderID>) -> Void
    @ObservationIgnored
    private let persistDisconnectedAccountProviders:
        (Set<AccountProviderID>) -> Void
    @ObservationIgnored
    private let publishSnapshot: @MainActor (DashboardSnapshot) -> Void
    @ObservationIgnored
    private let publishControlState:
        @MainActor (UsageDashboardControlState) -> Void
    @ObservationIgnored
    private let diagnosticStore: DiagnosticStore

    private(set) var snapshot: DashboardSnapshot
    private(set) var isRefreshing = false
    @ObservationIgnored
    private var refreshAfterCurrent = false
    @ObservationIgnored
    private var providerRosterVersion = 0
    private(set) var providerOrder: [ProviderID]
    private(set) var accountProviderOrder: [AccountProviderID]
    private(set) var disconnectedAccountProviders: Set<AccountProviderID>
    private(set) var accountConnectionStates: [
        AccountProviderID: ProviderAvailability
    ] = [:]
    private(set) var connectionStates: [
        ProviderID: ProviderAvailability
    ] = [:]

    var disconnectedProviders: Set<ProviderID> {
        Set(ProviderID.allCases.filter { providerID in
            let identities = providers
                .filter { $0.id == providerID }
                .map(\.accountProviderID)
            if identities.isEmpty {
                return disconnectedAccountProviders.contains(
                    AccountProviderID(
                        accountID: .legacy,
                        providerID: providerID
                    )
                )
            }
            return identities.allSatisfy(
                disconnectedAccountProviders.contains
            )
        })
    }

    init(
        providers: [any UsageProvider],
        providerOrder: [ProviderID] = ProviderID.allCases,
        persistProviderOrder: @escaping ([ProviderID]) -> Void = { _ in },
        accountProviderOrder: [AccountProviderID]? = nil,
        persistAccountProviderOrder: @escaping (
            [AccountProviderID]
        ) -> Void = { _ in },
        disconnectedProviders: Set<ProviderID> = [],
        disconnectedAccountProviders: Set<AccountProviderID>? = nil,
        persistDisconnectedProviders: @escaping (
            Set<ProviderID>
        ) -> Void = { _ in },
        persistDisconnectedAccountProviders: @escaping (
            Set<AccountProviderID>
        ) -> Void = { _ in },
        publishSnapshot: @escaping @MainActor (
            DashboardSnapshot
        ) -> Void = { _ in },
        publishControlState: @escaping @MainActor (
            UsageDashboardControlState
        ) -> Void = { _ in },
        diagnosticStore: DiagnosticStore = .shared,
        providerDeadline: TimeInterval = 30,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let uniqueProviders = Self.uniqueProviders(providers)
        self.providers = uniqueProviders
        let configured = uniqueProviders.isEmpty
            ? ProviderID.allCases.map {
                AccountProviderID(accountID: .legacy, providerID: $0)
            }
            : uniqueProviders.map(\.accountProviderID)
        let defaultAccountOrder = AccountProviderDisplayOrder.defaultOrder(
            configured: configured
        )
        self.defaultAccountProviderOrder = defaultAccountOrder
        let legacyOrder = ProviderDisplayOrder.repaired(providerOrder)
        let projectedInitial = legacyOrder.flatMap { providerID in
            defaultAccountOrder.filter { $0.providerID == providerID }
        }
        let repairedAccountOrder = AccountProviderDisplayOrder.repaired(
            accountProviderOrder ?? projectedInitial,
            configured: defaultAccountOrder
        )
        self.accountProviderOrder = repairedAccountOrder
        self.providerOrder = ProviderDisplayOrder.repaired(
            repairedAccountOrder.map(\.providerID)
        )
        self.persistProviderOrder = persistProviderOrder
        self.persistAccountProviderOrder = persistAccountProviderOrder
        if let disconnectedAccountProviders {
            self.disconnectedAccountProviders =
                disconnectedAccountProviders
        } else {
            self.disconnectedAccountProviders = Set(
                disconnectedProviders.flatMap { providerID in
                    let identities = uniqueProviders
                        .filter { $0.id == providerID }
                        .map(\.accountProviderID)
                    return identities.isEmpty
                        ? [AccountProviderID(
                            accountID: .legacy,
                            providerID: providerID
                        )]
                        : identities
                }
            )
        }
        self.persistDisconnectedProviders = persistDisconnectedProviders
        self.persistDisconnectedAccountProviders =
            persistDisconnectedAccountProviders
        self.publishSnapshot = publishSnapshot
        self.publishControlState = publishControlState
        self.diagnosticStore = diagnosticStore
        self.providerDeadline = providerDeadline
        self.sleep = sleep
        self.now = now
        snapshot = DashboardSnapshot(providers: [], refreshedAt: now())
        accountConnectionStates = Dictionary(
            uniqueKeysWithValues: self.disconnectedAccountProviders.map {
                ($0, ProviderAvailability.authenticationRequired)
            }
        )
        updateLegacyConnectionStates(includeUnavailableProviders: false)
        publishCurrentControlState()
    }

    func updateProviders(
        _ updatedProviders: [any UsageProvider],
        accountProviderOrder requestedOrder: [AccountProviderID],
        disconnected requestedDisconnected: Set<AccountProviderID>
    ) {
        let uniqueProviders = Self.uniqueProviders(updatedProviders)
        let configured = uniqueProviders.map(\.accountProviderID)
        let configuredSet = Set(configured)
        let updatedDefaultOrder = AccountProviderDisplayOrder.defaultOrder(
            configured: configured
        )
        let repairedOrder = AccountProviderDisplayOrder.repaired(
            requestedOrder,
            configured: updatedDefaultOrder
        )
        let previousUsage = Dictionary(
            uniqueKeysWithValues: snapshot.providers.map {
                ($0.accountProviderID, $0)
            }
        )

        providers = uniqueProviders
        defaultAccountProviderOrder = updatedDefaultOrder
        accountProviderOrder = repairedOrder
        providerOrder = ProviderDisplayOrder.repaired(
            repairedOrder.map(\.providerID)
        )
        disconnectedAccountProviders = requestedDisconnected.intersection(
            configuredSet
        )
        accountConnectionStates = accountConnectionStates.filter {
            configuredSet.contains($0.key)
        }
        for identity in disconnectedAccountProviders {
            accountConnectionStates[identity] = .authenticationRequired
        }
        updateLegacyConnectionStates(includeUnavailableProviders: false)
        snapshot = .ordered(
            providers: repairedOrder.compactMap { previousUsage[$0] },
            refreshedAt: snapshot.refreshedAt,
            accountProviderOrder: repairedOrder
        )
        providerRosterVersion += 1
        if isRefreshing {
            refreshAfterCurrent = true
        }
        publishSnapshot(snapshot)
        publishCurrentControlState()
    }

    var isAccountProviderOrderDefault: Bool {
        accountProviderOrder == defaultAccountProviderOrder
    }

    var accountProviderOrderingItems: [AccountProviderOrderingItem] {
        let counts = Dictionary(grouping: providers, by: \.id).mapValues(\.count)
        let byIdentity = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.accountProviderID, $0) }
        )
        return accountProviderOrder.compactMap { identity in
            guard let provider = byIdentity[identity] else {
                return providers.isEmpty
                    ? AccountProviderOrderingItem(
                        accountProviderID: identity,
                        provider: identity.providerID,
                        accountLabel: AccountLabel.defaultValue,
                        showsAccountLabel: false,
                        availability: accountConnectionStates[identity],
                        isDisconnected: isDisconnected(identity)
                    )
                    : nil
            }
            let label = AccountLabel.sanitized(provider.accountLabel)
            return AccountProviderOrderingItem(
                accountProviderID: identity,
                provider: provider.id,
                accountLabel: label,
                showsAccountLabel: counts[provider.id, default: 0] > 1
                    || label != AccountLabel.defaultValue,
                availability: accountConnectionStates[identity],
                isDisconnected: isDisconnected(identity)
            )
        }
    }

    func setProviderOrder(_ order: [ProviderID]) {
        let repaired = ProviderDisplayOrder.repaired(order)
        let composites = repaired.flatMap { providerID in
            defaultAccountProviderOrder.filter {
                $0.providerID == providerID
            }
        }
        applyAccountProviderOrder(composites)
    }

    func moveProvider(_ provider: ProviderID, by offset: Int) {
        guard let source = providerOrder.firstIndex(of: provider) else {
            return
        }
        let destination = source + offset
        guard providerOrder.indices.contains(destination) else { return }
        var moved = providerOrder
        let value = moved.remove(at: source)
        moved.insert(value, at: destination)
        setProviderOrder(moved)
    }

    func setAccountProviderOrder(_ order: [AccountProviderID]) {
        applyAccountProviderOrder(order)
    }

    func moveAccountProviders(
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) {
        let valid = offsets.filter(accountProviderOrder.indices.contains)
        guard !valid.isEmpty else { return }
        let moving = valid.map { accountProviderOrder[$0] }
        var remaining = accountProviderOrder
        for index in valid.sorted(by: >) { remaining.remove(at: index) }
        let adjusted = destination - valid.filter { $0 < destination }.count
        let insertion = min(max(0, adjusted), remaining.count)
        remaining.insert(contentsOf: moving, at: insertion)
        applyAccountProviderOrder(remaining)
    }

    @discardableResult
    func moveAccountProvider(
        _ identity: AccountProviderID,
        by offset: Int
    ) -> Bool {
        guard let source = accountProviderOrder.firstIndex(of: identity) else {
            return false
        }
        let destination = source + offset
        guard accountProviderOrder.indices.contains(destination) else {
            return false
        }
        var moved = accountProviderOrder
        let value = moved.remove(at: source)
        moved.insert(value, at: destination)
        applyAccountProviderOrder(moved)
        return true
    }

    func resetAccountProviderOrder() {
        applyAccountProviderOrder(defaultAccountProviderOrder)
    }

    private func applyAccountProviderOrder(_ order: [AccountProviderID]) {
        let repaired = AccountProviderDisplayOrder.repaired(
            order,
            configured: defaultAccountProviderOrder
        )
        guard repaired != accountProviderOrder else { return }
        accountProviderOrder = repaired
        providerOrder = ProviderDisplayOrder.repaired(
            accountProviderOrder.map(\.providerID)
        )
        persistAccountProviderOrder(accountProviderOrder)
        persistProviderOrder(providerOrder)
        setSnapshot(.ordered(
            providers: snapshot.providers,
            refreshedAt: snapshot.refreshedAt,
            accountProviderOrder: accountProviderOrder
        ))
        publishCurrentControlState()
    }

    func isDisconnected(_ provider: ProviderID) -> Bool {
        disconnectedProviders.contains(provider)
    }

    func disconnectProvider(_ provider: ProviderID) {
        let configuredIdentities = providers
            .filter { $0.id == provider }
            .map(\.accountProviderID)
        let identities = configuredIdentities.isEmpty
            ? [AccountProviderID(accountID: .legacy, providerID: provider)]
            : configuredIdentities
        var changed = false
        for identity in identities {
            changed = disconnectAccountProvider(
                identity,
                publishesState: false
            ) || changed
        }
        guard changed else { return }
        persistDisconnectedAccountProviders(disconnectedAccountProviders)
        persistDisconnectedProviders(disconnectedProviders)
        publishCurrentControlState()
    }

    func reconnectProvider(_ provider: ProviderID) {
        let identities = disconnectedAccountProviders.filter {
            $0.providerID == provider
        }
        var changed = false
        for identity in identities {
            changed = reconnectAccountProvider(
                identity,
                publishesState: false
            ) || changed
        }
        guard changed else { return }
        persistDisconnectedAccountProviders(disconnectedAccountProviders)
        persistDisconnectedProviders(disconnectedProviders)
        publishCurrentControlState()
    }

    func isDisconnected(_ accountProvider: AccountProviderID) -> Bool {
        disconnectedAccountProviders.contains(accountProvider)
    }

    func disconnectAccountProvider(_ accountProvider: AccountProviderID) {
        guard disconnectAccountProvider(
            accountProvider,
            publishesState: true
        ) else {
            return
        }
        persistDisconnectedAccountProviders(disconnectedAccountProviders)
        persistDisconnectedProviders(disconnectedProviders)
    }

    func reconnectAccountProvider(_ accountProvider: AccountProviderID) {
        guard reconnectAccountProvider(
            accountProvider,
            publishesState: true
        ) else {
            return
        }
        persistDisconnectedAccountProviders(disconnectedAccountProviders)
        persistDisconnectedProviders(disconnectedProviders)
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
            let refreshRosterVersion = providerRosterVersion
            let refreshProviders = providers
            let deadline = providerDeadline
            let deadlineSleep = sleep
            let results = await withTaskGroup(
                of: ProviderFetchResult.self,
                returning: [ProviderFetchResult].self
            ) { group in
                for provider in refreshProviders
                where !disconnectedAccountProviders.contains(
                    provider.accountProviderID
                ) {
                    group.addTask {
                        await Self.fetch(
                            provider,
                            now: fetchNow,
                            deadline: deadline,
                            sleep: deadlineSleep
                        )
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
            guard refreshRosterVersion == providerRosterVersion else {
                refreshAfterCurrent = true
                continue
            }

            let byAccountProvider = Dictionary(
                uniqueKeysWithValues: results.map { ($0.id, $0) }
            )
            accountConnectionStates = Dictionary(
                uniqueKeysWithValues: refreshProviders.map { provider in
                    let identity = provider.accountProviderID
                    return (
                        identity,
                        disconnectedAccountProviders.contains(identity)
                            ? .authenticationRequired
                            : byAccountProvider[identity]?.availability
                                ?? .unavailable
                    )
                }
            )
            var disabledForSchemaChange = false
            for result in results {
                guard let revision = result.contractRevision else { continue }
                disabledForSchemaChange = disconnectedAccountProviders
                    .insert(result.id).inserted || disabledForSchemaChange
                diagnosticStore.record(
                    DiagnosticEvent(
                        provider: result.id.providerID,
                        status: .schemaChanged,
                        category: .providerRefresh,
                        contractRevision: revision,
                        occurredAt: fetchNow
                    )
                )
            }
            if disabledForSchemaChange {
                persistDisconnectedAccountProviders(
                    disconnectedAccountProviders
                )
                persistDisconnectedProviders(disconnectedProviders)
            }
            updateLegacyConnectionStates(includeUnavailableProviders: true)
            let previous = Dictionary(
                uniqueKeysWithValues: snapshot.providers.map {
                    ($0.accountProviderID, $0)
                }
            )
            let usages: [ProviderUsage] = refreshProviders.compactMap {
                provider -> ProviderUsage? in
                let identity = provider.accountProviderID
                guard !disconnectedAccountProviders.contains(identity) else {
                    return nil
                }
                guard let result = byAccountProvider[identity] else {
                    return nil
                }
                if let usage = result.usage {
                    return usage
                }
                if
                    result.availability == .failed
                        || result.retainsPreviousUsage
                {
                    return previous[identity]?.recordingRefreshAttempt(
                        at: fetchNow,
                        failure: result.refreshFailure ?? .unknown
                    )
                }
                return nil
            }
            setSnapshot(.ordered(
                providers: usages,
                refreshedAt: now(),
                accountProviderOrder: accountProviderOrder
            ))
        } while refreshAfterCurrent && !Task.isCancelled
    }

    nonisolated
    private static func fetch(
        _ provider: any UsageProvider,
        now: Date,
        deadline: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async -> ProviderFetchResult {
        let race = ProviderDeadlineRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                let fetchTask = Task {
                    let result: ProviderFetchResult
                    do {
                        let fetched = try await provider.fetch(now: now)
                        let usage = fetched
                            .assigningAccount(
                                id: provider.accountID,
                                label: provider.accountLabel
                            )
                            .recordingRefreshAttempt(at: now)
                        result = ProviderFetchResult(
                            id: provider.accountProviderID,
                            usage: usage.availability == .available
                                ? usage
                                : nil,
                            availability: usage.availability
                        )
                    } catch is CancellationError {
                        result = ProviderFetchResult(
                            id: provider.accountProviderID,
                            usage: nil,
                            availability: .failed,
                            wasCancelled: true
                        )
                    } catch {
                        let contractRevision: Int? = if case let
                            ProviderContractError.schemaChanged(
                                _, _, revision
                            ) = error
                        {
                            revision
                        } else {
                            nil
                        }
                        result = ProviderFetchResult(
                            id: provider.accountProviderID,
                            usage: nil,
                            availability: availability(for: error),
                            retainsPreviousUsage:
                                retainsPreviousUsage(for: error),
                            refreshFailure: refreshFailure(for: error),
                            contractRevision: contractRevision
                        )
                    }
                    race.resolve(result)
                }
                let deadlineTask = Task {
                    do {
                        try await sleep(max(0, deadline))
                        race.resolve(ProviderFetchResult(
                            id: provider.accountProviderID,
                            usage: nil,
                            availability: .failed,
                            retainsPreviousUsage: true,
                            refreshFailure: .network
                        ))
                    } catch {
                        if !Task.isCancelled {
                            race.resolve(ProviderFetchResult(
                                id: provider.accountProviderID,
                                usage: nil,
                                availability: .failed,
                                retainsPreviousUsage: true,
                                refreshFailure: .network
                            ))
                        }
                    }
                }
                race.setTasks(fetch: fetchTask, deadline: deadlineTask)
            }
        } onCancel: {
            race.cancel(id: provider.accountProviderID)
        }
    }

    @discardableResult
    private func disconnectAccountProvider(
        _ accountProvider: AccountProviderID,
        publishesState: Bool
    ) -> Bool {
        guard disconnectedAccountProviders.insert(accountProvider).inserted
        else {
            return false
        }
        accountConnectionStates[accountProvider] = .authenticationRequired
        updateLegacyConnectionStates(includeUnavailableProviders: false)
        setSnapshot(.ordered(
            providers: snapshot.providers.filter {
                $0.accountProviderID != accountProvider
            },
            refreshedAt: snapshot.refreshedAt,
            accountProviderOrder: accountProviderOrder
        ))
        if publishesState {
            publishCurrentControlState()
        }
        return true
    }

    @discardableResult
    private func reconnectAccountProvider(
        _ accountProvider: AccountProviderID,
        publishesState: Bool
    ) -> Bool {
        guard disconnectedAccountProviders.remove(accountProvider) != nil
        else {
            return false
        }
        accountConnectionStates[accountProvider] = .authenticationRequired
        updateLegacyConnectionStates(includeUnavailableProviders: false)
        if isRefreshing {
            refreshAfterCurrent = true
        }
        if publishesState {
            publishCurrentControlState()
        }
        return true
    }

    private func updateLegacyConnectionStates(
        includeUnavailableProviders: Bool
    ) {
        connectionStates = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.compactMap { provider in
                let states = providers
                    .filter { $0.id == provider }
                    .compactMap {
                        accountConnectionStates[$0.accountProviderID]
                    }
                guard !states.isEmpty else {
                    return includeUnavailableProviders
                        ? (provider, .unavailable)
                        : nil
                }
                let availability: ProviderAvailability
                if states.contains(.available) {
                    availability = .available
                } else if states.contains(.schemaChanged) {
                    availability = .schemaChanged
                } else if states.contains(.failed) {
                    availability = .failed
                } else if states.contains(.authenticationRequired) {
                    availability = .authenticationRequired
                } else {
                    availability = .unavailable
                }
                return (provider, availability)
            }
        )
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
                accountProviderOrder: accountProviderOrder,
                accountProviderLabels: Dictionary(
                    uniqueKeysWithValues: providers.map {
                        (
                            $0.accountProviderID,
                            AccountLabel.sanitized($0.accountLabel)
                        )
                    }
                ),
                disconnectedAccountProviders:
                    disconnectedAccountProviders,
                isRefreshing: isRefreshing
            )
        )
    }

    private static func uniqueProviders(
        _ providers: [any UsageProvider]
    ) -> [any UsageProvider] {
        var seen: Set<AccountProviderID> = []
        return providers.filter {
            seen.insert($0.accountProviderID).inserted
        }
    }

    nonisolated
    private static func availability(
        for error: any Error
    ) -> ProviderAvailability {
        if case ProviderContractError.schemaChanged = error {
            return .schemaChanged
        }
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

    /// Classifies a retained failure so every surface can explain why the
    /// displayed values stopped advancing.
    nonisolated
    private static func refreshFailure(
        for error: any Error
    ) -> ProviderRefreshFailure {
        if error is CredentialDiscoveryError {
            return .credential
        }
        if case ProviderContractError.schemaChanged = error {
            return .schema
        }
        if let error = error as? ProviderTransportError {
            switch error {
            case .authenticationRequired:
                return .credential
            case .requestFailed:
                return .service
            case .transientTransport, .operationTimedOut:
                return .network
            case .invalidResponse, .invalidContentType, .responseTooLarge,
                 .invalidJSON:
                return .schema
            }
        }
        if error is UsageParsingError {
            return .schema
        }
        if error is URLError {
            return .network
        }
        return .unknown
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
    let id: AccountProviderID
    let usage: ProviderUsage?
    let availability: ProviderAvailability
    var wasCancelled = false
    var retainsPreviousUsage = false
    var refreshFailure: ProviderRefreshFailure?
    var contractRevision: Int? = nil
}

private final class ProviderDeadlineRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProviderFetchResult, Never>?
    private var fetchTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var result: ProviderFetchResult?

    func install(
        _ continuation: CheckedContinuation<ProviderFetchResult, Never>
    ) {
        let resolved = lock.withLock { () -> ProviderFetchResult? in
            guard result == nil else { return result }
            self.continuation = continuation
            return nil
        }
        if let resolved { continuation.resume(returning: resolved) }
    }

    func setTasks(
        fetch: Task<Void, Never>,
        deadline: Task<Void, Never>
    ) {
        let shouldCancel = lock.withLock {
            fetchTask = fetch
            deadlineTask = deadline
            return result != nil
        }
        if shouldCancel {
            fetch.cancel()
            deadline.cancel()
        }
    }

    func resolve(_ result: ProviderFetchResult) {
        let completion = lock.withLock { () -> (
            CheckedContinuation<ProviderFetchResult, Never>?,
            Task<Void, Never>?,
            Task<Void, Never>?
        )? in
            guard self.result == nil else { return nil }
            self.result = result
            let completion = (continuation, fetchTask, deadlineTask)
            continuation = nil
            fetchTask = nil
            deadlineTask = nil
            return completion
        }
        guard let completion else { return }
        completion.1?.cancel()
        completion.2?.cancel()
        completion.0?.resume(returning: result)
    }

    func cancel(id: AccountProviderID) {
        resolve(ProviderFetchResult(
            id: id,
            usage: nil,
            availability: .failed,
            wasCancelled: true
        ))
    }
}
