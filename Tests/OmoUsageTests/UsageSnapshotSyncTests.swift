import Foundation
import Testing
@testable import OmoUsage

@Suite
struct UsageSnapshotSyncTests {
    private let refreshedAt = Date(timeIntervalSince1970: 1_786_867_200)

    @Test
    func roundTripsACompleteDashboardSnapshot() throws {
        let expected = DashboardSnapshot(
            providers: [
                ProviderUsage(
                    provider: .codex,
                    planName: "Plus",
                    groups: [
                        UsageGroup(
                            id: "limits",
                            title: nil,
                            meters: [
                                UsageMeter(
                                    id: "session",
                                    title: "세션",
                                    period: .session,
                                    percentRemaining: 72,
                                    resetsAt: refreshedAt.addingTimeInterval(
                                        3_600
                                    ),
                                    resetText: "1시간 후 리셋"
                                )
                            ],
                            creditText: nil
                        )
                    ],
                    availability: .available,
                    updatedAt: refreshedAt
                )
            ],
            refreshedAt: refreshedAt
        )

        let encoded = try UsageSnapshotCodec.encode(expected)
        let decoded = try UsageSnapshotCodec.decode(encoded)

        #expect(decoded == expected)
    }

    @Test
    func rejectsUnsupportedSnapshotVersions() throws {
        let data = Data(
            #"{"version":5,"providers":[],"generatedAt":0}"#.utf8
        )

        #expect(throws: UsageSnapshotCodecError.unsupportedVersion(5)) {
            try UsageSnapshotCodec.decode(data)
        }
    }

    @Test
    func rejectsOutOfRangePercentagesFromICloud() {
        let data = Data(
            """
            {
              "version": 1,
              "providers": [{
                "provider": "codex",
                "planName": "Plus",
                "groups": [{
                  "id": "limits",
                  "title": null,
                  "meters": [{
                    "id": "session",
                    "title": "세션",
                    "period": "session",
                    "percentRemaining": 999,
                    "resetsAt": null,
                    "resetText": null,
                    "showsMenuBarBadge": false
                  }],
                  "creditText": null
                }],
                "availability": "available",
                "updatedAt": null
              }],
              "refreshedAt": 0
            }
            """.utf8
        )

        #expect(throws: UsageSnapshotCodecError.invalidPayload) {
            try UsageSnapshotCodec.decode(data)
        }
    }

    @Test
    func rejectsDatesThatCouldOverflowMobileFormatting() {
        let data = Data(
            """
            {
              "version": 1,
              "providers": [{
                "provider": "codex",
                "planName": "Plus",
                "groups": [{
                  "id": "limits",
                  "title": null,
                  "meters": [{
                    "id": "session",
                    "title": "세션",
                    "period": "session",
                    "percentRemaining": 50,
                    "resetsAt": 1e100,
                    "resetText": null,
                    "showsMenuBarBadge": false
                  }],
                  "creditText": null
                }],
                "availability": "available",
                "updatedAt": null
              }],
              "refreshedAt": 1786867200000
            }
            """.utf8
        )

        #expect(throws: UsageSnapshotCodecError.invalidPayload) {
            try UsageSnapshotCodec.decode(data)
        }
    }

    @Test
    func rejectsSnapshotsLargerThanTheSyncBudget() {
        let data = Data(
            repeating: 0,
            count: UsageSnapshotCodec.maximumPayloadBytes + 1
        )

        #expect(
            throws: UsageSnapshotCodecError.payloadTooLarge(data.count)
        ) {
            try UsageSnapshotCodec.decode(data)
        }
    }

    @Test
    @MainActor
    func surfacesICloudSynchronizationFailures() {
        let keyValueStore = StubUbiquitousKeyValueStore(
            synchronizes: false
        )
        let store = UbiquitousUsageSnapshotStore(
            store: keyValueStore
        )

        #expect(
            throws: UsageSnapshotStoreError.synchronizationFailed
        ) {
            try store.load()
        }
    }

    @Test
    @MainActor
    func mobileViewModelLoadsTheLatestPrivateSnapshot() {
        let expected = DashboardSnapshot(
            providers: [],
            refreshedAt: refreshedAt
        )
        let viewModel = MobileUsageViewModel(
            loadSnapshot: { expected }
        )

        viewModel.reload()

        #expect(viewModel.snapshot == expected)
        #expect(viewModel.loadState == .empty)
    }

    @Test
    @MainActor
    func mobileViewModelPreservesDistinctSanitizedAccountsFromV2() throws {
        let data = Data(
            """
            {
              "version": 2,
              "providers": [
                {
                  "provider": "openrouter",
                  "accountID": "00000000-0000-0000-0000-00000000000a",
                  "accountLabel": "Team A",
                  "planName": "",
                  "groups": [],
                  "availability": "available",
                  "updatedAt": null
                },
                {
                  "provider": "openrouter",
                  "accountID": "00000000-0000-0000-0000-00000000000b",
                  "accountLabel": "owner@example.com",
                  "planName": "",
                  "groups": [],
                  "availability": "available",
                  "updatedAt": null
                }
              ],
              "refreshedAt": 1786867200000
            }
            """.utf8
        )
        let viewModel = MobileUsageViewModel(
            loadSnapshot: { try UsageSnapshotCodec.decode(data) }
        )

        viewModel.reload()

        let providers = try #require(viewModel.snapshot?.providers)
        #expect(viewModel.loadState == .content)
        #expect(providers.filter { $0.provider == .openrouter }.count == 2)
        #expect(Set(providers.map(\.id)).count == 2)
        #expect(
            providers.map(\.accountLabel)
                == ["Team A", AccountLabel.defaultValue]
        )
    }

    @Test
    func mobileFixtureRendersTwoAccountsForTheSameProvider() throws {
        let now = Date(timeIntervalSince1970: 1_785_675_000)

        let fixture = DashboardSnapshot.mobileFixture(now: now)

        #expect(fixture.refreshedAt == now)
        #expect(fixture.providers.map(\.provider) == [
            .openrouter,
            .openrouter
        ])
        #expect(fixture.providers.map(\.accountLabel) == [
            "QA Team",
            "QA Personal"
        ])
        #expect(
            Set(fixture.providers.map(\.accountProviderID)).count == 2
        )
        #expect(
            fixture.providers.allSatisfy {
                $0.availability == .available
                    && !$0.groups.isEmpty
            }
        )
    }

    @Test
    @MainActor
    func mobileViewModelSurfacesSyncFailures() {
        let viewModel = MobileUsageViewModel(
            loadSnapshot: {
                throw StubSnapshotError.unavailable
            }
        )

        viewModel.reload()

        #expect(viewModel.snapshot == nil)
        #expect(viewModel.loadState == .failed)
    }

    @Test
    @MainActor
    func mobileViewModelRetainsLastGoodSnapshotAfterSyncFailure() {
        let expected = DashboardSnapshot.mobileFixture(now: refreshedAt)
        let loader = StubMobileSnapshotLoader(
            responses: [
                .success(expected),
                .failure(StubSnapshotError.unavailable)
            ]
        )
        let viewModel = MobileUsageViewModel(
            loadSnapshot: loader.load
        )

        viewModel.reload()
        viewModel.reload()

        #expect(viewModel.snapshot == expected)
        #expect(viewModel.loadState == .failed)
    }
}

private enum StubSnapshotError: Error {
    case unavailable
}

@MainActor
private final class StubMobileSnapshotLoader: @unchecked Sendable {
    private var responses: [
        Result<DashboardSnapshot?, any Error>
    ]

    init(responses: [Result<DashboardSnapshot?, any Error>]) {
        self.responses = responses
    }

    func load() throws -> DashboardSnapshot? {
        try responses.removeFirst().get()
    }
}

private final class StubUbiquitousKeyValueStore:
    UbiquitousKeyValueStoring
{
    private let synchronizes: Bool
    private var values: [String: Any] = [:]

    init(synchronizes: Bool) {
        self.synchronizes = synchronizes
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func synchronize() -> Bool {
        synchronizes
    }
}
