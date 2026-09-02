import Foundation
import LocalAuthentication
import Security

struct SecurityKeychainReader: KeychainReading {
    let api: any SecurityItemAPI

    init(
        api: any SecurityItemAPI = SecurityFrameworkItemAPI()
    ) {
        self.api = api
    }

    func value(service: String, account: String) throws -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            keychainKey(kSecClass):
                keychainKey(kSecClassGenericPassword),
            keychainKey(kSecAttrService): service,
            keychainKey(kSecReturnData): true,
            keychainKey(kSecMatchLimit):
                keychainKey(kSecMatchLimitOne),
            keychainKey(kSecUseAuthenticationContext): context
        ]
        if !account.isEmpty {
            query[keychainKey(kSecAttrAccount)] = account
        }
        let result = api.copyMatching(query)
        if result.status == errSecItemNotFound { return nil }
        guard result.status == errSecSuccess else {
            throw KeychainReadError(status: result.status)
        }
        guard let data = result.value as? Data else {
            throw KeychainReadError(status: errSecDecode)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainReadError(status: errSecDecode)
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct KeychainReadError: Error, Equatable {
    let status: OSStatus
}

private func keychainKey(_ value: CFString) -> String {
    value as String
}
