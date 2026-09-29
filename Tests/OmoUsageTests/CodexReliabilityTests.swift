import Foundation
import Testing
@testable import OmoUsage
import OmoUsageCore

@Suite(.serialized)
struct CodexReliabilityTests {
    private let hephaestusNow = Date(timeIntervalSince1970: 1_785_675_000)

    @Test
    func reportsPrimaryAndWeeklyResetWindows() throws {
        let payload = Data(
            """
            {
              "plan_type": "plus",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 37,
                  "limit_window_seconds": 18000,
                  "reset_at": 1785682200
                },
                "secondary_window": {
                  "used_percent": 12,
                  "limit_window_seconds": 604800,
                  "reset_at": 1786100400
                }
              }
            }
            """.utf8
        )

        let meters = try CodexUsageParser.parse(
            payload,
            now: hephaestusNow
        ).groups.flatMap(\.meters)

        #expect(meters.map(\.id) == ["codex.session", "codex.week"])
        #expect(meters.map(\.title) == ["세션 (5시간)", "주간"])
        #expect(meters.map(\.period) == [.session, .week])
        #expect(meters.map(\.percentRemaining) == [63, 88])
        #expect(
            meters.map(\.resetsAt?.timeIntervalSince1970)
                == [1_785_682_200, 1_786_100_400]
        )
        #expect(meters.map(\.showsMenuBarBadge) == [true, false])
    }

    @Test
    func whamRequestUsesCurrentMethodURLAndCredentialHeaders() async throws {
        try await hephaestusWithTemporaryDirectory { directory in
            HephaestusCodexRequestRecorder.shared.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [
                HephaestusCodexURLProtocol.self
            ]
            let provider = CodexUsageProvider(
                discovery: CredentialDiscovery(
                    paths: CredentialPaths(
                        claude: directory.appending(path: "missing-claude.json"),
                        codex: directory.appending(path: "missing-codex.json")
                    ),
                    environment: [:],
                    keychain: HephaestusCodexKeychain(values: [
                        "Codex Auth\u{0}": """
                        {
                          "auth_mode": "chatgpt",
                          "tokens": {
                            "access_token": "hephaestus-access-token",
                            "account_id": "hephaestus-account-id"
                          }
                        }
                        """
                    ]),
                    homeDirectory: directory
                ),
                http: ProviderHTTP(
                    session: URLSession(configuration: configuration)
                )
            )

            _ = try await provider.fetch(now: hephaestusNow)

            let request = try #require(
                HephaestusCodexRequestRecorder.shared.snapshot()
            )
            #expect(request.method == "GET")
            #expect(
                request.url
                    == "https://chatgpt.com/backend-api/wham/usage"
            )
            #expect(request.authorization == "Bearer hephaestus-access-token")
            #expect(request.accountID == "hephaestus-account-id")
        }
    }

    @Test(arguments: CodexRefreshBoundary.allCases)
    func refreshesOnlyInsideFiveMinuteJWTBoundary(
        boundary: CodexRefreshBoundary
    ) async throws {
        try await hephaestusWithTemporaryDirectory { directory in
            let storedAccess = HephaestusCodexOAuthFixture.jwt(
                expiresAt: hephaestusNow.addingTimeInterval(
                    TimeInterval(boundary.offset)
                )
            )
            HephaestusCodexOAuthExchange.shared.reset(
                acceptedUsageTokens: [storedAccess, "rotated-codex-access"]
            )
            let writer = HephaestusCodexRecordingWriter()
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                keychainCredential: HephaestusCodexOAuthFixture.credential(
                    accessToken: storedAccess,
                    refreshToken: "stored-codex-refresh"
                ),
                writer: writer
            )

            _ = try await provider.fetch(now: hephaestusNow)

            #expect(
                HephaestusCodexOAuthExchange.shared.tokenRequestCount()
                    == boundary.expectedRefreshes
            )
            #expect(
                HephaestusCodexOAuthExchange.shared.usageTokens()
                    == [
                        boundary.expectedRefreshes == 1
                            ? "rotated-codex-access"
                            : storedAccess
                    ]
            )
        }
    }

    @Test
    func refreshRequestUsesOfficialFormContractAndPlusSafeEncoding()
        async throws
    {
        try await hephaestusWithTemporaryDirectory { directory in
            let storedAccess = HephaestusCodexOAuthFixture.jwt(
                expiresAt: hephaestusNow.addingTimeInterval(240)
            )
            HephaestusCodexOAuthExchange.shared.reset(
                acceptedUsageTokens: [storedAccess, "rotated-codex-access"]
            )
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                keychainCredential: HephaestusCodexOAuthFixture.credential(
                    accessToken: storedAccess,
                    refreshToken: "fixture+refresh token"
                ),
                writer: HephaestusCodexRecordingWriter()
            )

            _ = try await provider.fetch(now: hephaestusNow)

            #expect(
                HephaestusCodexOAuthExchange.shared.lastTokenRequest()
                    == HephaestusCodexTokenRequest(
                        url: "https://auth.openai.com/oauth/token",
                        method: "POST",
                        contentType: "application/x-www-form-urlencoded",
                        fields: [
                            "grant_type": "refresh_token",
                            "refresh_token": "fixture+refresh token",
                            "client_id":
                                "app_EMoamEEZ73f0CkXaXp7hrann"
                        ],
                        plusWasPercentEncoded: true
                    )
            )
        }
    }

    @Test
    func rotatedKeychainCodexCredentialPersistsToAppSnapshot()
        async throws
    {
        try await hephaestusWithTemporaryDirectory { directory in
            let storedAccess = HephaestusCodexOAuthFixture.jwt(
                expiresAt: hephaestusNow.addingTimeInterval(240)
            )
            HephaestusCodexOAuthExchange.shared.reset(
                acceptedUsageTokens: [storedAccess, "rotated-codex-access"]
            )
            let writer = HephaestusCodexRecordingWriter()
            let snapshots = HephaestusCodexSnapshotKeychain()
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                keychainCredential: HephaestusCodexOAuthFixture.credential(
                    accessToken: storedAccess,
                    refreshToken: "stored-codex-refresh"
                ),
                writer: writer,
                snapshots: snapshots
            )

            _ = try await provider.fetch(now: hephaestusNow)

            #expect(writer.lastWrite() == nil)
            let stored = try #require(
                try ProviderCredentialSnapshotStore(keychain: snapshots).snapshot(
                    for: AccountProviderID(accountID: .legacy, providerID: .codex)
                )
            )
            #expect(stored.accessToken == "rotated-codex-access")
            #expect(stored.refreshToken == "rotated-codex-refresh")
            #expect(stored.accountReference == "fixture-codex-account")
        }
    }

    @Test
    func rotatedCodexCredentialPersistsToOriginatingFile()
        async throws
    {
        try await hephaestusWithTemporaryDirectory { directory in
            let storedAccess = HephaestusCodexOAuthFixture.jwt(
                expiresAt: hephaestusNow.addingTimeInterval(240)
            )
            HephaestusCodexOAuthExchange.shared.reset(
                acceptedUsageTokens: [storedAccess, "rotated-codex-access"]
            )
            let auth = directory.appending(path: "auth.json")
            try Data(
                HephaestusCodexOAuthFixture.credential(
                    accessToken: storedAccess,
                    refreshToken: "stored-codex-refresh"
                ).utf8
            ).write(to: auth)
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                codexFile: auth,
                writer: HephaestusCodexRecordingWriter()
            )

            _ = try await provider.fetch(now: hephaestusNow)

            try expectRotatedCodexCredential(Data(contentsOf: auth))
        }
    }

    @Test
    func omittedRotatedTokensPreserveStoredCodexValues() async throws {
        try await hephaestusWithTemporaryDirectory { directory in
            let storedAccess = HephaestusCodexOAuthFixture.jwt(
                expiresAt: hephaestusNow.addingTimeInterval(240)
            )
            HephaestusCodexOAuthExchange.shared.reset(
                acceptedUsageTokens: [storedAccess, "rotated-codex-access"],
                includesRotatedRefreshAndID: false
            )
            let auth = directory.appending(path: "auth.json")
            try Data(
                HephaestusCodexOAuthFixture.credential(
                    accessToken: storedAccess,
                    refreshToken: "stored-codex-refresh"
                ).utf8
            ).write(to: auth)
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                codexFile: auth,
                writer: HephaestusCodexRecordingWriter()
            )

            _ = try await provider.fetch(now: hephaestusNow)

            let root = try #require(
                try? UsageJSON.object(Data(contentsOf: auth))
            )
            let tokens = try #require(UsageJSON.object(root["tokens"]))
            #expect(
                tokens["refresh_token"] as? String
                    == "stored-codex-refresh"
            )
            #expect(tokens["id_token"] as? String == "stored-codex-id")
        }
    }

    @Test
    func persistenceFailurePreventsCodexUsageRequest() async throws {
        try await hephaestusWithTemporaryDirectory { directory in
            let storedAccess = HephaestusCodexOAuthFixture.jwt(
                expiresAt: hephaestusNow.addingTimeInterval(240)
            )
            HephaestusCodexOAuthExchange.shared.reset(
                acceptedUsageTokens: [storedAccess, "rotated-codex-access"]
            )
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                keychainCredential: HephaestusCodexOAuthFixture.credential(
                    accessToken: storedAccess,
                    refreshToken: "stored-codex-refresh"
                ),
                writer: HephaestusCodexFailingWriter(),
                snapshots: nil
            )

            await #expect(throws: (any Error).self) {
                try await provider.fetch(now: hephaestusNow)
            }
            #expect(
                HephaestusCodexOAuthExchange.shared.usageTokens().isEmpty
            )
        }
    }

    @Test
    func usageAuthenticationFailureRefreshesOnceAndRetries() async throws {
        try await hephaestusWithTemporaryDirectory { directory in
            HephaestusCodexOAuthExchange.shared.reset(
                acceptedUsageTokens: ["rotated-codex-access"]
            )
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                keychainCredential: HephaestusCodexOAuthFixture.credential(
                    accessToken: "stored-codex-access",
                    refreshToken: "stored-codex-refresh"
                ),
                writer: HephaestusCodexRecordingWriter()
            )

            let failure = await captureCodexFailure {
                _ = try await provider.fetch(now: hephaestusNow)
            }

            #expect(failure == nil)
            #expect(
                HephaestusCodexOAuthExchange.shared.tokenRequestCount() == 1
            )
            #expect(
                HephaestusCodexOAuthExchange.shared.usageTokens() == [
                    "stored-codex-access",
                    "rotated-codex-access"
                ]
            )
        }
    }

    @Test
    func rejectedFileCandidateFallsBackToKeychainCandidate() async throws {
        try await hephaestusWithTemporaryDirectory { directory in
            HephaestusCodexOAuthExchange.shared.reset(
                acceptedUsageTokens: ["keychain-codex-access"]
            )
            let auth = directory.appending(path: "auth.json")
            try Data(
                HephaestusCodexOAuthFixture.credential(
                    accessToken: "file-codex-access",
                    refreshToken: nil
                ).utf8
            ).write(to: auth)
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                codexFile: auth,
                keychainCredential: HephaestusCodexOAuthFixture.credential(
                    accessToken: "keychain-codex-access",
                    refreshToken: nil
                ),
                writer: HephaestusCodexRecordingWriter()
            )

            let failure = await captureCodexFailure {
                _ = try await provider.fetch(now: hephaestusNow)
            }

            #expect(failure == nil)
            #expect(
                HephaestusCodexOAuthExchange.shared.usageTokens() == [
                    "file-codex-access",
                    "keychain-codex-access"
                ]
            )
        }
    }

    @Test(arguments: [500, 429])
    func nonAuthenticationFailureDoesNotTryNextCodexCandidate(
        status: Int
    ) async throws {
        try await hephaestusWithTemporaryDirectory { directory in
            HephaestusCodexOAuthExchange.shared.reset(
                usageStatus: status
            )
            let auth = directory.appending(path: "auth.json")
            try Data(
                HephaestusCodexOAuthFixture.credential(
                    accessToken: "file-codex-access",
                    refreshToken: nil
                ).utf8
            ).write(to: auth)
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                codexFile: auth,
                keychainCredential: HephaestusCodexOAuthFixture.credential(
                    accessToken: "keychain-codex-access",
                    refreshToken: nil
                ),
                writer: HephaestusCodexRecordingWriter()
            )

            let failure = await captureCodexFailure {
                _ = try await provider.fetch(now: hephaestusNow)
            }

            #expect(
                failure as? ProviderTransportError
                    == .requestFailed(.codex, status)
            )
            #expect(
                Set(HephaestusCodexOAuthExchange.shared.usageTokens())
                    == ["file-codex-access"]
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDoesNotTryNextCodexCandidate() async throws {
        let started = HephaestusCodexOAuthExchange.shared.reset(hangs: true)
        try await hephaestusWithTemporaryDirectory { directory in
            let auth = directory.appending(path: "auth.json")
            try Data(
                HephaestusCodexOAuthFixture.credential(
                    accessToken: "file-codex-access",
                    refreshToken: nil
                ).utf8
            ).write(to: auth)
            let provider = try HephaestusCodexOAuthFixture.provider(
                home: directory,
                codexFile: auth,
                keychainCredential: HephaestusCodexOAuthFixture.credential(
                    accessToken: "keychain-codex-access",
                    refreshToken: nil
                ),
                writer: HephaestusCodexRecordingWriter()
            )
            let task = Task {
                try await provider.fetch(now: hephaestusNow)
            }
            var iterator = started.makeAsyncIterator()
            _ = await iterator.next()

            task.cancel()
            let failure = await captureCodexFailure {
                _ = try await task.value
            }

            #expect(failure is CancellationError)
            #expect(
                HephaestusCodexOAuthExchange.shared.usageTokens()
                    == ["file-codex-access"]
            )
        }
    }

    @Test
    func malformedPreferredCodexFileFallsThroughToValidKeychainCandidate() throws {
        try hephaestusWithTemporaryDirectory { directory in
            let codexFile = directory.appending(path: "auth.json")
            try Data("{malformed".utf8).write(to: codexFile)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(
                    claude: directory.appending(path: "missing-claude.json"),
                    codex: codexFile
                ),
                environment: [:],
                keychain: HephaestusCodexKeychain(values: [
                    "Codex Auth\u{0}": """
                    {
                      "auth_mode": "chatgpt",
                      "tokens": {
                        "access_token": "hephaestus-keychain-token",
                        "account_id": "hephaestus-keychain-account"
                      }
                    }
                    """
                ]),
                homeDirectory: directory
            )

            let credential = try discovery.codex(now: hephaestusNow)

            #expect(credential.source == .keychain)
            #expect(credential.accessToken == "hephaestus-keychain-token")
            #expect(credential.accountID == "hephaestus-keychain-account")
        }
    }

    enum CodexRefreshBoundary: String, CaseIterable, Sendable {
        case fourMinutes
        case sixMinutes

        var offset: Int {
            switch self {
            case .fourMinutes: 240
            case .sixMinutes: 360
            }
        }

        var expectedRefreshes: Int {
            switch self {
            case .fourMinutes: 1
            case .sixMinutes: 0
            }
        }
    }

    private func expectRotatedCodexCredential(_ data: Data) throws {
        let root = try #require(try? UsageJSON.object(data))
        let tokens = try #require(UsageJSON.object(root["tokens"]))
        #expect(tokens["access_token"] as? String == "rotated-codex-access")
        #expect(tokens["refresh_token"] as? String == "rotated-codex-refresh")
        #expect(tokens["id_token"] as? String == "rotated-codex-id")
        #expect(tokens["unknown_token"] as? String == "preserved-token")
        #expect(root["unknown_root"] as? String == "preserved-root")
        #expect(
            root["last_refresh"] as? String
                == hephaestusNow.ISO8601Format()
        )
    }

    private func captureCodexFailure(
        _ operation: () async throws -> Void
    ) async -> (any Error)? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func hephaestusWithTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "HephaestusCodexReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func hephaestusWithTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "HephaestusCodexReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private enum HephaestusCodexOAuthFixture {
    static let usageBody = Data(
        """
        {
          "plan_type": "plus",
          "rate_limit": {
            "secondary_window": {
              "used_percent": 12,
              "limit_window_seconds": 604800,
              "reset_at": 1786100400
            }
          }
        }
        """.utf8
    )

    static func provider(
        home: URL,
        codexFile: URL? = nil,
        keychainCredential: String? = nil,
        writer: any KeychainWriting,
        snapshots: (any ProviderKeychain)? = HephaestusCodexSnapshotKeychain()
    ) throws -> CodexUsageProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HephaestusCodexOAuthURLProtocol.self
        ]
        let missing = home.appending(path: "missing.json")
        return CodexUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: missing,
                    codex: codexFile ?? missing
                ),
                environment: [:],
                keychain: HephaestusCodexOAuthKeychain(
                    credential: keychainCredential
                ),
                providerKeychain: snapshots,
                keychainWriter: writer,
                homeDirectory: home
            ),
            http: providerHTTPTestClient(
                session: URLSession(configuration: configuration)
            )
        )
    }

    static func credential(
        accessToken: String,
        refreshToken: String?
    ) -> String {
        let refresh = refreshToken.map {
            #", "refresh_token": "\#($0)""#
        } ?? ""
        return """
        {
          "auth_mode": "chatgpt",
          "unknown_root": "preserved-root",
          "tokens": {
            "access_token": "\(accessToken)"\(refresh),
            "id_token": "stored-codex-id",
            "account_id": "fixture-codex-account",
            "unknown_token": "preserved-token"
          }
        }
        """
    }

    static func jwt(expiresAt: Date) -> String {
        let header = base64URL(["alg": "none"])
        let payload = base64URL([
            "exp": Int(expiresAt.timeIntervalSince1970)
        ])
        return "\(header).\(payload).fixture-signature"
    }

    private static func base64URL(_ object: [String: Any]) -> String {
        let data = (
            try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
        ) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct HephaestusCodexOAuthKeychain: KeychainReading {
    let credential: String?

    func value(service: String, account: String) throws -> String? {
        service == "Codex Auth" && account.isEmpty ? credential : nil
    }
}

private struct HephaestusCodexTokenRequest: Equatable, Sendable {
    let url: String
    let method: String
    let contentType: String?
    let fields: [String: String]
    let plusWasPercentEncoded: Bool
}

private final class HephaestusCodexOAuthExchange: @unchecked Sendable {
    static let shared = HephaestusCodexOAuthExchange()

    private let lock = NSLock()
    private var acceptedTokens = Set<String>()
    private var fixedUsageStatus: Int?
    private var hangs = false
    private var includesRotatedRefreshAndID = true
    private var tokenRequests: [HephaestusCodexTokenRequest] = []
    private var recordedUsageTokens: [String] = []
    private var startedContinuation: AsyncStream<Void>.Continuation?

    @discardableResult
    func reset(
        acceptedUsageTokens: Set<String> = [],
        usageStatus: Int? = nil,
        hangs: Bool = false,
        includesRotatedRefreshAndID: Bool = true
    ) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        lock.withLock {
            acceptedTokens = acceptedUsageTokens
            fixedUsageStatus = usageStatus
            self.hangs = hangs
            self.includesRotatedRefreshAndID = includesRotatedRefreshAndID
            tokenRequests = []
            recordedUsageTokens = []
            startedContinuation = continuation
        }
        return stream
    }

    func recordTokenRequest(
        _ request: HephaestusCodexTokenRequest
    ) {
        lock.withLock { tokenRequests.append(request) }
    }

    func usageStatus(for token: String) -> (status: Int, hangs: Bool) {
        lock.withLock {
            recordedUsageTokens.append(token)
            if hangs {
                startedContinuation?.yield()
                startedContinuation?.finish()
                return (200, true)
            }
            if let fixedUsageStatus {
                return (fixedUsageStatus, false)
            }
            return (acceptedTokens.contains(token) ? 200 : 401, false)
        }
    }

    func shouldIncludeRotatedRefreshAndID() -> Bool {
        lock.withLock { includesRotatedRefreshAndID }
    }

    func tokenRequestCount() -> Int {
        lock.withLock { tokenRequests.count }
    }

    func lastTokenRequest() -> HephaestusCodexTokenRequest? {
        lock.withLock { tokenRequests.last }
    }

    func usageTokens() -> [String] {
        lock.withLock { recordedUsageTokens }
    }
}

private final class HephaestusCodexSnapshotKeychain: ProviderKeychain,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(service: String, account: String) throws -> String? {
        lock.withLock { values[service + "/" + account] }
    }

    func set(_ value: String, service: String, account: String) throws {
        lock.withLock { values[service + "/" + account] = value }
    }

    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: service + "/" + account) }
    }
}

private final class HephaestusCodexRecordingWriter: KeychainWriting,
    @unchecked Sendable
{
    struct Write: Sendable {
        let value: String
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var write: Write?

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        lock.withLock {
            write = Write(value: value, service: service, account: account)
        }
    }

    func lastWrite() -> Write? {
        lock.withLock { write }
    }
}

private struct HephaestusCodexFailingWriter: KeychainWriting {
    struct Failure: Error {}

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        throw Failure()
    }
}

private final class HephaestusCodexOAuthURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            respond(status: 500, body: Data())
            return
        }
        if url.absoluteString == "https://auth.openai.com/oauth/token" {
            handleTokenRequest(url: url)
            return
        }
        let authorization = request.value(
            forHTTPHeaderField: "Authorization"
        ) ?? ""
        let token = authorization.hasPrefix("Bearer ")
            ? String(authorization.dropFirst("Bearer ".count))
            : ""
        let outcome = HephaestusCodexOAuthExchange.shared.usageStatus(
            for: token
        )
        guard !outcome.hangs else { return }
        respond(
            status: outcome.status,
            body: outcome.status == 200
                ? HephaestusCodexOAuthFixture.usageBody
                : Data(#"{"error":"request failed"}"#.utf8)
        )
    }

    override func stopLoading() {}

    private func handleTokenRequest(url: URL) {
        let raw = requestBodyData(request).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? ""
        HephaestusCodexOAuthExchange.shared.recordTokenRequest(
            HephaestusCodexTokenRequest(
                url: url.absoluteString,
                method: request.httpMethod ?? "",
                contentType: request.value(
                    forHTTPHeaderField: "Content-Type"
                ),
                fields: formFields(raw),
                plusWasPercentEncoded:
                    raw.contains("fixture%2Brefresh")
            )
        )
        var response: [String: Any] = [
            "access_token": "rotated-codex-access",
            "expires_in": 3_600
        ]
        if HephaestusCodexOAuthExchange.shared
            .shouldIncludeRotatedRefreshAndID()
        {
            response["refresh_token"] = "rotated-codex-refresh"
            response["id_token"] = "rotated-codex-id"
        }
        respond(
            status: 200,
            body: (
                try? JSONSerialization.data(withJSONObject: response)
            ) ?? Data()
        )
    }

    private func formFields(_ raw: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: raw.split(separator: "&").map {
            pair in
            let parts = pair.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let key = String(parts[0]).removingPercentEncoding ?? ""
            let encoded = parts.count == 2 ? String(parts[1]) : ""
            let value = encoded.replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding ?? ""
            return (key, value)
        })
    }

    private func respond(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct HephaestusCodexKeychain: KeychainReading {
    let values: [String: String]

    func value(service: String, account: String) throws -> String? {
        values["\(service)\u{0}\(account)"]
    }
}

private struct HephaestusCodexRecordedRequest: Sendable {
    let method: String?
    let url: String?
    let authorization: String?
    let accountID: String?
}

private final class HephaestusCodexRequestRecorder: @unchecked Sendable {
    static let shared = HephaestusCodexRequestRecorder()

    private let lock = NSLock()
    private var request: HephaestusCodexRecordedRequest?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        request = nil
    }

    func record(_ urlRequest: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        request = HephaestusCodexRecordedRequest(
            method: urlRequest.httpMethod,
            url: urlRequest.url?.absoluteString,
            authorization: urlRequest.value(
                forHTTPHeaderField: "Authorization"
            ),
            accountID: urlRequest.value(
                forHTTPHeaderField: "ChatGPT-Account-Id"
            )
        )
    }

    func snapshot() -> HephaestusCodexRecordedRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private final class HephaestusCodexURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        HephaestusCodexRequestRecorder.shared.record(request)
        let body = Data(
            """
            {
              "plan_type": "plus",
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 12,
                  "limit_window_seconds": 604800,
                  "reset_at": 1786100400
                }
              }
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
