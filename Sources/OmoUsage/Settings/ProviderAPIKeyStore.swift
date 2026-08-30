import Foundation
import Darwin

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
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["apiKey": key],
            options: [.prettyPrinted, .sortedKeys]
        )
        let temporaryURL = directory.appending(
            path: ".\(configURL.lastPathComponent).\(UUID().uuidString)"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard rename(temporaryURL.path, configURL.path) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: configURL)
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

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
