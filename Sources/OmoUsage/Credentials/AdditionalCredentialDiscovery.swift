import Foundation

extension CredentialDiscovery {
    func cursor(now: Date) throws -> DiscoveredCredential {
        let database = home.appending(
            components: "Library",
            "Application Support",
            "Cursor",
            "User",
            "globalStorage",
            "state.vscdb"
        )
        let sql = """
        SELECT value FROM ItemTable
        WHERE key = 'cursorAuth/accessToken' LIMIT 1;
        """
        let token = try LocalDataAccess.sqliteValue(
            database: database,
            sql: sql
        )
        guard let accessToken = token?.nonBlank else {
            throw CredentialDiscoveryError.notFound(.cursor)
        }
        try rejectExpiredJWT(
            accessToken,
            provider: .cursor,
            now: now
        )
        return credential(
            .cursor,
            token: accessToken,
            source: .file
        )
    }

    func copilot() throws -> DiscoveredCredential {
        for name in [
            "COPILOT_GITHUB_TOKEN",
            "GH_TOKEN",
            "GITHUB_TOKEN"
        ] {
            if let token = environment[name]?.nonBlank {
                return credential(
                    .copilot,
                    token: token,
                    source: .environment
                )
            }
        }
        do {
            if
                let token = try keychain.value(
                    service: "copilot-cli",
                    account: ""
                )?.nonBlank
            {
                return credential(
                    .copilot,
                    token: token,
                    source: .keychain
                )
            }
        } catch {
            throw CredentialDiscoveryError.malformed(.copilot)
        }
        for relative in [
            ".config/github-copilot/apps.json",
            ".config/github-copilot/hosts.json"
        ] {
            let url = home.appending(path: relative)
            if let token = editorOAuthToken(at: url) {
                return credential(.copilot, token: token, source: .file)
            }
        }
        let hosts = home.appending(path: ".config/gh/hosts.yml")
        if let text = try? String(contentsOf: hosts, encoding: .utf8),
           let token = githubYAMLValue(text, key: "oauth_token")
        {
            return credential(.copilot, token: token, source: .file)
        }
        for executable in commandPaths
        where FileManager.default.isExecutableFile(
            atPath: executable.path
        ) {
            if let token = try? LocalDataAccess.commandValue(
                executable: executable,
                arguments: ["auth", "token", "--hostname", "github.com"]
            ), let token = token.nonBlank {
                return credential(
                    .copilot,
                    token: token,
                    source: .file
                )
            }
        }
        throw CredentialDiscoveryError.notFound(.copilot)
    }

    func devin() throws -> DiscoveredCredential {
        let dataDirectory: URL
        if
            let value = environment["XDG_DATA_HOME"]?.nonBlank,
            value.hasPrefix("/")
        {
            dataDirectory = URL(
                filePath: value,
                directoryHint: .isDirectory
            )
        } else {
            dataDirectory = home.appending(
                path: ".local/share",
                directoryHint: .isDirectory
            )
        }
        let url = dataDirectory.appending(
            path: "devin/credentials.toml"
        )
        var candidateError: CredentialDiscoveryError?
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                if let token = tomlValue(
                    text,
                    key: "windsurf_api_key"
                ) {
                    return DiscoveredCredential(
                        provider: .devin,
                        accessToken: token,
                        refreshToken: nil,
                        accountID: tomlValue(
                            text,
                            key: "api_server_url"
                        ),
                        planName: nil,
                        expiresAt: nil,
                        source: .file
                    )
                }
                candidateError = .malformed(.devin)
            } catch {
                candidateError = .malformed(.devin)
            }
        }
        let database = home.appending(
            components: "Library",
            "Application Support",
            "Devin",
            "User",
            "globalStorage",
            "state.vscdb"
        )
        let sql = """
        SELECT value FROM ItemTable
        WHERE key = 'windsurfAuthStatus' LIMIT 1;
        """
        if FileManager.default.fileExists(atPath: database.path) {
            do {
                if let raw = try LocalDataAccess.sqliteValue(
                    database: database,
                    sql: sql
                ) {
                    guard
                        let data = raw.data(using: .utf8),
                        let object = try? UsageJSON.object(data),
                        let token = (
                            object["apiKey"] as? String
                        )?.nonBlank
                    else {
                        throw CredentialDiscoveryError.malformed(.devin)
                    }
                    return credential(
                        .devin,
                        token: token,
                        source: .file
                    )
                }
            } catch {
                candidateError = .malformed(.devin)
            }
        }
        if let candidateError {
            throw candidateError
        }
        throw CredentialDiscoveryError.notFound(.devin)
    }

    func grok(now: Date) throws -> DiscoveredCredential {
        let root = grokHome.appending(path: "auth.json")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw CredentialDiscoveryError.notFound(.grok)
        }
        let data: Data
        let object: [String: Any]
        do {
            data = try Data(contentsOf: root)
            object = try UsageJSON.object(data)
        } catch {
            throw CredentialDiscoveryError.malformed(.grok)
        }
        var candidateError: CredentialDiscoveryError?
        for key in object.keys.sorted() {
            guard
                let entry = UsageJSON.object(object[key]),
                let token = (entry["key"] as? String)?.nonBlank
            else {
                continue
            }
            let refreshToken = (
                entry["refresh_token"] as? String
                ?? entry["refresh"] as? String
            )?.nonBlank
            let issuer = (
                entry["oidc_issuer"] as? String
                ?? entry["issuer"] as? String
            )?.nonBlank
            let clientID = (
                entry["oidc_client_id"] as? String
                ?? entry["client_id"] as? String
            )?.nonBlank
            let expiresAt = UsageJSON.date(entry["expires_at"])
                ?? jwtExpiration(token)
            if
                let expiresAt,
                expiresAt <= now,
                refreshToken == nil || issuer == nil || clientID == nil
            {
                candidateError = .expired(.grok)
                continue
            }
            return DiscoveredCredential(
                provider: .grok,
                accessToken: token,
                refreshToken: refreshToken,
                accountID: key,
                planName: nil,
                expiresAt: expiresAt,
                source: .file,
                oidcIssuer: issuer,
                oidcClientID: clientID,
                principalType: (
                    entry["principal_type"] as? String
                )?.nonBlank,
                principalID: (
                    entry["principal_id"] as? String
                )?.nonBlank
            )
        }
        if let candidateError {
            throw candidateError
        }
        throw CredentialDiscoveryError.malformed(.grok)
    }

    func opencode(
        accountID: AccountID = .legacy
    ) throws -> DiscoveredCredential {
        if
            let store = ProviderAPIKeyStore.live(
                for: .opencode,
                accountID: accountID,
                home: home,
                environment: environment
            ),
            let loaded = store.loadCredential()
        {
            return credential(
                .opencode,
                token: loaded.value,
                source: loaded.source
            )
        }
        guard accountID == .legacy else {
            throw CredentialDiscoveryError.notFound(.opencode)
        }
        let directory = openCodeDataDirectory
        let auth = directory.appending(path: "auth.json")
        var candidateError: CredentialDiscoveryError?
        if FileManager.default.fileExists(atPath: auth.path) {
            do {
                let data = try Data(contentsOf: auth)
                let object = try UsageJSON.object(data)
                if
                    let entry = UsageJSON.object(
                        object["opencode-go"]
                    ),
                    let token = (
                        entry["key"] as? String
                    )?.nonBlank
                {
                    return credential(
                        .opencode,
                        token: token,
                        source: .file
                    )
                }
                candidateError = .malformed(.opencode)
            } catch {
                candidateError = .malformed(.opencode)
            }
        }
        let databases: [URL]
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                databases = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            } catch {
                throw CredentialDiscoveryError.malformed(.opencode)
            }
        } else {
            databases = []
        }
        if databases.contains(where: {
            $0.lastPathComponent.hasPrefix("opencode")
                && $0.pathExtension == "db"
        }) {
            return credential(.opencode, token: "local", source: .file)
        }
        if let candidateError {
            throw candidateError
        }
        throw CredentialDiscoveryError.notFound(.opencode)
    }

    func openrouter(
        accountID: AccountID = .legacy
    ) throws -> DiscoveredCredential {
        try apiKeyCredential(.openrouter, accountID: accountID)
    }

    func zai(
        accountID: AccountID = .legacy
    ) throws -> DiscoveredCredential {
        try apiKeyCredential(.zai, accountID: accountID)
    }

    var openCodeDataDirectory: URL {
        if
            let value = environment["XDG_DATA_HOME"]?.nonBlank,
            value.hasPrefix("/")
        {
            return URL(filePath: value, directoryHint: .isDirectory)
                .appending(path: "opencode", directoryHint: .isDirectory)
        }
        return home.appending(
            path: ".local/share/opencode",
            directoryHint: .isDirectory
        )
    }

    private var home: URL {
        homeDirectory
    }

    var grokHome: URL {
        if let value = environment["GROK_HOME"]?.nonBlank {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return home.appending(path: ".grok", directoryHint: .isDirectory)
    }

    private func apiKeyCredential(
        _ provider: ProviderID,
        accountID: AccountID
    ) throws -> DiscoveredCredential {
        guard
            let store = ProviderAPIKeyStore.live(
                for: provider,
                accountID: accountID,
                home: home,
                environment: environment
            ),
            let loaded = store.loadCredential()
        else {
            throw CredentialDiscoveryError.notFound(provider)
        }
        return credential(
            provider,
            token: loaded.value,
            source: loaded.source
        )
    }

    private func credential(
        _ provider: ProviderID,
        token: String,
        source: CredentialSource
    ) -> DiscoveredCredential {
        DiscoveredCredential(
            provider: provider,
            accessToken: token,
            refreshToken: nil,
            accountID: nil,
            planName: nil,
            expiresAt: nil,
            source: source
        )
    }
}

private extension CredentialDiscovery {
    func editorOAuthToken(at url: URL) -> String? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? UsageJSON.object(data)
        else {
            return nil
        }
        for (key, value) in object
        where key == "github.com" || key.hasPrefix("github.com:") {
            if let entry = UsageJSON.object(value),
               let token = (entry["oauth_token"] as? String)?.nonBlank
            {
                return token
            }
        }
        return nil
    }

    func githubYAMLValue(_ text: String, key: String) -> String? {
        var inGitHub = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace {
                inGitHub = line.trimmingCharacters(
                    in: .whitespaces
                ) == "github.com:"
                continue
            }
            guard inGitHub else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "\(key):"
            guard trimmed.hasPrefix(prefix) else { continue }
            return String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(
                    charactersIn: " \"'"
                ))
                .nonBlank
        }
        return nil
    }

    func tomlValue(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  parts[0].trimmingCharacters(
                    in: .whitespaces
                  ) == key
            else {
                continue
            }
            return parts[1].trimmingCharacters(
                in: CharacterSet(charactersIn: " \"'")
            ).nonBlank
        }
        return nil
    }

    func rejectExpiredJWT(
        _ token: String,
        provider: ProviderID,
        now: Date
    ) throws {
        if let expiration = jwtExpiration(token), expiration <= now {
            throw CredentialDiscoveryError.expired(provider)
        }
    }

    func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard
            let data = Data(base64Encoded: value),
            let object = try? UsageJSON.object(data),
            let seconds = UsageJSON.number(object["exp"])
        else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
