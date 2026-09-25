import Foundation
import LocalAuthentication
import Security

/// OmoUsage-owned secrets consolidated into ONE generic-password item.
/// Callers keep addressing by exact (service, account); only the storage
/// layout changes — a single versioned JSON map so the Keychain ACL has one
/// entry (one prompt per signing identity) for every provider/account.
/// Layout: {"v":1,"services":{"<service>":{"<account>":"<secret>"}}}
///
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
    private var didAttemptImport = false

    init(
        api: any SecurityItemAPI = SecurityFrameworkItemAPI(),
        service: String = UnifiedProviderKeychain.service,
        account: String = UnifiedProviderKeychain.account,
        legacyServices: [String] = UnifiedProviderKeychain.defaultLegacyServices
    ) {
        self.api = api
        self.serviceName = service
        self.accountName = account
        self.legacyServices = legacyServices
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
    /// merged yet: an enumeration failure leaves `didAttemptImport` false
    /// so a later access can converge. A consolidated item with data wins
    /// over any legacy leftovers.
    private func ensureImported() throws {
        guard !didAttemptImport else { return }
        if (try readPayload()) != nil {
            didAttemptImport = true
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
        didAttemptImport = !enumerationFailed
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
    /// overwritten.
    private func readPayload() throws -> Payload? {
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
        if result.status == errSecItemNotFound { return nil }
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
        return Payload(services: services)
    }

    private func write(services: [String: [String: String]]) throws {
        if services.isEmpty {
            let status = api.delete(matchQuery())
            guard status == errSecSuccess || status == errSecItemNotFound
            else {
                throw KeychainReadError(status: status)
            }
            return
        }
        let encoded = try JSONSerialization.data(
            withJSONObject: ["v": 1, "services": services],
            options: [.sortedKeys]
        )
        let exists = try itemExists()
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
