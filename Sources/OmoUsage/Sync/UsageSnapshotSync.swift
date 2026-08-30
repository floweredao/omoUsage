import Foundation
import Observation

enum UsageSnapshotCodecError: Error, Equatable {
    case unsupportedVersion(Int)
    case payloadTooLarge(Int)
    case invalidPayload
}

private struct UsageSnapshotPayload: Codable {
    let version: Int
    let providers: [ProviderUsage]
    let refreshedAt: Date
}

enum UsageSnapshotCodec {
    static let currentVersion = 2
    static let maximumPayloadBytes = 256 * 1_024
    private static let minimumTimestamp = 946_684_800.0
    private static let maximumTimestamp = 4_102_444_800.0

    static func encode(_ snapshot: DashboardSnapshot) throws -> Data {
        let payload = UsageSnapshotPayload(
            version: currentVersion,
            providers: snapshot.providers,
            refreshedAt: snapshot.refreshedAt
        )
        try validate(payload)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
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
        let payload = try decoder.decode(
            UsageSnapshotPayload.self,
            from: data
        )
        guard payload.version == 1 || payload.version == currentVersion else {
            throw UsageSnapshotCodecError.unsupportedVersion(
                payload.version
            )
        }
        try validate(payload)
        return DashboardSnapshot(
            providers: payload.providers,
            refreshedAt: payload.refreshedAt
        )
    }

    private static func validate(
        _ payload: UsageSnapshotPayload
    ) throws {
        let providers = payload.providers
        guard isSafeDate(payload.refreshedAt) else {
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
                isSafeDate(provider.updatedAt)
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
        store.set(
            try UsageSnapshotCodec.encode(snapshot),
            forKey: Self.snapshotKey
        )
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
