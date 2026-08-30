import Foundation
import LocalAuthentication
import Security

struct SecurityItemCopyResult: @unchecked Sendable {
    let status: OSStatus
    let value: Any?
}

protocol SecurityItemAPI: Sendable {
    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult
    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus
}

struct SecurityFrameworkItemAPI: SecurityItemAPI {
    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return SecurityItemCopyResult(status: status, value: value)
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
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
