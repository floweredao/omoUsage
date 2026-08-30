import CryptoKit
import Darwin
import Foundation

struct ProviderAPIKeyStore: Sendable {
    let configURL: URL
    let environment: [String: String]
    let environmentNames: [String]

    func load() -> String? {
        loadCredential()?.value
    }

    func loadCredential() -> (
        value: String,
        source: CredentialSource
    )? {
        for name in environmentNames {
            if let value = environment[name]?.trimmedNonEmpty {
                return (value, .environment)
            }
        }
        if
            let data = try? Data(contentsOf: configURL),
            let object = try? UsageJSON.object(data)
        {
            for key in ["apiKey", "api_key", "key"] {
                if let value = (object[key] as? String)?.trimmedNonEmpty {
                    return (value, .file)
                }
            }
        }
        return nil
    }

    func save(_ key: String) throws {
        guard let key = key.trimmedNonEmpty else {
            throw ProviderAPIKeyStoreError.empty
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["apiKey": key],
            options: [.prettyPrinted, .sortedKeys]
        )
        try ProviderFileDurability.atomicWrite(
            data,
            to: configURL,
            permissions: 0o600
        )
    }

    func remove() throws {
        try ProviderFileDurability.removeIfPresent(configURL)
    }

    func stage(_ key: String, transactionID: UUID) throws {
        try stagedStore(transactionID: transactionID).save(key)
    }

    func promoteStagedSecret(transactionID: UUID) throws {
        let stagedURL = stagedURL(transactionID: transactionID)
        guard rename(stagedURL.path, configURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try ProviderFileDurability.syncDirectory(
            configURL.deletingLastPathComponent()
        )
    }

    func removeStagedSecret(transactionID: UUID) throws {
        try ProviderFileDurability.removeIfPresent(
            stagedURL(transactionID: transactionID)
        )
    }

    func stagedSecretExists(transactionID: UUID) -> Bool {
        FileManager.default.fileExists(
            atPath: stagedURL(transactionID: transactionID).path
        )
    }

    func stagedSecretDigest(transactionID: UUID) -> String? {
        stagedStore(transactionID: transactionID).load().map(apiKeyDigest)
    }

    func persistedSecretDigest() -> String? {
        ProviderAPIKeyStore(
            configURL: configURL,
            environment: [:],
            environmentNames: []
        ).load().map(apiKeyDigest)
    }

    private func stagedStore(transactionID: UUID) -> ProviderAPIKeyStore {
        ProviderAPIKeyStore(
            configURL: stagedURL(transactionID: transactionID),
            environment: [:],
            environmentNames: []
        )
    }

    private func stagedURL(transactionID: UUID) -> URL {
        configURL.deletingLastPathComponent().appending(
            path: ".\(configURL.lastPathComponent).mutation-\(transactionID.uuidString.lowercased())"
        )
    }

    static func live(
        for provider: ProviderID,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderAPIKeyStore? {
        let configHome: URL
        if
            let value = environment["XDG_CONFIG_HOME"]?.trimmedNonEmpty,
            value.hasPrefix("/")
        {
            configHome = URL(
                filePath: value,
                directoryHint: .isDirectory
            )
        } else {
            configHome = home.appending(
                path: ".config",
                directoryHint: .isDirectory
            )
        }
        let base = configHome.appending(
            path: "openusage",
            directoryHint: .isDirectory
        )
        switch provider {
        case .opencode:
            return ProviderAPIKeyStore(
                configURL: base.appending(path: "opencode.json"),
                environment: environment,
                environmentNames: ["OPENCODE_API_KEY"]
            )
        case .openrouter:
            return ProviderAPIKeyStore(
                configURL: base.appending(path: "openrouter.json"),
                environment: environment,
                environmentNames: [
                    "OPENROUTER_API_KEY",
                    "OPENROUTER_KEY"
                ]
            )
        case .zai:
            return ProviderAPIKeyStore(
                configURL: base.appending(path: "zai.json"),
                environment: environment,
                environmentNames: ["ZAI_API_KEY", "GLM_API_KEY"]
            )
        default:
            return nil
        }
    }

    static func live(
        for provider: ProviderID,
        accountID: AccountID,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProviderAPIKeyStore? {
        guard let legacy = live(
            for: provider,
            home: home,
            environment: environment
        ) else {
            return nil
        }
        guard accountID != .legacy else { return legacy }
        let accountDirectory = legacy.configURL
            .deletingLastPathComponent()
            .appending(
                path: "accounts/\(accountID.rawValue)",
                directoryHint: .isDirectory
            )
        return ProviderAPIKeyStore(
            configURL: accountDirectory.appending(
                path: legacy.configURL.lastPathComponent
            ),
            environment: environment,
            environmentNames: []
        )
    }
}

enum ProviderAPIKeyStoreError: Error, Equatable {
    case empty
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
