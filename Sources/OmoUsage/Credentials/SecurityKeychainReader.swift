import Foundation
import LocalAuthentication
import Security

struct SecurityKeychainReader: KeychainReading {
    let api: any SecurityItemAPI
    let claudeSession: ClaudeKeychainAccessSession

    init(
        api: any SecurityItemAPI = SecurityFrameworkItemAPI(),
        claudeSession: ClaudeKeychainAccessSession = .shared
    ) {
        self.api = api
        self.claudeSession = claudeSession
    }

    func value(service: String, account: String) throws -> String? {
        if ClaudeKeychainAccessSession.isProtected(service: service) {
            return try claudeSession.authorizedValue(
                service: service,
                account: account
            )
        }
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            keychainKey(kSecClass):
                keychainKey(kSecClassGenericPassword),
            keychainKey(kSecAttrService): service,
            keychainKey(kSecReturnData): true,
            keychainKey(kSecMatchLimit):
                keychainKey(kSecMatchLimitOne),
            keychainKey(kSecUseAuthenticationContext): context,
            SecurityKeychainAuthenticationUIPolicy.queryKey:
                SecurityKeychainAuthenticationUIPolicy.failValue
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

/// Legacy macOS Keychain ACL items can ignore a noninteractive `LAContext`
/// and still open SecurityAgent. These are the stable raw values of the
/// deprecated `kSecUseAuthenticationUI` / `kSecUseAuthenticationUIFail`
/// constants, retained only to force fail-closed behavior for those items.
enum SecurityKeychainAuthenticationUIPolicy {
    static let queryKey = "u_AuthUI"
    static let failValue = "u_AuthUIF"
}

enum ClaudeKeychainAuthorizationOutcome: Equatable, Sendable {
    case authorized(service: String)
    case notFound
    case cancelled
}

final class ClaudeKeychainAccessSession: @unchecked Sendable {
    static let shared = ClaudeKeychainAccessSession()

    /// One explicitly selected OAuth origin, not a scan of foreign stores.
    /// Keep the raw JSON so rotation preserves fields owned by Claude Code.
    private struct AuthorizedCredential: Codable {
        let service: String
        let account: String
        let value: String
    }

    private static let mirrorService = "com.omo.usage.claude-authorized-credential"
    private static let mirrorAccount = "oauth"
    private static let safeStorageService = "Claude Safe Storage"

    private let providerKeychain: any ProviderKeychain

    init(providerKeychain: any ProviderKeychain = SecurityProviderKeychain()) {
        self.providerKeychain = providerKeychain
    }

    private let lock = NSLock()
    private var interactionDepth = 0

    static func isProtected(service: String) -> Bool {
        CredentialDiscovery.claudeKeychainServices.contains(service)
            || service == safeStorageService
    }

    var allowsInteraction: Bool {
        lock.withLock { interactionDepth > 0 }
    }

    func authorizedValue(service: String, account: String) throws -> String? {
        guard CredentialDiscovery.claudeKeychainServices.contains(service) else {
            return nil
        }
        return try lock.withLock {
            guard let stored = try storedCredential(),
                  stored.service == service, stored.account == account
            else { return nil }
            return stored.value
        }
    }

    func updateAuthorizedValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        try lock.withLock {
            guard let stored = try storedCredential(),
                  stored.service == service, stored.account == account
            else {
                throw KeychainReadError(status: errSecInteractionNotAllowed)
            }
            try save(AuthorizedCredential(
                service: service, account: account, value: value
            ))
        }
    }

    private func storedCredential() throws -> AuthorizedCredential? {
        guard let encoded = try providerKeychain.value(
            service: Self.mirrorService, account: Self.mirrorAccount
        ) else { return nil }
        guard let stored = try? JSONDecoder().decode(
            AuthorizedCredential.self, from: Data(encoded.utf8)
        ), stored.service == CredentialDiscovery.claudeLoginKeychainService,
           stored.account.isEmpty, !stored.value.isEmpty
        else {
            throw KeychainReadError(status: errSecDecode)
        }
        return stored
    }

    private func save(_ credential: AuthorizedCredential) throws {
        let encoded = try JSONEncoder().encode(credential)
        try providerKeychain.set(
            String(decoding: encoded, as: UTF8.self),
            service: Self.mirrorService, account: Self.mirrorAccount
        )
    }

    func authorizeClaude(
        api: any SecurityItemAPI = SecurityFrameworkItemAPI()
    ) throws -> ClaudeKeychainAuthorizationOutcome {
        try lock.withLock {
            // Explicit login replaces the old grant even when permission is
            // denied or saving the new grant fails. Never publish memory-only
            // authorization that would disappear on the next launch.
            try providerKeychain.remove(
                service: Self.mirrorService, account: Self.mirrorAccount
            )
            // This grant was created in OmoUsage's private CLI configuration.
            // Importing the interactive CLI's grant would race its token rotation.
            for service in [CredentialDiscovery.claudeLoginKeychainService] {
                let query: [String: Any] = [
                    keychainKey(kSecClass): keychainKey(kSecClassGenericPassword),
                    keychainKey(kSecAttrService): service,
                    keychainKey(kSecReturnData): true,
                    keychainKey(kSecMatchLimit): keychainKey(kSecMatchLimitOne)
                ]
                let result = api.copyMatching(query)
                switch result.status {
                case errSecSuccess:
                    guard let data = result.value as? Data,
                          let value = String(data: data, encoding: .utf8),
                          !value.isEmpty
                    else {
                        throw KeychainReadError(status: errSecDecode)
                    }
                    try save(AuthorizedCredential(
                        service: service, account: "", value: value
                    ))
                    return .authorized(service: service)
                case errSecItemNotFound:
                    continue
                case errSecInteractionNotAllowed, errSecAuthFailed,
                     errSecUserCanceled:
                    return .cancelled
                default:
                    throw KeychainReadError(status: result.status)
                }
            }
            return .notFound
        }
    }

    func withInteractionAllowed<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        lock.withLock {
            interactionDepth += 1
        }
        defer {
            lock.withLock {
                interactionDepth -= 1
            }
        }
        return try await operation()
    }
}

private func keychainKey(_ value: CFString) -> String {
    value as String
}
