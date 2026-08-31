import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct SnapshotFreshnessSchemaTests {
    private let generatedAt = Date(timeIntervalSince1970: 1_786_867_200)

    @Test
    func v3RoundTripPreservesIndependentFreshnessTimestamps() throws {
        let attemptAt = generatedAt.addingTimeInterval(-5)
        let oldestSuccessAt = generatedAt.addingTimeInterval(-120)
        let latestSuccessAt = generatedAt.addingTimeInterval(-30)
        let snapshot = DashboardSnapshot(
            providers: [
                usage(
                    provider: .codex,
                    lastSuccessfulAt: oldestSuccessAt
                ),
                usage(
                    provider: .claude,
                    lastSuccessfulAt: latestSuccessAt
                )
            ],
            generatedAt: generatedAt,
            lastRefreshAttemptAt: attemptAt,
            oldestDisplayedSuccessAt: oldestSuccessAt
        )

        let encoded = try UsageSnapshotCodec.encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let providers = try #require(
            object["providers"] as? [[String: Any]]
        )
        let decoded = try UsageSnapshotCodec.decode(encoded)

        #expect(object["version"] as? Int == 4)
        #expect(object["generatedAt"] != nil)
        #expect(object["lastRefreshAttemptAt"] != nil)
        #expect(object["oldestDisplayedSuccessAt"] != nil)
        #expect(object["refreshedAt"] == nil)
        #expect(providers.allSatisfy { $0["lastSuccessfulAt"] != nil })
        #expect(providers.allSatisfy { $0["updatedAt"] == nil })
        #expect(decoded == snapshot)
    }

    @Test(arguments: [1, 2])
    func migratesLegacySnapshotFreshnessSemantics(version: Int) throws {
        let refreshedAt = generatedAt.addingTimeInterval(-10)
        let oldestSuccessAt = generatedAt.addingTimeInterval(-300)
        let latestSuccessAt = generatedAt.addingTimeInterval(-60)
        let data = legacyPayload(
            version: version,
            refreshedAt: refreshedAt,
            providerSuccesses: [oldestSuccessAt, latestSuccessAt]
        )

        let snapshot = try UsageSnapshotCodec.decode(data)

        #expect(snapshot.generatedAt == refreshedAt)
        #expect(snapshot.lastRefreshAttemptAt == refreshedAt)
        #expect(snapshot.oldestDisplayedSuccessAt == oldestSuccessAt)
        #expect(snapshot.providers.map(\.lastSuccessfulAt) == [
            oldestSuccessAt,
            latestSuccessAt
        ])
    }

    @Test
    func migratesLegacySnapshotWithoutDisplayedSuccessAsUnknown() throws {
        let data = legacyPayload(
            version: 2,
            refreshedAt: generatedAt,
            providerSuccesses: [nil]
        )

        let snapshot = try UsageSnapshotCodec.decode(data)

        #expect(snapshot.generatedAt == generatedAt)
        #expect(snapshot.lastRefreshAttemptAt == generatedAt)
        #expect(snapshot.oldestDisplayedSuccessAt == nil)
        #expect(snapshot.providers.first?.lastSuccessfulAt == nil)
    }

    @Test
    func reencodesLegacyPayloadAsV3Fields() throws {
        let data = legacyPayload(
            version: 1,
            refreshedAt: generatedAt,
            providerSuccesses: [generatedAt.addingTimeInterval(-60)]
        )

        let migrated = try UsageSnapshotCodec.encode(
            UsageSnapshotCodec.decode(data)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: migrated) as? [String: Any]
        )
        let provider = try #require(
            (object["providers"] as? [[String: Any]])?.first
        )

        #expect(object["version"] as? Int == 4)
        #expect(object["generatedAt"] != nil)
        #expect(object["lastRefreshAttemptAt"] != nil)
        #expect(object["oldestDisplayedSuccessAt"] != nil)
        #expect(object["refreshedAt"] == nil)
        #expect(provider["accountOrdinal"] as? Int == 1)
        #expect(provider["accountID"] == nil)
        #expect(provider["accountLabel"] == nil)
        #expect(provider["lastSuccessfulAt"] != nil)
        #expect(provider["updatedAt"] == nil)
    }

    @Test(arguments: [
        "generatedAt",
        "lastRefreshAttemptAt",
        "oldestDisplayedSuccessAt",
        "lastSuccessfulAt"
    ])
    func rejectsOutOfRangeV3FreshnessDates(field: String) {
        let data = v3Payload(overriding: field, with: 4_102_444_801_000)

        #expect(throws: UsageSnapshotCodecError.invalidPayload) {
            try UsageSnapshotCodec.decode(data)
        }
    }

    @Test(arguments: [
        "lastRefreshAttemptAt",
        "oldestDisplayedSuccessAt",
        "lastSuccessfulAt"
    ])
    func rejectsFreshnessDatesAfterSnapshotGeneration(field: String) {
        let future = (generatedAt.timeIntervalSince1970 + 1) * 1_000
        let data = v3Payload(overriding: field, with: future)

        #expect(throws: UsageSnapshotCodecError.invalidPayload) {
            try UsageSnapshotCodec.decode(data)
        }
    }

    private func usage(
        provider: ProviderID,
        lastSuccessfulAt: Date?
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            planName: "",
            groups: [],
            availability: .available,
            lastSuccessfulAt: lastSuccessfulAt
        )
    }

    private func legacyPayload(
        version: Int,
        refreshedAt: Date,
        providerSuccesses: [Date?]
    ) -> Data {
        let providers = providerSuccesses.enumerated().map { index, date in
            let provider = index == 0 ? "codex" : "claude"
            let updatedAt = date.map {
                String($0.timeIntervalSince1970 * 1_000)
            } ?? "null"
            return """
            {
              "provider": "\(provider)",
              "planName": "",
              "groups": [],
              "availability": "available",
              "updatedAt": \(updatedAt)
            }
            """
        }
        return Data(
            """
            {
              "version": \(version),
              "providers": [\(providers.joined(separator: ","))],
              "refreshedAt": \(refreshedAt.timeIntervalSince1970 * 1_000)
            }
            """.utf8
        )
    }

    private func v3Payload(
        overriding field: String,
        with timestamp: Double
    ) -> Data {
        let generated = generatedAt.timeIntervalSince1970 * 1_000
        var snapshotFields: [String: Double] = [
            "generatedAt": generated,
            "lastRefreshAttemptAt": generated - 1_000,
            "oldestDisplayedSuccessAt": generated - 2_000
        ]
        var providerSuccess = generated - 2_000
        if field == "lastSuccessfulAt" {
            providerSuccess = timestamp
        } else {
            snapshotFields[field] = timestamp
        }
        return Data(
            """
            {
              "version": 3,
              "providers": [{
                "provider": "codex",
                "accountOrdinal": 1,
                "planName": "",
                "groups": [],
                "availability": "available",
                "lastSuccessfulAt": \(providerSuccess)
              }],
              "generatedAt": \(snapshotFields["generatedAt"]!),
              "lastRefreshAttemptAt": \(snapshotFields["lastRefreshAttemptAt"]!),
              "oldestDisplayedSuccessAt": \(snapshotFields["oldestDisplayedSuccessAt"]!)
            }
            """.utf8
        )
    }
}
