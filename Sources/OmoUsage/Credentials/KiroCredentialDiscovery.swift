import OmoUsageCore
import Foundation

extension CredentialDiscovery {
    typealias KiroSQLiteValue = @Sendable (URL, String) throws -> String?

    func kiro(
        accountID: AccountID = .legacy,
        now: Date,
        sqliteValue: KiroSQLiteValue = { database, sql in
            try LocalDataAccess.sqliteValue(database: database, sql: sql)
        }
    ) throws -> DiscoveredCredential {
        let identity = AccountProviderID(accountID: accountID, providerID: .kiro)
        if let snapshot = try snapshotStore.snapshot(for: identity) {
            let credential = snapshot.credential(storage: .accountSnapshot(identity))
            try Self.validateKiroCredential(credential, now: now)
            return credential
        }
        guard accountID == .legacy else {
            throw CredentialDiscoveryError.notFound(.kiro)
        }
        return try mutableKiroCredential(now: now, sqliteValue: sqliteValue)
    }

    /// Capture always reads the official CLI's current profile, not the pinned account.
    func mutableKiroCredential(
        now: Date,
        sqliteValue: KiroSQLiteValue = { database, sql in
            try LocalDataAccess.sqliteValue(database: database, sql: sql)
        }
    ) throws -> DiscoveredCredential {
        let directory: URL
        if let override = environment["KIRO_DATA_DIR"], override.hasPrefix("/") {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = homeDirectory.appendingPathComponent("Library/Application Support/kiro-cli")
        }
        let database = directory.appendingPathComponent("data.sqlite3")
        let tokenJSON: String?
        let profileJSON: String?
        do {
            tokenJSON = try sqliteValue(database, "SELECT value FROM auth_kv WHERE key='kirocli:odic:token';")
            profileJSON = try sqliteValue(database, "SELECT value FROM state WHERE key='api.codewhisperer.profile';")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CredentialDiscoveryError.malformed(.kiro)
        }
        guard let tokenJSON, let profileJSON else {
            throw CredentialDiscoveryError.notFound(.kiro)
        }
        struct Token: Decodable {
            let access_token: String
            let expires_at: String
        }
        struct Profile: Decodable {
            let arn: String
        }
        guard
            let token = try? JSONDecoder().decode(Token.self, from: Data(tokenJSON.utf8)),
            let profile = try? JSONDecoder().decode(Profile.self, from: Data(profileJSON.utf8))
        else {
            throw CredentialDiscoveryError.malformed(.kiro)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = fractional.date(from: token.expires_at)
            ?? ISO8601DateFormatter().date(from: token.expires_at)
        else {
            throw CredentialDiscoveryError.malformed(.kiro)
        }
        let credential = DiscoveredCredential(
            provider: .kiro,
            accessToken: token.access_token,
            refreshToken: nil,
            accountID: profile.arn,
            planName: nil,
            expiresAt: expiry,
            source: .file
        )
        try Self.validateKiroCredential(credential, now: now)
        return credential
    }

    static func kiroEndpoint(profileARN: String) throws -> URL {
        let components = profileARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard
            components.count == 6,
            components[0] == "arn",
            components[1] == "aws",
            components[2] == "codewhisperer",
            components[5].hasPrefix("profile/"),
            components[5].count > "profile/".count,
            profileARN.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else {
            throw CredentialDiscoveryError.malformed(.kiro)
        }
        switch components[3] {
        case "us-east-1":
            return URL(string: "https://codewhisperer.us-east-1.amazonaws.com/")!
        case "eu-central-1":
            return URL(string: "https://q.eu-central-1.amazonaws.com/")!
        default:
            throw CredentialDiscoveryError.malformed(.kiro)
        }
    }

    private static func validateKiroCredential(_ credential: DiscoveredCredential, now: Date) throws {
        guard
            !credential.accessToken.isEmpty,
            credential.accessToken.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
            let profileARN = credential.accountID,
            let expiry = credential.expiresAt,
            expiry.timeIntervalSince1970.isFinite
        else {
            throw CredentialDiscoveryError.malformed(.kiro)
        }
        _ = try kiroEndpoint(profileARN: profileARN)
        guard expiry > now else {
            throw CredentialDiscoveryError.expired(.kiro)
        }
    }
}
