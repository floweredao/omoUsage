import Foundation
import LocalAuthentication
import Security

struct SecurityItemCopyResult: @unchecked Sendable {
    let status: OSStatus
    let value: Any?
}

protocol SecurityItemAPI: Sendable {
    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

extension SecurityItemAPI {
    func add(_ attributes: [String: Any]) -> OSStatus { errSecUnimplemented }
    func delete(_ query: [String: Any]) -> OSStatus { errSecUnimplemented }
}

struct SecurityFrameworkItemAPI: SecurityItemAPI {
    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return SecurityItemCopyResult(status: status, value: value)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

protocol ProviderKeychain: Sendable {
    func value(service: String, account: String) throws -> String?
    func set(_ value: String, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

/// OmoUsage-owned generic-password items. Exact service/account matching keeps
/// provider-owned credentials outside this adapter's mutation boundary.
struct SecurityProviderKeychain: ProviderKeychain {
    let api: any SecurityItemAPI

    init(api: any SecurityItemAPI = SecurityFrameworkItemAPI()) {
        self.api = api
    }

    func value(service: String, account: String) throws -> String? {
        let result = api.copyMatching(query(
            service: service,
            account: account,
            returningData: true
        ))
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw KeychainReadError(status: result.status)
        }
        guard let data = result.value as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else {
            throw KeychainReadError(status: errSecDecode)
        }
        return value
    }

    func set(_ value: String, service: String, account: String) throws {
        let match = query(service: service, account: account)
        let status: OSStatus
        if try self.value(service: service, account: account) == nil {
            status = api.add(match.merging([
                securityKey(kSecValueData): Data(value.utf8),
                securityKey(kSecAttrAccessible):
                    securityKey(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
                securityKey(kSecUseAuthenticationContext):
                    noninteractiveContext()
            ], uniquingKeysWith: { _, new in new }))
        } else {
            status = api.update(
                match,
                attributes: [securityKey(kSecValueData): Data(value.utf8)]
            )
        }
        guard status == errSecSuccess else {
            throw KeychainReadError(status: status)
        }
    }

    func remove(service: String, account: String) throws {
        let status = api.delete(query(service: service, account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainReadError(status: status)
        }
    }

    private func query(
        service: String,
        account: String,
        returningData: Bool = false
    ) -> [String: Any] {
        var value: [String: Any] = [
            securityKey(kSecClass): securityKey(kSecClassGenericPassword),
            securityKey(kSecAttrService): service,
            securityKey(kSecAttrAccount): account
        ]
        if returningData {
            value[securityKey(kSecReturnData)] = true
            value[securityKey(kSecMatchLimit)] = securityKey(kSecMatchLimitOne)
            value[securityKey(kSecUseAuthenticationContext)] =
                noninteractiveContext()
        }
        return value
    }
}

/// Updates one existing generic-password item through Security.framework.
/// Matching by its persistent reference avoids delete/recreate behavior and
/// preserves the item's service, account, access controls, and ACL.
struct SecurityKeychainWriter: KeychainWriting {
    let api: any SecurityItemAPI

    init(api: any SecurityItemAPI = SecurityFrameworkItemAPI()) {
        self.api = api
    }

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        var query: [String: Any] = [
            securityKey(kSecClass): securityKey(kSecClassGenericPassword),
            securityKey(kSecAttrService): service,
            securityKey(kSecReturnAttributes): true,
            securityKey(kSecReturnPersistentRef): true,
            securityKey(kSecMatchLimit): securityKey(kSecMatchLimitAll),
            securityKey(kSecUseAuthenticationContext): noninteractiveContext()
        ]
        if !account.isEmpty {
            query[securityKey(kSecAttrAccount)] = account
        }

        let result = api.copyMatching(query)
        guard result.status == errSecSuccess else {
            throw KeychainReadError(status: result.status)
        }
        guard let items = result.value as? [[String: Any]] else {
            throw KeychainReadError(status: errSecDecode)
        }
        guard items.count == 1 else {
            throw KeychainReadError(
                status: items.isEmpty ? errSecItemNotFound : errSecDuplicateItem
            )
        }
        let item = items[0]
        guard
            item[securityKey(kSecAttrService)] as? String == service,
            let resolvedAccount = item[securityKey(kSecAttrAccount)] as? String,
            !resolvedAccount.isEmpty,
            account.isEmpty || resolvedAccount == account,
            let persistentReference = item[
                securityKey(kSecValuePersistentRef)
            ] as? Data,
            !persistentReference.isEmpty
        else {
            throw KeychainReadError(status: errSecDecode)
        }

        let updateStatus = api.update(
            [
                securityKey(kSecValuePersistentRef): persistentReference,
                securityKey(kSecUseAuthenticationContext):
                    noninteractiveContext()
            ],
            attributes: [
                securityKey(kSecValueData): Data(value.utf8)
            ]
        )
        guard updateStatus == errSecSuccess else {
            throw KeychainReadError(status: updateStatus)
        }
    }
}

private func securityKey(_ value: CFString) -> String {
    value as String
}

private func noninteractiveContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
}
