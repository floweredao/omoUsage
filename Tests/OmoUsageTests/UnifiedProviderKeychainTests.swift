import Foundation
import Security
import Testing
@testable import OmoUsage

@Suite(.serialized)
struct UnifiedProviderKeychainTests {
    private static let unifiedService = "com.omo.usage.qa.unified"
    private static let legacyService = "com.omo.usage.qa.legacy"

    /// One fresh cache per test models one process; stores sharing a fake
    /// API in a test share it just as live instances share `.shared`.
    private let cache = UnifiedKeychainCache()

    private func makeStore(
        api: UnifiedKeychainFakeAPI = UnifiedKeychainFakeAPI()
    ) -> UnifiedProviderKeychain {
        UnifiedProviderKeychain(
            api: api,
            service: Self.unifiedService,
            legacyServices: [Self.legacyService],
            cache: cache
        )
    }

    private func seedUnified(
        _ api: UnifiedKeychainFakeAPI,
        _ services: [String: [String: String]]
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ["v": 1, "services": services],
            options: [.sortedKeys]
        )
        api.seed(
            service: Self.unifiedService,
            account: "all",
            value: String(decoding: data, as: UTF8.self)
        )
    }

    @Test
    func manyInstancesAndReadsIssueOneDataRead() throws {
        let api = UnifiedKeychainFakeAPI()
        try seedUnified(api, ["svc.a": ["one": "alpha"]])
        let stores = (0..<3).map { _ in makeStore(api: api) }

        for store in stores {
            for _ in 0..<10 {
                #expect(
                    try store.value(service: "svc.a", account: "one")
                        == "alpha"
                )
            }
        }
        #expect(api.dataReadCount == 1)
    }

    @Test
    func absentItemIsCachedAfterOneRead() throws {
        let api = UnifiedKeychainFakeAPI()
        let first = makeStore(api: api)
        let second = makeStore(api: api)

        #expect(try first.value(service: "svc.a", account: "one") == nil)
        #expect(try second.value(service: "svc.a", account: "one") == nil)
        #expect(api.dataReadCount == 1)
    }

    @Test
    func setAfterCachedReadUpdatesWithoutReadingBack() throws {
        let api = UnifiedKeychainFakeAPI()
        try seedUnified(api, ["svc.a": ["one": "alpha"]])
        let store = makeStore(api: api)
        #expect(try store.value(service: "svc.a", account: "one") == "alpha")
        let readsBefore = api.copyCount

        try store.set("beta", service: "svc.a", account: "one")

        #expect(api.copyCount == readsBefore)
        #expect(api.updateCount == 1)
        #expect(api.addCount == 0)
        #expect(try makeStore(api: api).value(service: "svc.a", account: "one")
            == "beta")
        #expect(api.copyCount == readsBefore)
    }

    @Test
    func deniedReadLatchesUntilAuthorizationReset() throws {
        let api = UnifiedKeychainFakeAPI()
        try seedUnified(api, ["svc.a": ["one": "alpha"]])
        api.dataReadStatus = errSecAuthFailed
        let store = makeStore(api: api)

        #expect(throws: KeychainReadError(status: errSecAuthFailed)) {
            try store.value(service: "svc.a", account: "one")
        }
        let copiesAfterDenial = api.copyCount
        #expect(throws: KeychainReadError(status: errSecAuthFailed)) {
            try makeStore(api: api).value(service: "svc.a", account: "one")
        }
        #expect(throws: KeychainReadError(status: errSecAuthFailed)) {
            try store.set("beta", service: "svc.a", account: "one")
        }
        #expect(throws: KeychainReadError(status: errSecAuthFailed)) {
            try store.remove(service: "svc.a", account: "one")
        }
        #expect(api.copyCount == copiesAfterDenial)
        #expect(api.updateCount + api.addCount + api.deleteCount == 0)

        api.dataReadStatus = nil
        store.resetAuthorization()
        #expect(try store.value(service: "svc.a", account: "one") == "alpha")
        #expect(try store.value(service: "svc.a", account: "one") == "alpha")
        #expect(api.copyCount == copiesAfterDenial + 1)
    }

    @Test
    func failedWriteKeepsTheCachedPayload() throws {
        let api = UnifiedKeychainFakeAPI()
        try seedUnified(api, ["svc.a": ["one": "alpha"]])
        let store = makeStore(api: api)
        #expect(try store.value(service: "svc.a", account: "one") == "alpha")

        api.writeStatus = errSecIO
        #expect(throws: KeychainReadError(status: errSecIO)) {
            try store.set("beta", service: "svc.a", account: "one")
        }
        api.writeStatus = nil
        let readsBefore = api.copyCount

        #expect(try store.value(service: "svc.a", account: "one") == "alpha")
        #expect(api.copyCount == readsBefore)
    }

    @Test
    func cachesAreKeyedByTheUnifiedItem() throws {
        let api = UnifiedKeychainFakeAPI()
        try seedUnified(api, ["svc.a": ["one": "alpha"]])
        let other = UnifiedProviderKeychain(
            api: api,
            service: Self.unifiedService + ".other",
            legacyServices: [],
            cache: cache
        )
        #expect(try makeStore(api: api).value(service: "svc.a", account: "one")
            == "alpha")
        #expect(try other.value(service: "svc.a", account: "one") == nil)
        #expect(api.dataReadCount == 2)
    }

    @Test
    func secretsAcrossServicesShareOneItem() throws {
        let api = UnifiedKeychainFakeAPI()
        let store = makeStore(api: api)

        try store.set("alpha", service: "svc.a", account: "one")
        try store.set("beta", service: "svc.b", account: "two")
        try store.set(
            "staged",
            service: "svc.a",
            account: "one#staging#\(UUID().uuidString.lowercased())"
        )

        #expect(api.itemCount == 1)
        #expect(try store.value(service: "svc.a", account: "one") == "alpha")
        #expect(try store.value(service: "svc.b", account: "two") == "beta")
        #expect(
            try store.value(service: "svc.a", account: "one#staging#x")
                == nil
        )
    }

    @Test
    func lazyImportCopiesLegacyItemsIntoTheConsolidatedItem() throws {
        let api = UnifiedKeychainFakeAPI()
        api.seed(service: Self.legacyService, account: "a", value: "sa")
        api.seed(service: Self.legacyService, account: "b", value: "sb")
        let store = makeStore(api: api)

        #expect(try store.value(service: Self.legacyService, account: "a")
            == "sa")
        #expect(try store.value(service: Self.legacyService, account: "b")
            == "sb")
        #expect(api.itemCount == 3)
        #expect(
            api.items[Self.unifiedService + "\u{0}" + "all"] != nil
        )
        // The legacy originals remain for an older build; consolidation
        // wins from now on.
        api.seed(service: Self.legacyService, account: "a", value: "stale")
        #expect(try store.value(service: Self.legacyService, account: "a")
            == "sa")
    }

    @Test
    func existingConsolidatedItemSkipsImport() throws {
        let api = UnifiedKeychainFakeAPI()
        api.seed(service: Self.legacyService, account: "a", value: "legacy")
        let store = makeStore(api: api)
        try store.set("live", service: "svc.new", account: "x")
        api.seed(service: Self.legacyService, account: "c", value: "late")

        let fresh = makeStore(api: api)
        #expect(try fresh.value(service: Self.legacyService, account: "c")
            == nil)
        #expect(try fresh.value(service: "svc.new", account: "x") == "live")
    }

    @Test
    func failedEnumerationRetriesOnTheNextAccess() throws {
        let api = UnifiedKeychainFakeAPI()
        api.seed(service: Self.legacyService, account: "a", value: "sa")
        api.failEnumerations = true
        let store = makeStore(api: api)

        #expect(try store.value(service: Self.legacyService, account: "a")
            == nil)
        api.failEnumerations = false
        #expect(try store.value(service: Self.legacyService, account: "a")
            == "sa")
    }

    @Test
    func malformedConsolidatedItemFailsWithoutBeingOverwritten() throws {
        let api = UnifiedKeychainFakeAPI()
        let store = makeStore(api: api)
        api.seed(
            service: Self.unifiedService,
            account: "all",
            value: "not-json"
        )

        #expect(throws: KeychainReadError.self) {
            try store.value(service: "svc.a", account: "one")
        }
        #expect(throws: KeychainReadError.self) {
            try store.set("x", service: "svc.a", account: "one")
        }
        #expect(
            api.items[Self.unifiedService + "\u{0}" + "all"]
                == Data("not-json".utf8)
        )
    }

    @Test
    func removingTheLastKeyDeletesTheItem() throws {
        let api = UnifiedKeychainFakeAPI()
        let store = makeStore(api: api)
        try store.set("alpha", service: "svc.a", account: "one")
        #expect(api.itemCount == 1)

        try store.remove(service: "svc.a", account: "one")
        #expect(api.itemCount == 0)
        #expect(try store.value(service: "svc.a", account: "one") == nil)
    }

    @Test
    func concurrentWritesAcrossInstancesKeepEveryKey() throws {
        let api = UnifiedKeychainFakeAPI()
        let first = makeStore(api: api)
        let second = makeStore(api: api)

        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let store = index.isMultiple(of: 2) ? first : second
            try? store.set(
                "v\(index)",
                service: "svc.concurrent",
                account: "k\(index)"
            )
        }

        for index in 0..<20 {
            #expect(
                try first.value(
                    service: "svc.concurrent",
                    account: "k\(index)"
                ) == "v\(index)"
            )
        }
        #expect(api.itemCount == 1)
    }
}

/// In-memory SecurityItemAPI emulating the query shapes
/// UnifiedProviderKeychain and SecurityProviderKeychain issue: exact
/// service+account data reads, service-only matchAll enumerations, and
/// attribute-free existence probes.
private final class UnifiedKeychainFakeAPI: SecurityItemAPI,
    @unchecked Sendable
{
    private let lock = NSLock()
    private(set) var items: [String: Data] = [:]
    var failEnumerations = false
    /// Forces every exact data read to return this status.
    var dataReadStatus: OSStatus?
    /// Forces every add/update/delete to return this status.
    var writeStatus: OSStatus?
    private var counts = (copy: 0, dataRead: 0, add: 0, update: 0, delete: 0)

    var itemCount: Int {
        lock.withLock { items.count }
    }

    var copyCount: Int { lock.withLock { counts.copy } }
    var dataReadCount: Int { lock.withLock { counts.dataRead } }
    var addCount: Int { lock.withLock { counts.add } }
    var updateCount: Int { lock.withLock { counts.update } }
    var deleteCount: Int { lock.withLock { counts.delete } }

    func seed(service: String, account: String, value: String) {
        lock.withLock {
            items[entryKey(service, account)] = Data(value.utf8)
        }
    }

    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        lock.withLock {
            counts.copy += 1
            let wantsData =
                (query[kSecReturnData as String] as? Bool) == true
            if wantsData {
                counts.dataRead += 1
                if let dataReadStatus {
                    return SecurityItemCopyResult(
                        status: dataReadStatus,
                        value: nil
                    )
                }
            }
            guard let service =
                    query[kSecAttrService as String] as? String
            else {
                return SecurityItemCopyResult(
                    status: errSecItemNotFound,
                    value: nil
                )
            }
            if let account =
                query[kSecAttrAccount as String] as? String
            {
                guard let data = items[entryKey(service, account)] else {
                    return SecurityItemCopyResult(
                        status: errSecItemNotFound,
                        value: nil
                    )
                }
                return SecurityItemCopyResult(
                    status: errSecSuccess,
                    value: wantsData ? data : [:]
                )
            }
            let matches = items.filter {
                $0.key.hasPrefix(service + "\u{0}")
            }
            guard !matches.isEmpty else {
                return SecurityItemCopyResult(
                    status: errSecItemNotFound,
                    value: nil
                )
            }
            if failEnumerations {
                return SecurityItemCopyResult(
                    status: errSecInteractionNotAllowed,
                    value: nil
                )
            }
            let rows = matches.map { key, _ -> [String: Any] in
                [
                    kSecAttrService as String: service,
                    kSecAttrAccount as String:
                        String(key.dropFirst(service.count + 1)),
                    kSecValuePersistentRef as String: key.data(
                        using: .utf8
                    ) ?? Data(),
                ]
            }
            return SecurityItemCopyResult(
                status: errSecSuccess,
                value: rows
            )
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            counts.add += 1
            if let writeStatus { return writeStatus }
            guard let service =
                    attributes[kSecAttrService as String] as? String,
                  let account =
                    attributes[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data
            else { return errSecParam }
            items[entryKey(service, account)] = data
            return errSecSuccess
        }
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        lock.withLock {
            counts.update += 1
            if let writeStatus { return writeStatus }
            guard let service =
                    query[kSecAttrService as String] as? String,
                  let account =
                    query[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data
            else { return errSecParam }
            items[entryKey(service, account)] = data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            counts.delete += 1
            if let writeStatus { return writeStatus }
            guard let service =
                    query[kSecAttrService as String] as? String,
                  let account =
                    query[kSecAttrAccount as String] as? String
            else { return errSecParam }
            guard
                items.removeValue(forKey: entryKey(service, account))
                    != nil
            else { return errSecItemNotFound }
            return errSecSuccess
        }
    }

    private func entryKey(_ service: String, _ account: String) -> String {
        service + "\u{0}" + account
    }
}
