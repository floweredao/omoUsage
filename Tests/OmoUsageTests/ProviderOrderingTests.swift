import Foundation
import Testing
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
    func keyboardMoveUsesInsertionAndBoundaryNoOpDoesNotWrite() {
        var writes = 0
        let viewModel = UsageDashboardViewModel(
            providers: configuredProviders(),
            persistAccountProviderOrder: { _ in writes += 1 },
            now: { now }
        )
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
    var accountLabel: String { label }

    func fetch(now: Date) async throws -> ProviderUsage {
        ProviderUsage(
            provider: id,
            accountID: accountID,
            accountLabel: label,
            planName: "Test",
            groups: [],
            availability: .available,
            updatedAt: now
        )
    }
}
