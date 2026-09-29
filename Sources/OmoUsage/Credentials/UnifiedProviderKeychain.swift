import Foundation
import LocalAuthentication
import Security

/// OmoUsage-owned secrets consolidated into ONE generic-password item.
/// Callers keep addressing by exact (service, account); only the storage
/// layout changes — a single versioned JSON map so the Keychain ACL has one
/// entry (one prompt per signing identity) for every provider/account.
/// Layout: {"v":1,"services":{"<service>":{"<account>":"<secret>"}}}
///
/// Process-wide memory of the consolidated item, keyed by its exact
/// (service, account) so QA/test items never share state. Every Keychain
/// data read of an item whose ACL does not trust this build can open
/// SecurityAgent, so the item is read at most once until a write replaces
/// the cached copy, and a denied read latches until an explicit user
/// action calls `UnifiedProviderKeychain.resetAuthorization()`.
/// All state is guarded by `UnifiedProviderKeychain`'s process-wide lock.
final class UnifiedKeychainCache: @unchecked Sendable {
    static let shared = UnifiedKeychainCache()

    fileprivate struct Entry {
        var loaded = false
        /// `nil` with `loaded` means the item is absent.
        var services: [String: [String: String]]?
        var denied: KeychainReadError?
        var importAttempted = false
    }

    fileprivate var entries: [String: Entry] = [:]

    init() {}
}

/// Every operation serializes through one process-wide lock: read-modify-
/// write must not lose keys across instances (each `live()` call builds a
/// new value of this type) or concurrent rotations in a fetch task group.
final class UnifiedProviderKeychain: ProviderKeychain, @unchecked Sendable {
    static let service = "com.omo.usage.unified-secrets.v1"
    static let account = "all"

    /// Services OmoUsage wrote per-item secrets under; unreadable legacy
    /// items stay orphaned for an older build or manual cleanup.
    static let defaultLegacyServices: [String] = [
        ProviderAPIKeyStore.serviceName,
        ClaudeKeychainAccessSession.mirrorService,
    ]

    private static let storeLock = NSLock()

    private let api: any SecurityItemAPI
    private let serviceName: String
    private let accountName: String
    private let legacyServices: [String]
    private let cache: UnifiedKeychainCache
    private let cacheKey: String

    init(
        api: any SecurityItemAPI = SecurityFrameworkItemAPI(),
        service: String = UnifiedProviderKeychain.service,
        account: String = UnifiedProviderKeychain.account,
        legacyServices: [String] = UnifiedProviderKeychain.defaultLegacyServices,
        cache: UnifiedKeychainCache = .shared
    ) {
        self.api = api
        self.serviceName = service
        self.accountName = account
        self.legacyServices = legacyServices
        self.cache = cache
        self.cacheKey = service + "\u{0}" + account
    }

    /// Statuses meaning the user or the ACL refused this build; retrying
    /// would only re-open SecurityAgent, so they latch until reset.
    private static let denialStatuses: Set<OSStatus> = [
        errSecAuthFailed,
        errSecUserCanceled,
        errSecInteractionNotAllowed,
        errSecNoAccessForItem,
    ]

    private var entry: UnifiedKeychainCache.Entry {
        get { cache.entries[cacheKey] ?? UnifiedKeychainCache.Entry() }
        set { cache.entries[cacheKey] = newValue }
    }

    /// Clears a denial latch and the cached payload so the next access
    /// re-reads the item exactly once. Call only from explicit user actions.
    func resetAuthorization() {
        Self.storeLock.withLock {
            entry.denied = nil
            entry.loaded = false
            entry.services = nil
        }
    }

    func value(service: String, account: String) throws -> String? {
        try Self.storeLock.withLock {
            try ensureImported()
            guard let services = try readPayload()?.services else {
                return nil
            }
            let value = services[service]?[account]
            return (value?.isEmpty == false) ? value : nil
        }
    }

    func set(_ value: String, service: String, account: String) throws {
        try Self.storeLock.withLock {
            try ensureImported()
            var services = (try readPayload()?.services) ?? [:]
            var entry = services[service] ?? [:]
            entry[account] = value
            services[service] = entry
            try write(services: services)
        }
    }

    func remove(service: String, account: String) throws {
        try Self.storeLock.withLock {
            try ensureImported()
            guard var services = try readPayload()?.services else {
                return
            }
            guard var entry = services[service] else { return }
            entry.removeValue(forKey: account)
            if entry.isEmpty {
                services.removeValue(forKey: service)
            } else {
                services[service] = entry
            }
            try write(services: services)
        }
    }

    /// One lazy import of legacy per-item secrets. Retryable while nothing
    /// merged yet: an enumeration failure leaves `importAttempted` false
    /// so a later access can converge. A consolidated item with data wins
    /// over any legacy leftovers. The attempt is recorded process-wide.
    private func ensureImported() throws {
        guard !entry.importAttempted else { return }
        if (try readPayload()) != nil {
            entry.importAttempted = true
            return
        }
        var merged: [String: [String: String]] = [:]
        var sawLegacyData = false
        var enumerationFailed = false
        for service in legacyServices {
            // matchAll + returnData is errSecParam: the API delivers rows
            // only when a ref is requested alongside, so we ask for a
            // persistent ref, then re-read each item by exact match.
            let query: [String: Any] = [
                key(kSecClass): key(kSecClassGenericPassword),
                key(kSecAttrService): service,
                key(kSecReturnAttributes): true,
                key(kSecReturnPersistentRef): true,
                key(kSecMatchLimit): key(kSecMatchLimitAll),
                key(kSecUseAuthenticationContext): noninteractiveContext(),
                SecurityKeychainAuthenticationUIPolicy.queryKey:
                    SecurityKeychainAuthenticationUIPolicy.failValue,
            ]
            let result = api.copyMatching(query)
            switch result.status {
            case errSecSuccess:
                guard let items = result.value as? [[String: Any]] else {
                    enumerationFailed = true
                    continue
                }
                for item in items {
                    guard
                        let account =
                            item[key(kSecAttrAccount)] as? String,
                        let secret = try? legacyValue(
                            service: service,
                            account: account
                        ),
                        !secret.isEmpty
                    else { continue }
                    var entry = merged[service] ?? [:]
                    entry[account] = secret
                    merged[service] = entry
                    sawLegacyData = true
                }
            case errSecItemNotFound:
                continue
            default:
                enumerationFailed = true
            }
        }
        entry.importAttempted = !enumerationFailed
        guard sawLegacyData else { return }
        try write(services: merged)
    }

    private func legacyValue(
        service: String,
        account: String
    ) throws -> String? {
        let query: [String: Any] = [
            key(kSecClass): key(kSecClassGenericPassword),
            key(kSecAttrService): service,
            key(kSecAttrAccount): account,
            key(kSecReturnData): true,
            key(kSecMatchLimit): key(kSecMatchLimitOne),
            key(kSecUseAuthenticationContext): noninteractiveContext(),
            SecurityKeychainAuthenticationUIPolicy.queryKey:
                SecurityKeychainAuthenticationUIPolicy.failValue,
        ]
        let result = api.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess,
              let data = result.value as? Data,
              let text = String(data: data, encoding: .utf8)
        else {
            throw KeychainReadError(
                status: result.status == errSecSuccess
                    ? errSecDecode
                    : result.status
            )
        }
        return text
    }

    private struct Payload {
        let services: [String: [String: String]]
    }

    /// A malformed consolidated item is a typed failure, never silently
    /// overwritten. Served from the process-wide cache once loaded; a
    /// latched denial throws without touching the Keychain.
    private func readPayload() throws -> Payload? {
        let cached = entry
        if let denied = cached.denied { throw denied }
        if cached.loaded {
            return cached.services.map(Payload.init(services:))
        }
        let query: [String: Any] = [
            key(kSecClass): key(kSecClassGenericPassword),
            key(kSecAttrService): serviceName,
            key(kSecAttrAccount): accountName,
            key(kSecReturnData): true,
            key(kSecMatchLimit): key(kSecMatchLimitOne),
            key(kSecUseAuthenticationContext): noninteractiveContext(),
            SecurityKeychainAuthenticationUIPolicy.queryKey:
                SecurityKeychainAuthenticationUIPolicy.failValue,
        ]
        let result = api.copyMatching(query)
        if result.status == errSecItemNotFound {
            entry.loaded = true
            entry.services = nil
            return nil
        }
        if Self.denialStatuses.contains(result.status) {
            let denied = KeychainReadError(status: result.status)
            entry.denied = denied
            throw denied
        }
        guard result.status == errSecSuccess,
              let data = result.value as? Data,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              object["v"] as? Int == 1,
              let services = object["services"] as? [String: [String: String]]
        else {
            throw KeychainReadError(
                status: result.status == errSecSuccess
                    ? errSecDecode
                    : result.status
            )
        }
        entry.loaded = true
        entry.services = services
        return Payload(services: services)
    }

    /// Updates the cache only after the Keychain accepted the change, and
    /// never reads the item back.
    private func write(services: [String: [String: String]]) throws {
        if services.isEmpty {
            let status = api.delete(matchQuery())
            guard status == errSecSuccess || status == errSecItemNotFound
            else {
                throw KeychainReadError(status: status)
            }
            entry.loaded = true
            entry.services = nil
            return
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: ["v": 1, "services": services],
            options: [.sortedKeys]
        )
        let cached = entry
        let exists = cached.loaded
            ? cached.services != nil
            : try itemExists()
        let status: OSStatus
        if exists {
            status = api.update(
                matchQuery(),
                attributes: [key(kSecValueData): encoded]
            )
        } else {
            var attributes = matchQuery()
            attributes[key(kSecValueData)] = encoded
            attributes[key(kSecAttrAccessible)] =
                key(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
            attributes[key(kSecUseAuthenticationContext)] =
                noninteractiveContext()
            status = api.add(attributes)
        }
        guard status == errSecSuccess else {
            throw KeychainReadError(status: status)
        }
        entry.loaded = true
        entry.services = services
    }

    private func itemExists() throws -> Bool {
        let query: [String: Any] = [
            key(kSecClass): key(kSecClassGenericPassword),
            key(kSecAttrService): serviceName,
            key(kSecAttrAccount): accountName,
            key(kSecUseAuthenticationContext): noninteractiveContext(),
            SecurityKeychainAuthenticationUIPolicy.queryKey:
                SecurityKeychainAuthenticationUIPolicy.failValue,
        ]
        let result = api.copyMatching(query)
        if result.status == errSecItemNotFound { return false }
        guard result.status == errSecSuccess else {
            throw KeychainReadError(status: result.status)
        }
        return true
    }

    private func matchQuery() -> [String: Any] {
        [
            key(kSecClass): key(kSecClassGenericPassword),
            key(kSecAttrService): serviceName,
            key(kSecAttrAccount): accountName,
        ]
    }
}

private func key(_ value: CFString) -> String {
    value as String
}

private func noninteractiveContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
}
