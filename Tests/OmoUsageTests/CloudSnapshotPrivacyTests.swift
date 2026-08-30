import Foundation
import Testing
@testable import OmoUsage

@Suite
struct CloudSnapshotPrivacyTests {
    private let generatedAt = Date(timeIntervalSince1970: 1_786_867_200)

    @Test
    func v3OmitsStableAccountMetadataAndUsesProviderLocalOrdinals() throws {
        let firstID = try #require(AccountID(
            rawValue: "11111111-1111-1111-1111-111111111111"
        ))
        let secondID = try #require(AccountID(
            rawValue: "22222222-2222-2222-2222-222222222222"
        ))
        let snapshot = DashboardSnapshot(
            providers: [
                usage(accountID: firstID, accountLabel: "Client A"),
                usage(
                    accountID: secondID,
                    accountLabel: "owner@example.com"
                )
            ],
            refreshedAt: generatedAt
        )

        let data = try UsageSnapshotCodec.encode(snapshot)
        let text = String(decoding: data, as: UTF8.self)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let providers = try #require(
            object["providers"] as? [[String: Any]]
        )

        #expect(object["version"] as? Int == 3)
        #expect(providers.map { $0["accountOrdinal"] as? Int } == [1, 2])
        #expect(providers.allSatisfy { $0["accountID"] == nil })
        #expect(providers.allSatisfy { $0["accountLabel"] == nil })
        #expect(!text.contains(firstID.rawValue))
        #expect(!text.contains(secondID.rawValue))
        #expect(!text.contains("Client A"))
        #expect(!text.contains("owner@example.com"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("\\Users\\"))

        let decoded = try UsageSnapshotCodec.decode(data)
        #expect(decoded.providers.map(\.accountLabel) == [
            "Account 1", "Account 2"
        ])
        #expect(Set(decoded.providers.map(\.accountProviderID)).count == 2)
    }

    @Test
    func ordinalsRestartForEachProvider() throws {
        let snapshot = DashboardSnapshot(
            providers: [
                usage(
                    provider: .codex,
                    accountID: try #require(AccountID(
                        rawValue: "11111111-1111-1111-1111-111111111111"
                    )),
                    accountLabel: "First"
                ),
                usage(
                    provider: .claude,
                    accountID: try #require(AccountID(
                        rawValue: "22222222-2222-2222-2222-222222222222"
                    )),
                    accountLabel: "Second"
                ),
                usage(
                    provider: .codex,
                    accountID: try #require(AccountID(
                        rawValue: "33333333-3333-3333-3333-333333333333"
                    )),
                    accountLabel: "Third"
                )
            ],
            refreshedAt: generatedAt
        )

        let data = try UsageSnapshotCodec.encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let providers = try #require(
            object["providers"] as? [[String: Any]]
        )

        #expect(providers.map { $0["accountOrdinal"] as? Int } == [1, 1, 2])
    }

    @Test
    func minimizedV3RetainsFreshnessFields() throws {
        let attemptAt = generatedAt.addingTimeInterval(-5)
        let successAt = generatedAt.addingTimeInterval(-60)
        let snapshot = DashboardSnapshot(
            providers: [
                usage(
                    lastSuccessfulAt: successAt,
                    lastRefreshAttemptAt: attemptAt,
                    refreshFailure: .network
                )
            ],
            generatedAt: generatedAt,
            lastRefreshAttemptAt: attemptAt,
            oldestDisplayedSuccessAt: successAt
        )

        let encoded = try UsageSnapshotCodec.encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let provider = try #require(
            (object["providers"] as? [[String: Any]])?.first
        )
        let decoded = try UsageSnapshotCodec.decode(encoded)

        #expect(provider["accountOrdinal"] as? Int == 1)
        #expect(provider["accountID"] == nil)
        #expect(provider["accountLabel"] == nil)
        #expect(provider["lastSuccessfulAt"] != nil)
        #expect(provider["lastRefreshAttemptAt"] != nil)
        #expect(provider["refreshFailure"] as? String == "network")
        #expect(decoded.generatedAt == generatedAt)
        #expect(decoded.lastRefreshAttemptAt == attemptAt)
        #expect(decoded.oldestDisplayedSuccessAt == successAt)
        #expect(decoded.providers.first?.lastSuccessfulAt == successAt)
        #expect(decoded.providers.first?.lastRefreshAttemptAt == attemptAt)
        #expect(decoded.providers.first?.refreshFailure == .network)
        #expect(decoded.providers.first?.freshness == .stale)
    }

    @Test
    @MainActor
    func encodingIsDeterministicAndUnchangedPublishSkipsCloudWrite() throws {
        let snapshot = DashboardSnapshot(
            providers: [usage()],
            refreshedAt: generatedAt
        )
        #expect(
            try UsageSnapshotCodec.encode(snapshot)
                == UsageSnapshotCodec.encode(snapshot)
        )
        let keyValueStore = PrivacyRecordingKeyValueStore()
        let store = UbiquitousUsageSnapshotStore(store: keyValueStore)

        try store.publish(snapshot)
        try store.publish(snapshot)

        let expectedData = try UsageSnapshotCodec.encode(snapshot)
        #expect(
            UbiquitousUsageSnapshotStore.snapshotKey
                == "OmoUsage.dashboardSnapshot.v1"
        )
        let storedData = keyValueStore.data(
            forKey: UbiquitousUsageSnapshotStore.snapshotKey
        )
        #expect(keyValueStore.setCount == 1)
        #expect(keyValueStore.synchronizeCount == 1)
        #expect(storedData == expectedData)
    }

    @Test
    func rejectsOversizedV3Strings() {
        let planName = String(repeating: "x", count: 257)
        let data = Data(
            """
            {
              "version": 3,
              "providers": [{
                "provider": "codex",
                "accountOrdinal": 1,
                "planName": "\(planName)",
                "groups": [],
                "availability": "available",
                "lastSuccessfulAt": null
              }],
              "generatedAt": 1786867200000,
              "lastRefreshAttemptAt": 1786867200000
            }
            """.utf8
        )

        #expect(throws: UsageSnapshotCodecError.invalidPayload) {
            try UsageSnapshotCodec.decode(data)
        }
    }

    private func usage(
        provider: ProviderID = .codex,
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue,
        lastSuccessfulAt: Date? = nil,
        lastRefreshAttemptAt: Date? = nil,
        refreshFailure: ProviderRefreshFailure? = nil
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            accountID: accountID,
            accountLabel: accountLabel,
            planName: "Plus",
            groups: [
                UsageGroup(
                    id: "limits",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "weekly",
                            title: "Weekly",
                            period: .week,
                            percentRemaining: 75
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            lastSuccessfulAt: lastSuccessfulAt,
            lastRefreshAttemptAt: lastRefreshAttemptAt,
            refreshFailure: refreshFailure
        )
    }
}

private final class PrivacyRecordingKeyValueStore: UbiquitousKeyValueStoring {
    private var values: [String: Any] = [:]
    private(set) var setCount = 0
    private(set) var synchronizeCount = 0

    func set(_ value: Any?, forKey key: String) {
        setCount += 1
        values[key] = value
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }
}
