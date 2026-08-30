import Foundation
import Observation

enum UsageSnapshotCodecError: Error, Equatable {
    case unsupportedVersion(Int)
    case payloadTooLarge(Int)
    case invalidPayload
}

private struct UsageSnapshotVersion: Decodable {
    let version: Int
}

private struct LegacyUsageSnapshotPayload: Decodable {
    let version: Int
    let providers: [ProviderUsage]
    let refreshedAt: Date
}

private struct CloudSnapshotV3: Codable {
    let version: Int
    let providers: [CloudProviderUsage]
    let generatedAt: Date
    let lastRefreshAttemptAt: Date?
    let oldestDisplayedSuccessAt: Date?
}

private struct CloudProviderUsage: Codable {
    let provider: ProviderID
    let accountOrdinal: Int
    let planName: String
    let groups: [CloudUsageGroup]
    let availability: ProviderAvailability
    let lastSuccessfulAt: Date?

    init(_ usage: ProviderUsage, accountOrdinal: Int) {
        provider = usage.provider
        self.accountOrdinal = accountOrdinal
        planName = usage.planName
        groups = usage.groups.map(CloudUsageGroup.init)
        availability = usage.availability
        lastSuccessfulAt = usage.lastSuccessfulAt
    }

    func usage(sameProviderCount: Int) -> ProviderUsage {
        let accountID = AccountID(
            rawValue: String(
                format: "00000000-0000-0000-0000-%012d",
                accountOrdinal
            )
        )!
        return ProviderUsage(
            provider: provider,
            accountID: accountID,
            accountLabel: sameProviderCount > 1
                ? "Account \(accountOrdinal)"
                : AccountLabel.defaultValue,
            planName: planName,
            groups: groups.map(\.usage),
            availability: availability,
            lastSuccessfulAt: lastSuccessfulAt
        )
    }
}

private struct CloudUsageGroup: Codable {
    let id: String
    let title: String?
    let meters: [CloudUsageMeter]
    let creditText: String?

    init(_ group: UsageGroup) {
        id = group.id
        title = group.title
        meters = group.meters.map(CloudUsageMeter.init)
        creditText = group.creditText
    }

    var usage: UsageGroup {
        UsageGroup(
            id: id,
            title: title,
            meters: meters.map(\.usage),
            creditText: creditText
        )
    }
}

private struct CloudUsageMeter: Codable {
    let id: String
    let title: String
    let period: UsagePeriod
    let percentRemaining: Int
    let resetsAt: Date?
    let resetText: String?
    let showsMenuBarBadge: Bool

    init(_ meter: UsageMeter) {
        id = meter.id
        title = meter.title
        period = meter.period
        percentRemaining = meter.percentRemaining
        resetsAt = meter.resetsAt
        resetText = meter.resetText
        showsMenuBarBadge = meter.showsMenuBarBadge
    }

    var usage: UsageMeter {
        UsageMeter(
            id: id,
            title: title,
            period: period,
            percentRemaining: percentRemaining,
            resetsAt: resetsAt,
            resetText: resetText,
            showsMenuBarBadge: showsMenuBarBadge
        )
    }
}

enum UsageSnapshotCodec {
    static let currentVersion = 3
    static let maximumPayloadBytes = 256 * 1_024
    private static let minimumTimestamp = 946_684_800.0
    private static let maximumTimestamp = 4_102_444_800.0

    static func encode(_ snapshot: DashboardSnapshot) throws -> Data {
        try validate(snapshot)
        var ordinals: [ProviderID: Int] = [:]
        let providers = snapshot.providers.map { usage in
            let ordinal = ordinals[usage.provider, default: 0] + 1
            ordinals[usage.provider] = ordinal
            return CloudProviderUsage(usage, accountOrdinal: ordinal)
        }
        let payload = CloudSnapshotV3(
            version: currentVersion,
            providers: providers,
            generatedAt: snapshot.generatedAt,
            lastRefreshAttemptAt: snapshot.lastRefreshAttemptAt,
            oldestDisplayedSuccessAt: snapshot.oldestDisplayedSuccessAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= maximumPayloadBytes else {
            throw UsageSnapshotCodecError.payloadTooLarge(data.count)
        }
        return data
    }

    static func decode(_ data: Data) throws -> DashboardSnapshot {
        guard data.count <= maximumPayloadBytes else {
            throw UsageSnapshotCodecError.payloadTooLarge(data.count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let version = try decoder.decode(
            UsageSnapshotVersion.self,
            from: data
        ).version
        let snapshot: DashboardSnapshot
        switch version {
        case 1, 2:
            let payload = try decoder.decode(
                LegacyUsageSnapshotPayload.self,
                from: data
            )
            snapshot = DashboardSnapshot(
                providers: payload.providers,
                generatedAt: payload.refreshedAt,
                lastRefreshAttemptAt: payload.refreshedAt,
                oldestDisplayedSuccessAt: payload.providers
                    .compactMap(\.lastSuccessfulAt)
                    .min()
            )
        case currentVersion:
            let payload = try decoder.decode(
                CloudSnapshotV3.self,
                from: data
            )
            guard hasValidOrdinals(payload.providers) else {
                throw UsageSnapshotCodecError.invalidPayload
            }
            let counts = Dictionary(
                grouping: payload.providers,
                by: \.provider
            ).mapValues(\.count)
            snapshot = DashboardSnapshot(
                providers: payload.providers.map {
                    $0.usage(
                        sameProviderCount: counts[$0.provider, default: 0]
                    )
                },
                generatedAt: payload.generatedAt,
                lastRefreshAttemptAt: payload.lastRefreshAttemptAt,
                oldestDisplayedSuccessAt:
                    payload.oldestDisplayedSuccessAt
            )
        default:
            throw UsageSnapshotCodecError.unsupportedVersion(version)
        }
        try validate(snapshot)
        return snapshot
    }

    private static func hasValidOrdinals(
        _ providers: [CloudProviderUsage]
    ) -> Bool {
        var nextOrdinals: [ProviderID: Int] = [:]
        for provider in providers {
            let expected = nextOrdinals[provider.provider, default: 0] + 1
            guard provider.accountOrdinal == expected else { return false }
            nextOrdinals[provider.provider] = expected
        }
        return true
    }

    private static func validate(
        _ snapshot: DashboardSnapshot
    ) throws {
        let providers = snapshot.providers
        guard
            isSafeDate(snapshot.generatedAt),
            isSafeFreshnessDate(
                snapshot.lastRefreshAttemptAt,
                generatedAt: snapshot.generatedAt
            ),
            isSafeFreshnessDate(
                snapshot.oldestDisplayedSuccessAt,
                generatedAt: snapshot.generatedAt
            ),
            snapshot.oldestDisplayedSuccessAt
                == providers.compactMap(\.lastSuccessfulAt).min()
        else {
            throw UsageSnapshotCodecError.invalidPayload
        }
        guard providers.count <= 64 else {
            throw UsageSnapshotCodecError.invalidPayload
        }
        guard
            Set(providers.map(\.accountProviderID)).count
                == providers.count
        else {
            throw UsageSnapshotCodecError.invalidPayload
        }

        for provider in providers {
            guard
                provider.accountLabel.count <= AccountLabel.maximumLength,
                provider.accountLabel
                    == AccountLabel.sanitized(provider.accountLabel),
                provider.planName.count <= 256,
                isSafeFreshnessDate(
                    provider.lastSuccessfulAt,
                    generatedAt: snapshot.generatedAt
                ),
                isSafeFreshnessDate(
                    provider.lastRefreshAttemptAt,
                    generatedAt: snapshot.generatedAt
                ),
                recordsAttemptAfterSuccess(provider)
            else {
                throw UsageSnapshotCodecError.invalidPayload
            }
            guard provider.groups.count <= 64 else {
                throw UsageSnapshotCodecError.invalidPayload
            }
            for group in provider.groups {
                guard
                    group.id.count <= 256,
                    group.title?.count ?? 0 <= 512,
                    group.creditText?.count ?? 0 <= 1_024,
                    group.meters.count <= 64
                else {
                    throw UsageSnapshotCodecError.invalidPayload
                }
                for meter in group.meters {
                    guard
                        meter.id.count <= 256,
                        meter.title.count <= 512,
                        meter.resetText?.count ?? 0 <= 512,
                        (0...100).contains(meter.percentRemaining),
                        isSafeDate(meter.resetsAt)
                    else {
                        throw UsageSnapshotCodecError.invalidPayload
                    }
                }
            }
        }
    }

    /// A refresh attempt can never be older than the success it reports.
    private static func recordsAttemptAfterSuccess(
        _ provider: ProviderUsage
    ) -> Bool {
        guard
            let successAt = provider.lastSuccessfulAt,
            let attemptAt = provider.lastRefreshAttemptAt
        else {
            return true
        }
        return successAt <= attemptAt
    }

    private static func isSafeFreshnessDate(
        _ date: Date?,
        generatedAt: Date
    ) -> Bool {
        guard let date else { return true }
        return isSafeDate(date) && date <= generatedAt
    }

    private static func isSafeDate(_ date: Date?) -> Bool {
        guard let date else { return true }
        let timestamp = date.timeIntervalSince1970
        return timestamp.isFinite
            && (minimumTimestamp...maximumTimestamp).contains(timestamp)
    }
}

protocol UbiquitousKeyValueStoring: AnyObject {
    func set(_ value: Any?, forKey key: String)
    func data(forKey key: String) -> Data?
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {}

enum UsageSnapshotStoreError: Error, Equatable {
    case synchronizationFailed
}

@MainActor
final class UbiquitousUsageSnapshotStore {
    static let snapshotKey = "OmoUsage.dashboardSnapshot.v1"

    private let store: any UbiquitousKeyValueStoring

    init(
        store: any UbiquitousKeyValueStoring =
            NSUbiquitousKeyValueStore.default
    ) {
        self.store = store
    }

    func publish(_ snapshot: DashboardSnapshot) throws {
        let data = try UsageSnapshotCodec.encode(snapshot)
        guard store.data(forKey: Self.snapshotKey) != data else {
            return
        }
        store.set(data, forKey: Self.snapshotKey)
        guard store.synchronize() else {
            throw UsageSnapshotStoreError.synchronizationFailed
        }
    }

    func load() throws -> DashboardSnapshot? {
        guard store.synchronize() else {
            throw UsageSnapshotStoreError.synchronizationFailed
        }
        guard let data = store.data(forKey: Self.snapshotKey) else {
            return nil
        }
        return try UsageSnapshotCodec.decode(data)
    }
}

enum MobileUsageLoadState: Equatable {
    case loading
    case content
    case empty
    case failed
}

@Observable
@MainActor
final class MobileUsageViewModel {
    private let loadSnapshot: @MainActor () throws -> DashboardSnapshot?
    private let fixtureSnapshot: DashboardSnapshot?

    private(set) var snapshot: DashboardSnapshot?
    private(set) var loadState: MobileUsageLoadState = .loading

    init(
        loadSnapshot: @escaping @MainActor (
        ) throws -> DashboardSnapshot?,
        fixtureSnapshot: DashboardSnapshot? = nil
    ) {
        self.loadSnapshot = loadSnapshot
        self.fixtureSnapshot = fixtureSnapshot
    }

    func reload() {
        loadState = .loading
        do {
            if let fixtureSnapshot {
                snapshot = fixtureSnapshot
            } else {
                snapshot = try loadSnapshot()
            }
            loadState = snapshot?.providers.isEmpty == false
                ? .content
                : .empty
        } catch {
            loadState = .failed
        }
    }
}
