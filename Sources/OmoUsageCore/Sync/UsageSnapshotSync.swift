import Foundation
import Observation

public enum UsageSnapshotCodecError: Error, Equatable {
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

private struct CloudSnapshot: Codable {
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
    let lastRefreshAttemptAt: Date?
    let refreshFailure: ProviderRefreshFailure?

    init(_ usage: ProviderUsage, accountOrdinal: Int) {
        provider = usage.provider
        self.accountOrdinal = accountOrdinal
        planName = usage.planName
        groups = usage.groups.map(CloudUsageGroup.init)
        availability = usage.availability
        lastSuccessfulAt = usage.lastSuccessfulAt
        lastRefreshAttemptAt = usage.lastRefreshAttemptAt
        refreshFailure = usage.refreshFailure
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
            lastSuccessfulAt: lastSuccessfulAt,
            lastRefreshAttemptAt: lastRefreshAttemptAt,
            refreshFailure: refreshFailure
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
    let metric: UsageMetric
    let resetsAt: Date?
    let resetText: String?
    let showsMenuBarBadge: Bool

    init(_ meter: UsageMeter) {
        id = meter.id
        title = meter.title
        period = meter.period
        metric = meter.metric
        resetsAt = meter.resetsAt
        resetText = meter.resetText
        showsMenuBarBadge = meter.showsMenuBarBadge
    }

    var usage: UsageMeter {
        UsageMeter(
            id: id,
            title: title,
            period: period,
            metric: metric,
            resetsAt: resetsAt,
            resetText: resetText,
            showsMenuBarBadge: showsMenuBarBadge
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, period, metric, percentRemaining
        case resetsAt, resetText, showsMenuBarBadge
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        period = try container.decode(UsagePeriod.self, forKey: .period)
        metric = try container.decodeIfPresent(
            UsageMetric.self,
            forKey: .metric
        ) ?? .quotaRemaining(
            percent: try container.decode(Int.self, forKey: .percentRemaining)
        )
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        resetText = try container.decodeIfPresent(String.self, forKey: .resetText)
        showsMenuBarBadge = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsMenuBarBadge
        ) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(period, forKey: .period)
        try container.encode(metric, forKey: .metric)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(resetText, forKey: .resetText)
        try container.encode(showsMenuBarBadge, forKey: .showsMenuBarBadge)
    }
}

public enum UsageSnapshotCodec {
    public static let currentVersion = 4
    public static let maximumPayloadBytes = 256 * 1_024
    private static let minimumTimestamp = 946_684_800.0
    private static let maximumTimestamp = 4_102_444_800.0

    public static func encode(_ snapshot: DashboardSnapshot) throws -> Data {
        try validate(snapshot)
        var ordinals: [ProviderID: Int] = [:]
        let providers = snapshot.providers.map { usage in
            let ordinal = ordinals[usage.provider, default: 0] + 1
            ordinals[usage.provider] = ordinal
            return CloudProviderUsage(usage, accountOrdinal: ordinal)
        }
        let payload = CloudSnapshot(
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

    public static func decode(_ data: Data) throws -> DashboardSnapshot {
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
        case 3, currentVersion:
            let payload = try decoder.decode(
                CloudSnapshot.self,
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
                        meter.metric.isValid,
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

public protocol UbiquitousKeyValueStoring: AnyObject {
    func set(_ value: Any?, forKey key: String)
    func data(forKey key: String) -> Data?
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousKeyValueStoring {}

public enum UsageSnapshotStoreError: Error, Equatable {
    case synchronizationFailed
}

@MainActor
public final class UbiquitousUsageSnapshotStore {
    public static let snapshotKey = "OmoUsage.dashboardSnapshot.v1"

    private let store: any UbiquitousKeyValueStoring

    public init(
        store: any UbiquitousKeyValueStoring =
            NSUbiquitousKeyValueStore.default
    ) {
        self.store = store
    }

    public func publish(_ snapshot: DashboardSnapshot) throws {
        let data = try UsageSnapshotCodec.encode(snapshot)
        guard store.data(forKey: Self.snapshotKey) != data else {
            return
        }
        store.set(data, forKey: Self.snapshotKey)
        guard store.synchronize() else {
            throw UsageSnapshotStoreError.synchronizationFailed
        }
    }

    public func load() throws -> DashboardSnapshot? {
        guard store.synchronize() else {
            throw UsageSnapshotStoreError.synchronizationFailed
        }
        guard let data = store.data(forKey: Self.snapshotKey) else {
            return nil
        }
        return try UsageSnapshotCodec.decode(data)
    }
}

public enum MobileUsageLoadState: Equatable {
    case loading
    case content
    case empty
    case failed
}

/// How old the displayed snapshot is, measured from the Mac's last check.
public enum MobileSnapshotAge: String, Equatable, Sendable {
    case fresh
    case stale
}

/// The single deterministic model for what mobile may claim about its data:
/// when the Mac last checked, whether that snapshot has aged out, and whether
/// the latest iCloud read failed. Provider staleness is a separate fact; it
/// reports a failed provider refresh, never the age of this snapshot.
public struct MobileFreshnessPresentation: Equatable, Sendable {
    /// A snapshot reads as out of date once it reaches this age.
    public static let staleThreshold: TimeInterval = 15 * 60

    public let macLastCheckedAt: Date
    public let age: MobileSnapshotAge
    public let hasSyncIssue: Bool

    public var isStale: Bool { age == .stale }

    public init(
        snapshot: DashboardSnapshot,
        now: Date,
        hasSyncIssue: Bool
    ) {
        let macLastCheckedAt = snapshot.refreshedAt
        self.macLastCheckedAt = macLastCheckedAt
        age = now.timeIntervalSince(macLastCheckedAt) >= Self.staleThreshold
            ? .stale
            : .fresh
        self.hasSyncIssue = hasSyncIssue
    }

    /// The visible header line. It names the Mac's own check time so a fresh
    /// pull is never mistaken for a fresh provider reading.
    @MainActor
    public func statusText(
        _ localization: LocalizationContext,
        clockText: String
    ) -> String {
        localization.format(.macLastChecked, clockText)
    }

    /// VoiceOver hears the check time first, then any aged-out or sync-issue
    /// qualification, so the state never depends on the visible badge color.
    @MainActor
    public func accessibilityLabel(
        _ localization: LocalizationContext,
        clockText: String
    ) -> String {
        var parts = [statusText(localization, clockText: clockText)]
        if isStale {
            parts.append(localization.text(.mobileSnapshotOutOfDate))
        }
        if hasSyncIssue {
            parts.append(
                localization.text(.mobileRetainedAfterSyncFailure)
            )
        }
        return parts.joined(separator: ", ")
    }
}

/// Fixture-only knobs that let visual QA render the snapshot-age boundary and
/// the retained sync-failure state without waiting on wall-clock time.
public enum MobileFixtureEnvironment {
    public static let ageKey = "OMO_USAGE_FIXTURE_AGE_SECONDS"
    public static let syncFailureKey = "OMO_USAGE_FIXTURE_SYNC_FAILURE"
    private static let maximumAgeSeconds: TimeInterval = 86_400

    public static func snapshotAgeSeconds(
        _ environment: [String: String]
    ) -> TimeInterval {
        guard
            let raw = environment[ageKey],
            let seconds = TimeInterval(raw),
            seconds.isFinite
        else {
            return 0
        }
        return min(max(0, seconds), maximumAgeSeconds)
    }

    public static func simulatesSyncFailure(
        _ environment: [String: String]
    ) -> Bool {
        environment[syncFailureKey] == "1"
    }
}

@Observable
@MainActor
public final class MobileUsageViewModel {
    private let loadSnapshot: @MainActor () throws -> DashboardSnapshot?
    private let fixtureSnapshot: DashboardSnapshot?
    private let simulatesSyncFailure: Bool
    private let now: @MainActor () -> Date

    public private(set) var snapshot: DashboardSnapshot?
    public private(set) var loadState: MobileUsageLoadState = .loading
    public private(set) var freshnessPresentation: MobileFreshnessPresentation?

    public init(
        loadSnapshot: @escaping @MainActor (
        ) throws -> DashboardSnapshot?,
        fixtureSnapshot: DashboardSnapshot? = nil,
        simulatesSyncFailure: Bool = false,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.loadSnapshot = loadSnapshot
        self.fixtureSnapshot = fixtureSnapshot
        self.simulatesSyncFailure = simulatesSyncFailure
        self.now = now
    }

    /// Reads the published snapshot once. A failed read keeps the last good
    /// snapshot and its timestamps exactly as they were; only a newly
    /// published snapshot may move the Mac and provider times.
    public func reload() {
        loadState = .loading
        do {
            if let fixtureSnapshot {
                snapshot = fixtureSnapshot
                if simulatesSyncFailure {
                    throw UsageSnapshotStoreError.synchronizationFailed
                }
            } else {
                snapshot = try loadSnapshot()
            }
            loadState = snapshot?.providers.isEmpty == false
                ? .content
                : .empty
        } catch {
            loadState = .failed
        }
        freshnessPresentation = snapshot.map {
            MobileFreshnessPresentation(
                snapshot: $0,
                now: now(),
                hasSyncIssue: loadState == .failed
            )
        }
    }
}
