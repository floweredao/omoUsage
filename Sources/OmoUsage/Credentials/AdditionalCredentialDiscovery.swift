import OmoUsageCore
import Foundation
import Darwin

extension CredentialDiscovery {
    /// Shipped Grok CLI client id, used when the credential store carries
    /// no explicit or account-key-encoded value.
    static let grokDefaultClientID =
        "b1a00492-073a-47ea-816f-4c329264a828"

    func cursor(
        accountID: AccountID = .legacy,
        now: Date
    ) throws -> DiscoveredCredential {
        guard accountID == .legacy else {
            let credential = try snapshotCredential(
                for: .cursor,
                accountID: accountID,
                now: now
            )
            // Cursor states the deadline inside the token, which is what
            // the local path enforces; the snapshot enforces the same.
            try rejectExpiredJWT(
                credential.accessToken,
                provider: .cursor,
                now: now
            )
            return credential
        }
        let database = home.appending(
            components: "Library",
            "Application Support",
            "Cursor",
            "User",
            "globalStorage",
            "state.vscdb"
        )
        let databaseAccessToken = try cursorDatabaseValue(
            database,
            key: "cursorAuth/accessToken"
        )
        let keychainAccessToken = cursorKeychainValue(
            "cursor-access-token"
        )
        if let databaseAccessToken {
            if let keychainAccessToken {
                let membership = try cursorDatabaseValue(
                    database,
                    key: "cursorAuth/stripeMembershipType"
                )
                if
                    membership == "free",
                    cursorSubjectsDiffer(
                        databaseAccessToken,
                        keychainAccessToken
                    )
                {
                    return try cursorKeychainCredential(
                        keychainAccessToken,
                        now: now
                    )
                }
            }
            let refreshToken = try cursorDatabaseValue(
                database,
                key: "cursorAuth/refreshToken"
            )
            try rejectExpiredJWT(
                databaseAccessToken,
                provider: .cursor,
                now: now
            )
            return DiscoveredCredential(
                provider: .cursor,
                accessToken: databaseAccessToken,
                refreshToken: refreshToken,
                accountID: nil,
                planName: nil,
                expiresAt: nil,
                source: .file
            )
        }
        guard let keychainAccessToken else {
            throw CredentialDiscoveryError.notFound(.cursor)
        }
        return try cursorKeychainCredential(
            keychainAccessToken,
            now: now
        )
    }

    func copilot(
        accountID: AccountID = .legacy
    ) throws -> DiscoveredCredential {
        guard accountID == .legacy else {
            // A GitHub token carries no deadline the app can read, so the
            // snapshot is used as captured until the API rejects it.
            return try snapshotCredential(
                for: .copilot,
                accountID: accountID,
                now: .distantPast,
                allowingExpired: true
            )
        }
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
        let hostsText = try? String(contentsOf: hosts, encoding: .utf8)
        if
            let hostsText,
            let token = githubYAMLValue(hostsText, key: "oauth_token")
        {
            return credential(.copilot, token: token, source: .file)
        }
        if
            let token = githubCLIKeychainToken(
                user: hostsText.flatMap {
                    githubYAMLValue($0, key: "user")
                }
            )
        {
            return credential(
                .copilot,
                token: token,
                source: .keychain
            )
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

    func devin(
        accountID: AccountID = .legacy
    ) throws -> DiscoveredCredential {
        guard accountID == .legacy else {
            // The captured snapshot keeps the account's own server URL in
            // `accountID`, so a self-hosted account keeps its host.
            return try snapshotCredential(
                for: .devin,
                accountID: accountID,
                now: .distantPast,
                allowingExpired: true
            )
        }
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
                        accountID: devinServerURL(text),
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

    func grok(
        accountID: AccountID = .legacy,
        now: Date
    ) throws -> DiscoveredCredential {
        guard accountID == .legacy else {
            return try grokSnapshotCredential(
                accountID: accountID,
                now: now
            )
        }
        let resolution = try resolveGrokCandidates(now: now)
        if let best = resolution.candidates.first {
            return best
        }
        if let failure = resolution.failure {
            throw failure
        }
        throw CredentialDiscoveryError.malformed(.grok)
    }

    /// Every usable account, in the sorted key order the runtime should
    /// try them. `grok(now:)` returns the first of these.
    func grokCandidates(
        accountID: AccountID = .legacy,
        now: Date
    ) -> [DiscoveredCredential] {
        guard accountID == .legacy else {
            return (try? grokSnapshotCredential(
                accountID: accountID,
                now: now
            )).map { [$0] } ?? []
        }
        return ((try? resolveGrokCandidates(now: now))?.candidates) ?? []
    }

    /// Mirrors the local store's rule: an expired entry is only usable
    /// when a refresh token can revive it.
    private func grokSnapshotCredential(
        accountID: AccountID,
        now: Date
    ) throws -> DiscoveredCredential {
        let credential = try snapshotCredential(
            for: .grok,
            accountID: accountID,
            now: now,
            allowingExpired: true
        )
        if
            let expiresAt = credential.expiresAt,
            expiresAt <= now,
            credential.refreshToken == nil
        {
            throw CredentialDiscoveryError.expired(.grok)
        }
        return credential
    }

    private func resolveGrokCandidates(
        now: Date
    ) throws -> (
        candidates: [DiscoveredCredential],
        failure: CredentialDiscoveryError?
    ) {
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
        var candidates: [DiscoveredCredential] = []
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
            // The CLI stores the client id explicitly, encodes it after
            // `::` in the account key, or omits it entirely and relies on
            // the shipped default.
            let suffixClientID = key.range(of: "::").map {
                String(key[$0.upperBound...])
            }?.nonBlank
            let clientID = (
                entry["oidc_client_id"] as? String
                ?? entry["client_id"] as? String
            )?.nonBlank
                ?? suffixClientID
                ?? Self.grokDefaultClientID
            let expiresAt = UsageJSON.date(
                entry["expires_at"] ?? entry["expires"]
            ) ?? jwtExpiration(token)
            if
                let expiresAt,
                expiresAt <= now,
                refreshToken == nil
            {
                candidateError = .expired(.grok)
                continue
            }
            candidates.append(
                DiscoveredCredential(
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
            )
        }
        return (candidates, candidateError)
    }

    func opencode(
        accountID: AccountID = .legacy
    ) throws -> DiscoveredCredential {
        if
            let store = ProviderAPIKeyStore.live(
                for: .opencode,
                accountID: accountID,
                home: home,
                environment: environment,
                keychain: providerKeychain
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
            } catch {
                candidateError = .malformed(.opencode)
            }
        }
        do {
            if try openCodeDatabase() != nil {
                return credential(.opencode, token: "local", source: .file)
            }
        } catch {
            throw CredentialDiscoveryError.malformed(.opencode)
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

    func openCodeDatabase() throws -> URL? {
        let directory = openCodeDataDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return nil
        }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).compactMap(OpenCodeDatabaseCandidate.init(url:))
            .sorted {
                ($0.name == "opencode.db") != ($1.name == "opencode.db")
                    ? $0.name == "opencode.db"
                    : $0.canonicalPath < $1.canonicalPath
            }
        var paths = Set<String>()
        var identities = Set<OpenCodeDatabaseIdentity>()
        let unique = candidates.filter {
            paths.insert($0.canonicalPath).inserted
                && identities.insert($0.identity).inserted
        }
        return unique.first(where: {
            $0.name == "opencode.db"
        })?.url ?? unique.first?.url
    }

    var openCodeDataDirectory: URL {
        if
            let value = environment["OPENCODE_DATA_DIR"]?.nonBlank,
            value.hasPrefix("/")
        {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
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
                environment: environment,
                keychain: providerKeychain
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

private struct OpenCodeDatabaseCandidate {
    let name: String
    let url: URL
    let canonicalPath: String
    let identity: OpenCodeDatabaseIdentity

    init?(url: URL) {
        guard
            url.lastPathComponent.hasPrefix("opencode"),
            url.pathExtension == "db"
        else {
            return nil
        }
        let canonicalURL = url.resolvingSymlinksInPath()
            .standardizedFileURL
        guard let identity = OpenCodeDatabaseIdentity(url: canonicalURL) else {
            return nil
        }
        self.name = url.lastPathComponent
        self.url = canonicalURL
        self.canonicalPath = canonicalURL.path
        self.identity = identity
    }
}

private struct OpenCodeDatabaseIdentity: Hashable {
    let device: UInt64
    let inode: UInt64

    init?(url: URL) {
        var information = stat()
        guard
            stat(url.path, &information) == 0,
            information.st_mode & S_IFMT == S_IFREG
        else {
            return nil
        }
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
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

    func githubCLIKeychainToken(user: String?) -> String? {
        var accounts: [String] = []
        if let user {
            accounts.append(user)
        }
        accounts.append("")
        for account in accounts {
            guard
                let value = try? keychain.value(
                    service: "gh:github.com",
                    account: account
                )
            else {
                continue
            }
            if let token = goKeyringToken(value) {
                return token
            }
        }
        return nil
    }

    func goKeyringToken(_ value: String?) -> String? {
        guard let trimmed = value?.nonBlank else {
            return nil
        }
        let prefix = "go-keyring-base64:"
        guard trimmed.hasPrefix(prefix) else {
            return trimmed
        }
        guard
            let data = Data(
                base64Encoded: String(trimmed.dropFirst(prefix.count))
            ),
            let decoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return decoded.nonBlank
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
            return tomlScalar(parts[1])
        }
        return nil
    }

    /// Reads one TOML scalar. Trimming quote characters off both ends is
    /// not enough: `"https://host/"  # note` keeps the closing quote and
    /// the comment, and that string is no longer a parsable URL.
    func tomlScalar(_ raw: some StringProtocol) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard let quote = value.first else {
            return nil
        }
        guard quote == "\"" || quote == "'" else {
            return value.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0].trimmingCharacters(in: .whitespaces).nonBlank
        }
        let body = value.dropFirst()
        guard let closing = body.firstIndex(of: quote) else {
            return nil
        }
        let remainder = body[body.index(after: closing)...]
            .trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty || remainder.hasPrefix("#") else {
            return nil
        }
        return String(body[..<closing]).nonBlank
    }

    /// Devin writes the server with or without a trailing slash; the host
    /// allow-list in the provider stays authoritative either way.
    func devinServerURL(_ text: String) -> String? {
        guard var value = tomlValue(text, key: "api_server_url") else {
            return nil
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value.nonBlank
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
        guard
            let payload = jwtPayload(token),
            let seconds = UsageJSON.number(payload["exp"])
        else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    func jwtSubject(_ token: String) -> String? {
        guard let payload = jwtPayload(token) else {
            return nil
        }
        return (payload["sub"] as? String)?.nonBlank
    }

    func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard
            let data = Data(base64Encoded: value),
            let object = try? UsageJSON.object(data)
        else {
            return nil
        }
        return object
    }

    func cursorDatabaseValue(
        _ database: URL,
        key: String
    ) throws -> String? {
        try LocalDataAccess.sqliteValue(
            database: database,
            sql: """
            SELECT value FROM ItemTable
            WHERE key = '\(key)' LIMIT 1;
            """
        )?.nonBlank
    }

    func cursorKeychainValue(_ service: String) -> String? {
        do {
            return try keychain.value(
                service: service,
                account: ""
            )?.nonBlank
        } catch {
            return nil
        }
    }

    func cursorSubjectsDiffer(
        _ first: String,
        _ second: String
    ) -> Bool {
        guard
            let firstSubject = jwtSubject(first),
            let secondSubject = jwtSubject(second)
        else {
            return false
        }
        return firstSubject != secondSubject
    }

    func cursorKeychainCredential(
        _ accessToken: String,
        now: Date
    ) throws -> DiscoveredCredential {
        try rejectExpiredJWT(
            accessToken,
            provider: .cursor,
            now: now
        )
        return DiscoveredCredential(
            provider: .cursor,
            accessToken: accessToken,
            refreshToken: cursorKeychainValue("cursor-refresh-token"),
            accountID: nil,
            planName: nil,
            expiresAt: nil,
            source: .keychain
        )
    }
}

private extension String {
    var nonBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
