import OmoUsageCore
import CryptoKit
import Foundation

protocol ProviderLegacyFileSystem: Sendable {
    func data(at url: URL) throws -> Data
    func exists(at url: URL) -> Bool
    func remove(at url: URL) throws
}

struct LiveProviderLegacyFileSystem: ProviderLegacyFileSystem {
    func data(at url: URL) throws -> Data { try Data(contentsOf: url) }
    func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
    func remove(at url: URL) throws {
        try ProviderFileDurability.removeIfPresent(url)
    }
}

struct ProviderAPIKeyStore: Sendable {
    static let serviceName = "com.omo.usage.provider-api-keys.v1"

    let provider: ProviderID
    let accountID: AccountID
    let serviceName: String
    let legacyURL: URL
    let legacyURLs: [URL]
    let environment: [String: String]
    let environmentNames: [String]
    let keychain: any ProviderKeychain
    let legacyFileSystem: any ProviderLegacyFileSystem

    var configURL: URL { legacyURL }
    var service: String { serviceName }
    var account: String { "\(provider.rawValue)/\(accountID.rawValue)" }

    init(
        configURL: URL,
        environment: [String: String],
        environmentNames: [String]
    ) {
        self.init(
            provider: .openrouter,
            accountID: .legacy,
            serviceName: Self.serviceName,
            legacyURL: configURL,
            environment: environment,
            environmentNames: environmentNames,
            keychain: VolatileProviderKeychain(),
            legacyFileSystem: LiveProviderLegacyFileSystem()
        )
    }

    init(
        provider: ProviderID,
        accountID: AccountID,
        serviceName: String,
        legacyURL: URL,
        environment: [String: String],
        environmentNames: [String],
        keychain: any ProviderKeychain,
        legacyFileSystem: any ProviderLegacyFileSystem,
        legacyURLs: [URL]? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
        self.serviceName = serviceName
        self.legacyURL = legacyURL
        self.legacyURLs = legacyURLs ?? [legacyURL]
        self.environment = environment
        self.environmentNames = environmentNames
        self.keychain = keychain
        self.legacyFileSystem = legacyFileSystem
    }

    func load() -> String? { loadCredential()?.value }

    func loadCredential() -> (value: String, source: CredentialSource)? {
        for name in environmentNames {
            if let value = environment[name]?.trimmedNonEmpty {
                return (value, .environment)
            }
        }
        do {
            if let value = try keychain.value(service: service, account: account)?
                .trimmedNonEmpty
            {
                return (value, .keychain)
            }
        } catch {
            // A denied or ambiguous exact Keychain lookup must not widen to a
            // lower-precedence plaintext credential.
            return nil
        }
        return legacyCredential().map { ($0, .file) }
    }

    func save(_ key: String) throws {
        guard let key = key.trimmedNonEmpty else {
            throw ProviderAPIKeyStoreError.empty
        }
        try keychain.set(key, service: service, account: account)
    }

    func remove() throws {
        try keychain.remove(service: service, account: account)
    }

    func stage(_ key: String, transactionID: UUID) throws {
        guard let key = key.trimmedNonEmpty else {
            throw ProviderAPIKeyStoreError.empty
        }
        try keychain.set(
            key,
            service: service,
            account: stagingAccount(transactionID)
        )
    }

    func promoteStagedSecret(transactionID: UUID) throws {
        let staging = stagingAccount(transactionID)
        guard let value = try keychain.value(service: service, account: staging) else {
            throw ProviderAPIKeyStoreError.stagedSecretMissing
        }
        try keychain.set(value, service: service, account: account)
        try keychain.remove(service: service, account: staging)
    }

    func removeStagedSecret(transactionID: UUID) throws {
        try keychain.remove(
            service: service,
            account: stagingAccount(transactionID)
        )
    }

    func stagedSecretExists(transactionID: UUID) -> Bool {
        (try? keychain.value(
            service: service,
            account: stagingAccount(transactionID)
        )) != nil
    }

    func stagedSecretDigest(transactionID: UUID) -> String? {
        try? keychain.value(
            service: service,
            account: stagingAccount(transactionID)
        ).map(apiKeyDigest)
    }

    func persistedSecretDigest() -> String? {
        keychainCredential().map(apiKeyDigest)
    }

    func keychainCredential() -> String? {
        (try? keychain.value(service: service, account: account)) ?? nil
    }

    func legacyCredential() -> String? {
        for url in legacyURLs where legacyFileSystem.exists(at: url) {
            guard let data = try? legacyFileSystem.data(at: url) else {
                continue
            }
            if let object = try? UsageJSON.object(data) {
                for key in ["apiKey", "api_key", "key"] {
                    if let value = (object[key] as? String)?.trimmedNonEmpty {
                        return value
                    }
                }
                continue
            }
            guard
                provider == .openrouter || provider == .zai,
                let value = String(data: data, encoding: .utf8)?
                    .trimmedNonEmpty,
                !value.hasPrefix("{"),
                !value.hasPrefix("["),
                !value.hasPrefix("\"")
            else {
                continue
            }
            return value
        }
        return nil
    }

    var legacyExists: Bool {
        legacyURLs.contains(where: legacyFileSystem.exists(at:))
    }

    func removeLegacy() throws {
        var firstError: (any Error)?
        for url in legacyURLs {
            do {
                try legacyFileSystem.remove(at: url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private func stagingAccount(_ transactionID: UUID) -> String {
        "\(account)#staging#\(transactionID.uuidString.lowercased())"
    }

    static func live(
        for provider: ProviderID,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: any ProviderKeychain = UnifiedProviderKeychain(),
        legacyFileSystem: any ProviderLegacyFileSystem = LiveProviderLegacyFileSystem()
    ) -> ProviderAPIKeyStore? {
        live(
            for: provider,
            accountID: .legacy,
            home: home,
            environment: environment,
            keychain: keychain,
            legacyFileSystem: legacyFileSystem
        )
    }

    static func live(
        for provider: ProviderID,
        accountID: AccountID,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: any ProviderKeychain = UnifiedProviderKeychain(),
        legacyFileSystem: any ProviderLegacyFileSystem = LiveProviderLegacyFileSystem()
    ) -> ProviderAPIKeyStore? {
        let fileName: String
        let environmentNames: [String]
        switch provider {
        case .opencode:
            fileName = "opencode.json"
            environmentNames = ["OPENCODE_API_KEY"]
        case .openrouter:
            fileName = "openrouter.json"
            environmentNames = ["OPENROUTER_API_KEY", "OPENROUTER_KEY"]
        case .zai:
            fileName = "zai.json"
            environmentNames = ["ZAI_API_KEY", "GLM_API_KEY"]
        case .devin, .kiro:
            // Imported credentials use the same exact account-scoped store
            // and transaction journal as captured companion snapshots.
            fileName = "\(provider.rawValue).json"
            environmentNames = []
        default:
            guard accountID != .legacy else { return nil }
            fileName = "\(provider.rawValue).json"
            environmentNames = []
        }
        let configHome: URL
        if let value = environment["XDG_CONFIG_HOME"]?.trimmedNonEmpty,
           value.hasPrefix("/") {
            configHome = URL(filePath: value, directoryHint: .isDirectory)
        } else {
            configHome = home.appending(path: ".config", directoryHint: .isDirectory)
        }
        var legacyURL = configHome.appending(path: "openusage", directoryHint: .isDirectory)
        if accountID != .legacy {
            legacyURL.append(path: "accounts/\(accountID.rawValue)", directoryHint: .isDirectory)
        }
        legacyURL.append(path: fileName)
        let legacyURLs: [URL]
        if provider == .openrouter, accountID == .legacy {
            legacyURLs = [
                legacyURL,
                configHome.appending(path: "openrouter/key.json")
            ]
        } else if provider == .zai, accountID == .legacy {
            legacyURLs = [
                legacyURL,
                configHome.appending(path: "zai/key.json")
            ]
        } else {
            legacyURLs = [legacyURL]
        }
#if OMO_USAGE_FIXTURES
        let serviceName = environment["OMO_USAGE_KEY_MIGRATION_QA"] == "1"
            ? environment["OMO_USAGE_PROVIDER_KEYCHAIN_SERVICE"]?.trimmedNonEmpty
                ?? Self.serviceName
            : Self.serviceName
#else
        let serviceName = Self.serviceName
#endif
        return ProviderAPIKeyStore(
            provider: provider,
            accountID: accountID,
            serviceName: serviceName,
            legacyURL: legacyURL,
            environment: environment,
            environmentNames: accountID == .legacy ? environmentNames : [],
            keychain: keychain,
            legacyFileSystem: legacyFileSystem,
            legacyURLs: legacyURLs
        )
    }
}

enum ProviderAPIKeyStoreError: Error, Equatable {
    case empty
    case stagedSecretMissing
}

private final class VolatileProviderKeychain: ProviderKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func value(service: String, account: String) throws -> String? {
        lock.withLock { values[service + "|" + account] }
    }
    func set(_ value: String, service: String, account: String) throws {
        lock.withLock { values[service + "|" + account] = value }
    }
    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: service + "|" + account) }
    }
}

private func apiKeyDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
