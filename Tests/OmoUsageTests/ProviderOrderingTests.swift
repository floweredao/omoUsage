import Foundation
import Testing
import UniformTypeIdentifiers
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct ProviderOrderingTests {
    private let first = AccountID(
        rawValue: "00000000-0000-0000-0000-000000000002"
    )!
    private let second = AccountID(
        rawValue: "00000000-0000-0000-0000-000000000003"
    )!
    private let now = Date(timeIntervalSince1970: 1_786_867_200)

    @Test
    func nativeDragUsesStandardTextPasteboardContract() {
        #expect(ProviderOrderingTransfer.type == .utf8PlainText)
        #expect(ProviderOrderingTransfer.type.conforms(to: .data))
        #expect(ProviderOrderingTransfer.type.conforms(to: .item))
    }

    @Test
    func nativeListHeightFitsEveryCompleteRow() {
        #expect(ProviderOrderingLayout.rowHeight == 60)
        #expect(ProviderOrderingLayout.verticalRowInset == 0)
        #expect(
            ProviderOrderingLayout.listHeight(itemCount: 9) == 540
        )
    }

    @Test
    func sameProviderOrderingActionsUseAccountQualifiedNames() {
        let team = ProviderOrderingAccessibility.identityName(
            providerName: "OpenRouter",
            accountLabel: "QA Team",
            showsAccountLabel: true
        )
        let personal = ProviderOrderingAccessibility.identityName(
            providerName: "OpenRouter",
            accountLabel: "QA Personal",
            showsAccountLabel: true
        )

        #expect(team == "OpenRouter, QA Team")
        #expect(personal == "OpenRouter, QA Personal")
        #expect(team != personal)
        #expect(
            ProviderOrderingAccessibility.announcement(
                identityName: team,
                position: "8 of 9"
            ) == "OpenRouter, QA Team, 8 of 9"
        )
    }

    @Test
    func dragPlanUsesCompositeIdentityAndSemanticInsertion() {
        let team = AccountProviderID(
            accountID: first,
            providerID: .openrouter
        )
        let personal = AccountProviderID(
            accountID: second,
            providerID: .openrouter
        )
        let codex = AccountProviderID(
            accountID: .legacy,
            providerID: .codex
        )
        let order = [team, personal, codex]
        let payload = ProviderOrderingDrag.payload(for: team)

        #expect(
            ProviderOrderingDrag.identity(
                for: payload,
                in: order
            ) == team
        )
        #expect(
            ProviderOrderingDrag.movePlan(
                dragged: team,
                onto: codex,
                in: order
            ) == ProviderOrderingMovePlan(
                fromOffsets: IndexSet(integer: 0),
                toOffset: 3
            )
        )
        #expect(
            ProviderOrderingDrag.movePlan(
                dragged: team,
                onto: team,
                in: order
            ) == nil
        )
    }

    @Test
    func dragLifecyclePreviewsWithoutChangingOrderAndCancellationRollsBack() {
        let order = configuredProviders().map(\.accountProviderID)
        var drag = ProviderOrderingDragSession()
        drag.begin(dragged: order[0], in: order)

        let movedDown = drag.hover(onto: order[2])
        #expect(movedDown)
        #expect(drag.previewOrder == [order[1], order[2], order[0]])
        let movedOntoSelf = drag.hover(onto: order[0])
        #expect(!movedOntoSelf)
        #expect(drag.finish(accepted: false, in: order) == nil)
        #expect(drag.previewOrder == nil)
        #expect(drag.dragged == nil)

        drag.begin(dragged: order[2], in: order)
        let movedUp = drag.hover(onto: order[0])
        #expect(movedUp)
        #expect(drag.previewOrder == [order[2], order[0], order[1]])
        #expect(drag.finish(accepted: true, in: order) == ProviderOrderingMovePlan(
            fromOffsets: IndexSet(integer: 2), toOffset: 0
        ))
        #expect(drag.previewOrder == nil)
        #expect(drag.finish(accepted: true, in: order) == nil)
    }

    @Test @MainActor
    func hoverDoesNotPublishAndDropPersistsPreviewExactlyOnce() {
        var writes: [[AccountProviderID]] = []
        let viewModel = UsageDashboardViewModel(
            providers: configuredProviders(),
            persistAccountProviderOrder: { writes.append($0) },
            now: { now }
        )
        let original = viewModel.accountProviderOrder
        var drag = ProviderOrderingDragSession()
        drag.begin(dragged: original[0], in: original)
        let firstHover = drag.hover(onto: original[1])
        let secondHover = drag.hover(onto: original[2])
        #expect(firstHover)
        #expect(secondHover)
        let preview = drag.previewOrder
        #expect(viewModel.accountProviderOrder == original)
        #expect(writes.isEmpty)

        if let plan = drag.finish(accepted: true, in: viewModel.accountProviderOrder) {
            viewModel.moveAccountProviders(
                fromOffsets: plan.fromOffsets, toOffset: plan.toOffset
            )
        }
        #expect(viewModel.accountProviderOrder == preview)
        #expect(writes == [preview!])
        #expect(drag.finish(accepted: true, in: viewModel.accountProviderOrder) == nil)
    }

    @Test
    func unchangedOrStaleDragDoesNotCommit() {
        let order = configuredProviders().map(\.accountProviderID)
        var drag = ProviderOrderingDragSession()
        drag.begin(dragged: order[0], in: order)
        #expect(drag.finish(accepted: true, in: order) == nil)

        drag.begin(dragged: order[0], in: order)
        drag.hover(onto: order[2])
        drag.hover(onto: order[1])
        #expect(drag.previewOrder == order)
        #expect(drag.finish(accepted: true, in: order) == nil)

        drag.begin(dragged: order[0], in: order)
        drag.hover(onto: order[2])
        #expect(drag.finish(accepted: true, in: Array(order.reversed())) == nil)
        #expect(drag.previewOrder == nil)
    }

    @Test @MainActor
    func legacyMoveUsesSemanticInsertionForArbitraryOffset() {
        let viewModel = UsageDashboardViewModel(providers: [])
        viewModel.moveProvider(.claude, by: 3)
        #expect(Array(viewModel.providerOrder.prefix(4)) == [
            .codex, .cursor, .antigravity, .claude
        ])
    }

    @Test
    func defaultOrderUsesAccountRegistrationThenCanonicalProviders() {
        let configured = [
            AccountProviderID(accountID: second, providerID: .codex),
            AccountProviderID(accountID: first, providerID: .zai),
            AccountProviderID(accountID: second, providerID: .claude),
            AccountProviderID(accountID: first, providerID: .claude)
        ]

        let order = AccountProviderDisplayOrder.defaultOrder(
            configured: configured
        )

        #expect(order == [
            AccountProviderID(accountID: second, providerID: .claude),
            AccountProviderID(accountID: second, providerID: .codex),
            AccountProviderID(accountID: first, providerID: .claude),
            AccountProviderID(accountID: first, providerID: .zai)
        ])
    }

    @Test @MainActor
    func twoAccountsRemainDistinctAndDragPersistsOnce() {
        var writes: [[AccountProviderID]] = []
        var snapshots = 0
        var controlStates = 0
        let providers = configuredProviders()
        let viewModel = UsageDashboardViewModel(
            providers: providers,
            persistAccountProviderOrder: { writes.append($0) },
            publishSnapshot: { _ in snapshots += 1 },
            publishControlState: { _ in controlStates += 1 },
            now: { now }
        )
        let original = viewModel.accountProviderOrder

        viewModel.moveAccountProviders(
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )

        #expect(Set(viewModel.accountProviderOrder).count == 3)
        #expect(viewModel.accountProviderOrder.filter {
            $0.providerID == .claude
        }.count == 2)
        #expect(viewModel.accountProviderOrder == [
            original[1], original[2], original[0]
        ])
        #expect(writes == [viewModel.accountProviderOrder])
        #expect(snapshots == 1)
        #expect(controlStates == 2) // Initial state plus the one logical move.
    }

    @Test @MainActor
    func keyboardMoveUsesInsertionAndBoundaryNoOpDoesNotWrite() async {
        var writes = 0
        let viewModel = UsageDashboardViewModel(
            providers: configuredProviders(),
            persistAccountProviderOrder: { _ in writes += 1 },
            now: { now }
        )
        await viewModel.refresh()
        let firstIdentity = viewModel.accountProviderOrder[0]
        #expect(!viewModel.moveAccountProvider(firstIdentity, by: -1))
        #expect(writes == 0)
        #expect(viewModel.moveAccountProvider(firstIdentity, by: 2))
        #expect(viewModel.accountProviderOrder[2] == firstIdentity)
        #expect(writes == 1)
    }

    @Test @MainActor
    func resetRestoresDeterministicConfiguredDefaultOnce() {
        var writes: [[AccountProviderID]] = []
        let providers = configuredProviders()
        let defaultOrder = AccountProviderDisplayOrder.defaultOrder(
            configured: providers.map(\.accountProviderID)
        )
        let viewModel = UsageDashboardViewModel(
            providers: providers,
            accountProviderOrder: Array(defaultOrder.reversed()),
            persistAccountProviderOrder: { writes.append($0) },
            now: { now }
        )

        viewModel.resetAccountProviderOrder()
        viewModel.resetAccountProviderOrder()

        #expect(viewModel.accountProviderOrder == defaultOrder)
        #expect(writes == [defaultOrder])
    }

    @Test @MainActor
    func repairedOrderDropsUnknownAndDuplicatesAndAppendsConfigured() {
        let providers = configuredProviders()
        let configured = providers.map(\.accountProviderID)
        let unknown = AccountProviderID(
            accountID: AccountID(), providerID: .grok
        )
        let viewModel = UsageDashboardViewModel(
            providers: providers,
            accountProviderOrder: [configured[1], unknown, configured[1]],
            now: { now }
        )
        #expect(viewModel.accountProviderOrder == [
            configured[1], configured[0], configured[2]
        ])
    }

    @Test @MainActor
    func snapshotFollowsCompositeOrderAndLegacyProjectionStaysCompatible() async {
        let providers = configuredProviders()
        let configured = providers.map(\.accountProviderID)
        let order = [configured[1], configured[2], configured[0]]
        let viewModel = UsageDashboardViewModel(
            providers: providers,
            accountProviderOrder: order,
            now: { now }
        )

        await viewModel.refresh()

        #expect(viewModel.snapshot.providers.map(\.accountProviderID) == order)
        #expect(viewModel.providerOrder == ProviderDisplayOrder.repaired([
            .claude, .codex
        ]))
    }

    @Test
    func accountStoreAtomicallyUpdatesOnlyDisplayOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ProviderOrderingStore-\(UUID())",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let url = root.appending(path: "accounts.json")
        let accounts = [
            ProviderAccount(id: .legacy, label: "Default Account"),
            ProviderAccount(id: first, label: "Work")
        ]
        let original = ProviderAccountRegistry(
            version: ProviderAccountStore.currentVersion,
            migrationVersion: ProviderAccountStore.currentMigrationVersion,
            accounts: accounts,
            displayOrder: [
                AccountProviderID(accountID: .legacy, providerID: .codex),
                AccountProviderID(accountID: first, providerID: .claude)
            ],
            disconnected: [
                AccountProviderID(accountID: .legacy, providerID: .codex)
            ],
            providerReferences: [
                AccountProviderID(accountID: .legacy, providerID: .openrouter)
            ]
        )
        try JSONEncoder().encode(original).write(to: url)
        let defaults = UserDefaults(suiteName: "ProviderOrderingStore-\(UUID())")!
        let store = ProviderAccountStore(
            registryURL: url,
            defaults: defaults,
            legacyAPIKeyPresence: { _ in false }
        )
        let unknown = AccountProviderID(
            accountID: AccountID(),
            providerID: .grok
        )
        let requested = [
            original.displayOrder[1],
            unknown,
            original.displayOrder[1]
        ]

        let updated = try store.saveDisplayOrder(requested)

        #expect(updated.displayOrder == [
            original.displayOrder[1],
            original.displayOrder[0]
        ])
        #expect(updated.accounts == original.accounts)
        #expect(updated.disconnected == original.disconnected)
        #expect(updated.providerReferences == original.providerReferences)
    }

    @Test @MainActor
    func orderingOmitsUnverifiedAndEmptyRosterWithoutChangingPersistedOrder() {
        let viewModel = UsageDashboardViewModel(
            providers: configuredProviders(), now: { now }
        )
        let original = viewModel.accountProviderOrder
        #expect(viewModel.accountProviderOrderingItems.isEmpty)
        #expect(viewModel.accountProviderOrder == original)
        #expect(UsageDashboardViewModel(providers: []).accountProviderOrderingItems.isEmpty)
    }

    @Test @MainActor
    func orderingIncludesOnlyAvailableAccountsAndPreservesAccountLabels() async {
        let states: [ProviderAvailability] = [
            .available, .authenticationRequired, .unavailable, .failed, .schemaChanged
        ]
        let providers = zip(ProviderID.allCases, states).map { id, availability in
            OrderingProvider(
                id: id, accountID: first, label: "Work", availability: availability
            )
        } + [OrderingProvider(id: .claude, accountID: second, label: "Personal")]
        let order = providers.map(\.accountProviderID)
        var writes = 0
        let viewModel = UsageDashboardViewModel(
            providers: providers,
            accountProviderOrder: order,
            persistAccountProviderOrder: { _ in writes += 1 },
            now: { now }
        )
        await viewModel.refresh()

        let items = viewModel.accountProviderOrderingItems
        #expect(items.map(\.id) == [order[0], order[5]])
        #expect(items.map(\.accountLabel) == ["Work", "Personal"])
        #expect(items.allSatisfy { $0.showsAccountLabel && !$0.isDisconnected })
        #expect(viewModel.accountProviderOrder == order)
        #expect(writes == 0)
    }

    @Test @MainActor
    func disconnectAndReconnectRequireVerifiedAvailabilityWithoutDroppingOrder() async {
        let providers = configuredProviders()
        let original = providers.map(\.accountProviderID)
        let viewModel = UsageDashboardViewModel(
            providers: providers, accountProviderOrder: original, now: { now }
        )
        await viewModel.refresh()
        viewModel.disconnectAccountProvider(original[1])
        #expect(viewModel.accountProviderOrderingItems.map(\.id) == [original[0], original[2]])
        #expect(viewModel.accountProviderOrder == original)

        viewModel.reconnectAccountProvider(original[1])
        #expect(viewModel.accountProviderOrderingItems.map(\.id) == [original[0], original[2]])
        await viewModel.refresh()
        #expect(viewModel.accountProviderOrderingItems.map(\.id) == original)
        #expect(viewModel.accountProviderOrder == original)
    }

    @Test @MainActor
    func keyboardMovesAcrossHiddenIdentitiesAndHonorsVisibleBoundaries() async {
        let providers = interleavedProviders()
        let order = providers.map(\.accountProviderID)
        var writes: [[AccountProviderID]] = []
        let viewModel = UsageDashboardViewModel(
            providers: providers,
            accountProviderOrder: order,
            persistAccountProviderOrder: { writes.append($0) },
            now: { now }
        )
        await viewModel.refresh()

        #expect(!viewModel.moveAccountProvider(order[1], by: -1))
        #expect(!viewModel.moveAccountProvider(order[3], by: 1))
        #expect(!viewModel.moveAccountProvider(order[2], by: 1))
        #expect(writes.isEmpty)
        #expect(viewModel.moveAccountProvider(order[1], by: 1))
        let moved = [order[0], order[2], order[3], order[1], order[4]]
        #expect(viewModel.accountProviderOrder == moved)
        #expect(viewModel.accountProviderOrderingItems.map(\.id) == [order[3], order[1]])
        #expect(writes == [moved])
        #expect(viewModel.moveAccountProvider(order[1], by: -1))
        #expect(viewModel.accountProviderOrderingItems.map(\.id) == [order[1], order[3]])
        #expect(viewModel.accountProviderOrder.filter { ![order[1], order[3]].contains($0) }
            == [order[0], order[2], order[4]])
        #expect(writes.count == 2)
    }

    @Test @MainActor
    func dragAcrossHiddenIdentitiesPersistsFullOrderAndReconnectRestoresPosition() async throws {
        let providers = interleavedProviders()
        let order = providers.map(\.accountProviderID)
        var writes: [[AccountProviderID]] = []
        let viewModel = UsageDashboardViewModel(
            providers: providers,
            accountProviderOrder: order,
            persistAccountProviderOrder: { writes.append($0) },
            now: { now }
        )
        await viewModel.refresh()
        var drag = ProviderOrderingDragSession()
        drag.begin(dragged: order[1], in: viewModel.accountProviderOrder)
        let hovered = drag.hover(onto: order[3])
        #expect(hovered)
        #expect(writes.isEmpty)
        let finished = drag.finish(accepted: true, in: viewModel.accountProviderOrder)
        let plan = try #require(finished)
        viewModel.moveAccountProviders(fromOffsets: plan.fromOffsets, toOffset: plan.toOffset)
        let moved = [order[0], order[2], order[3], order[1], order[4]]
        #expect(viewModel.accountProviderOrder == moved)
        #expect(viewModel.accountProviderOrderingItems.map(\.id) == [order[3], order[1]])
        #expect(viewModel.snapshot.providers.map(\.accountProviderID) == [order[3], order[1]])
        #expect(writes == [moved])

        let reconnected = providers.map { provider in
            OrderingProvider(id: provider.id, accountID: provider.accountID, label: provider.label)
        }
        viewModel.updateProviders(reconnected, accountProviderOrder: moved, disconnected: [])
        await viewModel.refresh()
        #expect(viewModel.accountProviderOrderingItems.map(\.id) == moved)
        #expect(viewModel.accountProviderOrder == moved)
        #expect(writes == [moved])
    }

    private func interleavedProviders() -> [OrderingProvider] {
        [
            OrderingProvider(id: .codex, accountID: first, label: "Work", availability: .unavailable),
            OrderingProvider(id: .claude, accountID: first, label: "Work"),
            OrderingProvider(id: .cursor, accountID: first, label: "Work", availability: .authenticationRequired),
            OrderingProvider(id: .claude, accountID: second, label: "Personal"),
            OrderingProvider(id: .zai, accountID: first, label: "Work", availability: .failed)
        ]
    }

    private func configuredProviders() -> [any UsageProvider] {
        [
            OrderingProvider(id: .claude, accountID: first, label: "Work"),
            OrderingProvider(id: .claude, accountID: second, label: "Personal"),
            OrderingProvider(id: .codex, accountID: .legacy, label: "Default Account")
        ]
    }
}

private struct OrderingProvider: UsageProvider {
    let id: ProviderID
    let accountID: AccountID
    let label: String
    var availability: ProviderAvailability = .available
    var accountLabel: String { label }

    func fetch(now: Date) async throws -> ProviderUsage {
        ProviderUsage(
            provider: id,
            accountID: accountID,
            accountLabel: label,
            planName: "Test",
            groups: [],
            availability: availability,
            updatedAt: now
        )
    }
}
