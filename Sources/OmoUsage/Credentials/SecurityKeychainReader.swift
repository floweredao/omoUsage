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
            return claudeSession.cachedValue(
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

    private struct CacheKey: Hashable {
        let service: String
        let account: String
    }

    private static let safeStorageService = "Claude Safe Storage"
    private static let safeStorageAccount = "Claude Key"

    private let lock = NSLock()
    private var values: [CacheKey: String] = [:]
    private var interactionDepth = 0

    static func isProtected(service: String) -> Bool {
        CredentialDiscovery.claudeKeychainServices.contains(service)
            || service == safeStorageService
    }

    var allowsInteraction: Bool {
        lock.withLock { interactionDepth > 0 }
    }

    func cachedValue(
        service: String,
        account: String
    ) -> String? {
        lock.withLock {
            if let value = values[
                CacheKey(service: service, account: account)
            ] {
                return value
            }
            guard account.isEmpty else { return nil }
            return values.first {
                $0.key.service == service
            }?.value
        }
    }

    func cache(
        _ value: String,
        service: String,
        account: String
    ) {
        lock.withLock {
            values[CacheKey(service: service, account: account)] =
                value
        }
    }

    func authorizeClaude(
        api: any SecurityItemAPI = SecurityFrameworkItemAPI()
    ) throws -> ClaudeKeychainAuthorizationOutcome {
        let targets = CredentialDiscovery.claudeKeychainServices.map {
            (service: $0, account: "")
        } + [(
            service: Self.safeStorageService,
            account: Self.safeStorageAccount
        )]

        for target in targets {
            var query: [String: Any] = [
                keychainKey(kSecClass):
                    keychainKey(kSecClassGenericPassword),
                keychainKey(kSecAttrService): target.service,
                keychainKey(kSecReturnData): true,
                keychainKey(kSecMatchLimit):
                    keychainKey(kSecMatchLimitOne)
            ]
            if !target.account.isEmpty {
                query[keychainKey(kSecAttrAccount)] =
                    target.account
            }
            let result = api.copyMatching(query)
            switch result.status {
            case errSecSuccess:
                guard
                    let data = result.value as? Data,
                    let value = String(data: data, encoding: .utf8),
                    !value.isEmpty
                else {
                    throw KeychainReadError(status: errSecDecode)
                }
                cache(
                    value,
                    service: target.service,
                    account: target.account
                )
                return .authorized(service: target.service)
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
