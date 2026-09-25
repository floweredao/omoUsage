import Foundation
import LocalAuthentication
import Security
import Testing
@testable import OmoUsage

@Suite
struct SecurityKeychainReaderTests {
    @Test
    func backgroundReadUsesNoninteractiveSecurityFrameworkQuery() throws {
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecSuccess,
                value: Data("reader-fixture-value".utf8)
            )
        )
        let reader = SecurityKeychainReader(api: api)

        #expect(
            try reader.value(
                service: "synthetic.reader.service",
                account: ""
            ) == "reader-fixture-value"
        )

        let query = try #require(api.copyQueries().only)
        #expect(
            query[key(kSecClass)] as? String
                == key(kSecClassGenericPassword)
        )
        #expect(
            query[key(kSecAttrService)] as? String
                == "synthetic.reader.service"
        )
        #expect(query[key(kSecAttrAccount)] == nil)
        #expect(query[key(kSecReturnData)] as? Bool == true)
        #expect(
            query[key(kSecMatchLimit)] as? String
                == key(kSecMatchLimitOne)
        )
        #expect(
            (query[key(kSecUseAuthenticationContext)] as? LAContext)?
                .interactionNotAllowed == true
        )
        #expect(
            query[
                SecurityKeychainAuthenticationUIPolicy.queryKey
            ] as? String
                == SecurityKeychainAuthenticationUIPolicy.failValue
        )
    }

    @Test
    func explicitAccountReadMatchesOnlyThatAccount() throws {
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecSuccess,
                value: Data("reader-fixture-value".utf8)
            )
        )
        let reader = SecurityKeychainReader(api: api)

        _ = try reader.value(
            service: "synthetic.reader.explicit",
            account: "fixture-account"
        )

        let query = try #require(api.copyQueries().only)
        #expect(
            query[key(kSecAttrAccount)] as? String
                == "fixture-account"
        )
    }

    @Test
    func itemNotFoundReturnsNilAndDeniedAccessRemainsTyped() throws {
        let missing = SecurityKeychainReader(
            api: RecordingSecurityItemAPI(
                copyResult: SecurityItemCopyResult(
                    status: errSecItemNotFound,
                    value: nil
                )
            )
        )
        #expect(
            try missing.value(
                service: "missing-service",
                account: ""
            ) == nil
        )

        let denied = SecurityKeychainReader(
            api: RecordingSecurityItemAPI(
                copyResult: SecurityItemCopyResult(
                    status: errSecInteractionNotAllowed,
                    value: nil
                )
            )
        )
        #expect(
            throws: KeychainReadError(
                status: errSecInteractionNotAllowed
            )
        ) {
            _ = try denied.value(
                service: "synthetic.reader.denied",
                account: ""
            )
        }
    }

    @Test
    func protectedClaudeReadRequiresExplicitSessionAuthorization()
        throws
    {
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecSuccess,
                value: Data("protected-reader-value".utf8)
            )
        )
        let session = ClaudeKeychainAccessSession(
            providerKeychain: AuthorizedClaudeTestKeychain()
        )
        let reader = SecurityKeychainReader(
            api: api,
            claudeSession: session
        )

        #expect(
            try reader.value(
                service: CredentialDiscovery.claudeLoginKeychainService,
                account: ""
            ) == nil
        )
        #expect(api.copyQueries().isEmpty)

        #expect(
            try session.authorizeClaude(api: api)
                == .authorized(
                    service:
                        CredentialDiscovery.claudeLoginKeychainService
                )
        )
        let authorizationQuery = try #require(
            api.copyQueries().only
        )
        #expect(
            authorizationQuery[
                key(kSecUseAuthenticationContext)
            ] == nil
        )
        #expect(
            authorizationQuery[
                SecurityKeychainAuthenticationUIPolicy.queryKey
            ] == nil
        )

        #expect(
            try reader.value(
                service: CredentialDiscovery.claudeLoginKeychainService,
                account: ""
            ) == "protected-reader-value"
        )
        #expect(api.copyQueries().count == 1)
    }

    @Test
    func cancelledClaudeAuthorizationDoesNotUnlockBackgroundReads()
        throws
    {
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecUserCanceled,
                value: nil
            )
        )
        let session = ClaudeKeychainAccessSession(
            providerKeychain: AuthorizedClaudeTestKeychain()
        )
        let reader = SecurityKeychainReader(
            api: api,
            claudeSession: session
        )

        #expect(
            try session.authorizeClaude(api: api) == .cancelled
        )
        #expect(
            try reader.value(
                service: CredentialDiscovery.claudeLoginKeychainService,
                account: ""
            ) == nil
        )
    }
}

@Suite
struct SecurityKeychainWriterTests {
    private let service = "synthetic.test.Claude Code-credentials"
    private let secret = "writer-test-secret-must-stay-private"

    @Test
    func ownedGenericPasswordUsesNativeAddCopyUpdateAndDelete() throws {
        let api = MutableSecurityItemAPI()
        let keychain = SecurityProviderKeychain(api: api)

        try keychain.set(secret, service: "com.omo.usage.synthetic", account: "openrouter/legacy")
        #expect(try keychain.value(service: "com.omo.usage.synthetic", account: "openrouter/legacy") == secret)
        try keychain.set("replacement", service: "com.omo.usage.synthetic", account: "openrouter/legacy")
        try keychain.remove(service: "com.omo.usage.synthetic", account: "openrouter/legacy")

        #expect(api.addCount == 1)
        #expect(api.updateCount == 1)
        #expect(api.deleteCount == 1)
        #expect(api.copyCount >= 3)
        #expect(api.lastAdd?[key(kSecAttrAccessible)] as? String == key(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly))
        #expect(api.lastAdd?[key(kSecAttrService)] as? String == "com.omo.usage.synthetic")
        #expect(api.lastAdd?[key(kSecAttrAccount)] as? String == "openrouter/legacy")
    }

    @Test(arguments: [errSecDuplicateItem, errSecInteractionNotAllowed])
    func ownedGenericPasswordPropagatesAmbiguousOrDeniedLookup(status: OSStatus) {
        let api = MutableSecurityItemAPI(copyStatus: status)
        #expect(throws: KeychainReadError(status: status)) {
            _ = try SecurityProviderKeychain(api: api).value(
                service: "com.omo.usage.synthetic",
                account: "zai/legacy"
            )
        }
        #expect(api.addCount == 0)
        #expect(api.updateCount == 0)
    }

    @Test
    func injectedFacadeResolvesEmptyAccountWithoutLaunchingProcess() throws {
        let reference = Data([0x01, 0x02, 0x03])
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecSuccess,
                value: [[
                    key(kSecAttrService): service,
                    key(kSecAttrAccount): "resolved-account",
                    key(kSecValuePersistentRef): reference
                ]]
            )
        )
        let writer = SecurityKeychainWriter(api: api)

        try writer.setValue(secret, service: service, account: "")

        let copy = try #require(api.copyQueries().only)
        #expect(copy[key(kSecClass)] as? String == key(kSecClassGenericPassword))
        #expect(copy[key(kSecAttrService)] as? String == service)
        #expect(copy[key(kSecAttrAccount)] == nil)
        #expect(copy[key(kSecReturnAttributes)] as? Bool == true)
        #expect(copy[key(kSecReturnPersistentRef)] as? Bool == true)
        #expect(copy[key(kSecMatchLimit)] as? String == key(kSecMatchLimitAll))
        #expect(
            (copy[key(kSecUseAuthenticationContext)] as? LAContext)?
                .interactionNotAllowed == true
        )
        #expect(copy[key(kSecValueData)] == nil)

        let update = try #require(api.updateCalls().only)
        #expect(update.query.count == 2)
        #expect(update.query[key(kSecValuePersistentRef)] as? Data == reference)
        #expect(
            (update.query[key(kSecUseAuthenticationContext)] as? LAContext)?
                .interactionNotAllowed == true
        )
        #expect(update.attributes.count == 1)
        #expect(
            update.attributes[key(kSecValueData)] as? Data
                == Data(secret.utf8)
        )
    }

    @Test
    func explicitAccountQueriesAndUpdatesOnlyTheExactItem() throws {
        let reference = Data([0x04, 0x05, 0x06])
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecSuccess,
                value: [[
                    key(kSecAttrService): service,
                    key(kSecAttrAccount): "claude-account",
                    key(kSecValuePersistentRef): reference
                ]]
            )
        )

        try SecurityKeychainWriter(api: api).setValue(
            secret,
            service: service,
            account: "claude-account"
        )

        let copy = try #require(api.copyQueries().only)
        #expect(copy[key(kSecAttrAccount)] as? String == "claude-account")
        let update = try #require(api.updateCalls().only)
        #expect(update.query[key(kSecValuePersistentRef)] as? Data == reference)
        #expect(update.query[key(kSecAttrService)] == nil)
        #expect(update.query[key(kSecAttrAccount)] == nil)
    }

    @Test
    func rotatedClaudeCredentialRefreshesAuthorizedSessionCache() throws {
        let store = AuthorizedClaudeTestKeychain()
        let session = ClaudeKeychainAccessSession(providerKeychain: store)
        let authorizationAPI = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecSuccess,
                value: Data("original-reader-value".utf8)
            )
        )
        _ = try session.authorizeClaude(api: authorizationAPI)
        let backgroundAPI = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecInteractionNotAllowed, value: nil
            )
        )
        try SecurityKeychainWriter(
            api: backgroundAPI, claudeSession: session
        ).setValue(
            "rotated-reader-value",
            service: CredentialDiscovery.claudeLoginKeychainService,
            account: ""
        )
        let reader = SecurityKeychainReader(
            api: backgroundAPI,
            claudeSession: ClaudeKeychainAccessSession(providerKeychain: store)
        )
        #expect(try reader.value(
            service: CredentialDiscovery.claudeLoginKeychainService, account: ""
        ) == "rotated-reader-value")
        #expect(backgroundAPI.copyQueries().isEmpty)
        #expect(backgroundAPI.updateCalls().isEmpty)
    }

    @Test
    func duplicateMatchesFailWithoutUpdating() throws {
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecSuccess,
                value: [
                    item(account: "first", reference: Data([0x01])),
                    item(account: "second", reference: Data([0x02]))
                ]
            )
        )
        let writer = SecurityKeychainWriter(api: api)

        #expect(throws: KeychainReadError(status: errSecDuplicateItem)) {
            try writer.setValue(secret, service: service, account: "")
        }
        #expect(api.updateCalls().isEmpty)
    }

    @Test
    func itemNotFoundFailsWithoutUpdating() throws {
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecItemNotFound,
                value: nil
            )
        )

        #expect(throws: KeychainReadError(status: errSecItemNotFound)) {
            try SecurityKeychainWriter(api: api).setValue(
                secret,
                service: service,
                account: ""
            )
        }
        #expect(api.updateCalls().isEmpty)
    }

    @Test
    func interactionDeniedFailsWithoutUpdating() throws {
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecInteractionNotAllowed,
                value: nil
            )
        )

        #expect(
            throws: KeychainReadError(status: errSecInteractionNotAllowed)
        ) {
            try SecurityKeychainWriter(api: api).setValue(
                secret,
                service: service,
                account: ""
            )
        }
        #expect(api.updateCalls().isEmpty)
    }

    @Test
    func updateErrorsNeverContainSecret() throws {
        let api = RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(
                status: errSecSuccess,
                value: [item(
                    account: "claude-account",
                    reference: Data([0x07])
                )]
            ),
            updateStatus: errSecAuthFailed
        )

        do {
            try SecurityKeychainWriter(api: api).setValue(
                secret,
                service: service,
                account: ""
            )
            Issue.record("Expected native update failure")
        } catch {
            #expect(error as? KeychainReadError
                == KeychainReadError(status: errSecAuthFailed))
            #expect(!String(describing: error).contains(secret))
            #expect(!String(reflecting: error).contains(secret))
        }
    }

    private func item(account: String, reference: Data) -> [String: Any] {
        [
            key(kSecAttrService): service,
            key(kSecAttrAccount): account,
            key(kSecValuePersistentRef): reference
        ]
    }
}

@Suite
struct ClaudeAuthorizedCredentialLifetimeTests {
    private let service = CredentialDiscovery.claudeLoginKeychainService
    private let now = Date(timeIntervalSince1970: 1_785_675_000)
    private let raw = #"{"claudeAiOauth":{"accessToken":"fixture-original","refreshToken":"fixture-refresh","expiresAt":1785685000000,"scopes":["user:inference"]},"unknown":"preserved"}"#

    @Test
    func authorizationNeverImportsTheInteractiveCLIsSharedGrant() throws {
        let session = ClaudeKeychainAccessSession(
            providerKeychain: AuthorizedClaudeTestKeychain()
        )
        #expect(
            try session.authorizeClaude(api: SharedClaudeGrantOnlyAPI())
                == .notFound
        )
    }

    @Test
    func authorizationSurvivesFreshSessionWithoutForeignKeychainAccess() throws {
        let store = AuthorizedClaudeTestKeychain()
        let session = ClaudeKeychainAccessSession(providerKeychain: store)
        #expect(try session.authorizeClaude(api: foreignAPI()) == .authorized(service: service))
        let background = foreignAPI(status: errSecInteractionNotAllowed)
        let fresh = ClaudeKeychainAccessSession(providerKeychain: store)
        let reader = SecurityKeychainReader(api: background, claudeSession: fresh)
        #expect(try reader.value(service: service, account: "") == raw)
        #expect(try reader.value(service: "Claude Safe Storage", account: "Claude Key") == nil)
        #expect(try reader.value(service: service, account: "another-account") == nil)
        #expect(background.copyQueries().isEmpty)
    }

    @Test
    func backgroundRotationPersistsAuthorizedMirrorAndSurvivesAnotherSession() throws {
        let store = AuthorizedClaudeTestKeychain()
        _ = try ClaudeKeychainAccessSession(providerKeychain: store)
            .authorizeClaude(api: foreignAPI())
        let background = foreignAPI(status: errSecInteractionNotAllowed)
        let fresh = ClaudeKeychainAccessSession(providerKeychain: store)
        let missing = URL(filePath: "/definitely/missing")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: SecurityKeychainReader(api: background, claudeSession: fresh),
            providerKeychain: store,
            keychainWriter: SecurityKeychainWriter(api: background, claudeSession: fresh)
        )
        let credential = try discovery.claude(now: now)
        // This is the logical authorized origin, not a foreign write target:
        // the real Security adapters below must perform zero foreign calls.
        #expect(credential.storage == .keychain(service: service, account: ""))
        try discovery.persistClaudeCredential(
            accessToken: "fixture-rotated", refreshToken: "fixture-rotated-refresh",
            expiresAt: now.addingTimeInterval(3600),
            source: credential.source, storage: credential.storage
        )
        let reader = SecurityKeychainReader(
            api: background,
            claudeSession: ClaudeKeychainAccessSession(providerKeychain: store)
        )
        let encoded = try #require(try reader.value(service: service, account: ""))
        let root = try UsageJSON.object(Data(encoded.utf8))
        let oauth = try #require(UsageJSON.object(root["claudeAiOauth"]))
        #expect(oauth["accessToken"] as? String == "fixture-rotated")
        #expect(oauth["refreshToken"] as? String == "fixture-rotated-refresh")
        #expect(oauth["expiresAt"] as? Double == now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        #expect(oauth["scopes"] as? [String] == ["user:inference"])
        #expect(root["unknown"] as? String == "preserved")
        #expect(background.copyQueries().isEmpty)
        #expect(background.updateCalls().isEmpty)
    }

    @Test
    func freshSessionProviderRotatesMirrorAndRestoresScopedWeeklyUsage() async throws {
        let store = AuthorizedClaudeTestKeychain()
        let expired = raw.replacingOccurrences(of: "1785685000000", with: "1000")
        _ = try ClaudeKeychainAccessSession(providerKeychain: store).authorizeClaude(
            api: RecordingSecurityItemAPI(copyResult: SecurityItemCopyResult(
                status: errSecSuccess, value: Data(expired.utf8)
            ))
        )
        let background = foreignAPI(status: errSecInteractionNotAllowed)
        let missing = URL(filePath: "/definitely/missing")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthorizedClaudeUsageURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }

        // Neither provider gets the session that authorized the foreign item.
        // The second also has to recover the first provider's token rotation.
        for _ in 0..<2 {
            let fresh = ClaudeKeychainAccessSession(providerKeychain: store)
            let discovery = CredentialDiscovery(
                paths: CredentialPaths(claude: missing, codex: missing),
                environment: [:],
                keychain: SecurityKeychainReader(api: background, claudeSession: fresh),
                providerKeychain: store,
                keychainWriter: SecurityKeychainWriter(api: background, claudeSession: fresh)
            )
            let provider = ClaudeUsageProvider(
                discovery: discovery,
                http: providerHTTPTestClient(session: transport),
                desktopUsageURL: missing,
                desktopSessionDiscovery: .unavailable,
                refreshCooldown: ClaudeRefreshCooldown(),
                usageCooldown: ClaudeUsageCooldown()
            )
            let usage = try await provider.fetch(now: now)
            let meters = usage.groups.flatMap(\.meters)
            #expect(usage.availability == .available)
            #expect(meters.map(\.id) == ["claude.session", "claude.week", "claude.week.model.fable"])
            #expect(meters.map(\.percentRemaining) == [90, 80, 56])
            #expect(try discovery.claude(now: now).accessToken == "fixture-provider-rotated")
        }
        #expect(background.copyQueries().isEmpty)
        #expect(background.updateCalls().isEmpty)
    }

    @Test
    func authorizationPersistenceFailureDoesNotPublishSessionCredential() throws {
        let store = AuthorizedClaudeTestKeychain(writeStatus: errSecDiskFull)
        let session = ClaudeKeychainAccessSession(providerKeychain: store)
        #expect(throws: KeychainReadError(status: errSecDiskFull)) {
            try session.authorizeClaude(api: foreignAPI())
        }
        let background = foreignAPI(status: errSecInteractionNotAllowed)
        for candidate in [session, ClaudeKeychainAccessSession(providerKeychain: store)] {
            #expect(try SecurityKeychainReader(api: background, claudeSession: candidate)
                .value(service: service, account: "") == nil)
        }
        #expect(background.copyQueries().isEmpty)
    }

    @Test
    func failedRotationDoesNotAdvanceMemoryOrTouchForeignCredential() throws {
        let store = AuthorizedClaudeTestKeychain()
        let session = ClaudeKeychainAccessSession(providerKeychain: store)
        _ = try session.authorizeClaude(api: foreignAPI())
        store.failWrites(status: errSecDiskFull)
        let background = foreignAPI(status: errSecInteractionNotAllowed)
        #expect(throws: KeychainReadError(status: errSecDiskFull)) {
            try SecurityKeychainWriter(api: background, claudeSession: session)
                .setValue("fixture-lost-rotation", service: service, account: "")
        }
        for candidate in [session, ClaudeKeychainAccessSession(providerKeychain: store)] {
            #expect(try SecurityKeychainReader(api: background, claudeSession: candidate)
                .value(service: service, account: "") == raw)
        }
        #expect(background.copyQueries().isEmpty)
        #expect(background.updateCalls().isEmpty)
    }

    @Test
    func deniedMirrorReadDoesNotWidenToEnvironmentCredential() throws {
        let store = AuthorizedClaudeTestKeychain()
        let session = ClaudeKeychainAccessSession(providerKeychain: store)
        _ = try session.authorizeClaude(api: foreignAPI())
        store.failReads(status: errSecInteractionNotAllowed)
        let background = foreignAPI(status: errSecInteractionNotAllowed)
        let missing = URL(filePath: "/definitely/missing")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "fixture-broader-token"],
            keychain: SecurityKeychainReader(api: background, claudeSession: session),
            providerKeychain: store
        )
        #expect(throws: KeychainReadError(status: errSecInteractionNotAllowed)) {
            try discovery.claude(now: now)
        }
        #expect(discovery.claudeCandidates(now: now).isEmpty)
        #expect(background.copyQueries().isEmpty)
    }

    @Test
    func deniedMirrorReadThrowsOriginalErrorInsteadOfPublishingCachedDesktopHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeDeniedMirrorHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = Data(
            #"{"version":2,"samples":[{"t":1785674940000,"org":"fixture-other-account","u":{"fh":64,"sd":7,"xu":78}}]}"#.utf8
        )
        let historyURL = directory.appending(path: "plan-usage-history.json")
        try history.write(to: historyURL)
        // A malformed or absent cache would hide the forbidden fallback.
        let cached = try ClaudeUsageParser.parseDesktopHistory(history, now: now)
        #expect(cached.availability == .available)
        #expect(!cached.groups.flatMap(\.meters).isEmpty)

        let store = AuthorizedClaudeTestKeychain()
        _ = try ClaudeKeychainAccessSession(providerKeychain: store)
            .authorizeClaude(api: foreignAPI())
        store.failReads(status: errSecInteractionNotAllowed)
        let background = foreignAPI(status: errSecInteractionNotAllowed)
        let missing = directory.appending(path: "missing.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthorizedClaudeUsageURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let provider = ClaudeUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(claude: missing, codex: missing),
                environment: [:],
                keychain: SecurityKeychainReader(
                    api: background,
                    claudeSession: ClaudeKeychainAccessSession(providerKeychain: store)
                ),
                providerKeychain: store,
                homeDirectory: directory
            ),
            http: providerHTTPTestClient(session: transport),
            desktopUsageURL: historyURL,
            desktopSessionDiscovery: ClaudeDesktopSessionDiscovery {
                Issue.record("OAuth Keychain denial must not enter Desktop discovery")
                return nil
            },
            refreshCooldown: ClaudeRefreshCooldown(),
            usageCooldown: ClaudeUsageCooldown()
        )
        await #expect(throws: KeychainReadError(status: errSecInteractionNotAllowed)) {
            try await provider.fetch(now: now)
        }
        #expect(background.copyQueries().isEmpty)
    }

    @Test(arguments: [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed])
    func deniedReauthorizationInvalidatesStaleCredentialWithoutWidening(status: OSStatus) throws {
        let store = AuthorizedClaudeTestKeychain()
        let session = ClaudeKeychainAccessSession(providerKeychain: store)
        _ = try session.authorizeClaude(api: foreignAPI())
        let denied = foreignAPI(status: status)
        #expect(try session.authorizeClaude(api: denied) == .cancelled)
        #expect(denied.copyQueries().count == 1)
        let reader = SecurityKeychainReader(api: denied, claudeSession: session)
        #expect(try reader.value(service: service, account: "") == nil)
        #expect(try reader.value(service: "Claude Safe Storage", account: "Claude Key") == nil)
        #expect(denied.copyQueries().count == 1)
    }

    @Test
    func officialOAuthAuthorizationNeverSearchesDesktopSafeStorage() throws {
        let api = foreignAPI(status: errSecItemNotFound)
        #expect(try ClaudeKeychainAccessSession(providerKeychain: AuthorizedClaudeTestKeychain())
            .authorizeClaude(api: api) == .notFound)
        #expect(api.copyQueries().compactMap { $0[key(kSecAttrService)] as? String }
            == [CredentialDiscovery.claudeLoginKeychainService])
    }

    @Test
    func explicitReauthorizationReplacesPersistedAndAlreadyReadCredential() throws {
        let store = AuthorizedClaudeTestKeychain()
        let session = ClaudeKeychainAccessSession(providerKeychain: store)
        _ = try session.authorizeClaude(api: foreignAPI())
        let background = foreignAPI(status: errSecInteractionNotAllowed)
        let earlierSession = ClaudeKeychainAccessSession(providerKeychain: store)
        let reader = SecurityKeychainReader(api: background, claudeSession: earlierSession)
        #expect(try reader.value(service: service, account: "") == raw)
        let replacement = raw.replacingOccurrences(of: "fixture-original", with: "fixture-new-login")
        _ = try session.authorizeClaude(api: RecordingSecurityItemAPI(
            copyResult: SecurityItemCopyResult(status: errSecSuccess, value: Data(replacement.utf8))
        ))
        #expect(try reader.value(service: service, account: "") == replacement)
        #expect(background.copyQueries().isEmpty)
    }

    private func foreignAPI(status: OSStatus = errSecSuccess) -> RecordingSecurityItemAPI {
        RecordingSecurityItemAPI(copyResult: SecurityItemCopyResult(
            status: status, value: status == errSecSuccess ? Data(raw.utf8) : nil
        ))
    }
}

private final class AuthorizedClaudeUsageURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: String
        if request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token" {
            guard let data = requestBodyData(request),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["refresh_token"] as? String == "fixture-refresh"
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
                return
            }
            body = #"{"access_token":"fixture-provider-rotated","refresh_token":"fixture-provider-refresh","expires_in":3600}"#
        } else if request.url?.absoluteString
            == "https://api.anthropic.com/api/oauth/usage"
                + "?cedar_ember=1&skip_spend=1",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-provider-rotated" {
            body = #"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":44,"resets_at":"2026-08-20T00:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"}}}]}"#
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct SharedClaudeGrantOnlyAPI: SecurityItemAPI {
    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        let isShared = query[key(kSecAttrService)] as? String
            == "Claude Code-credentials"
        return SecurityItemCopyResult(
            status: isShared ? errSecSuccess : errSecItemNotFound,
            value: isShared
                ? Data(#"{"claudeAiOauth":{"accessToken":"shared-cli","refreshToken":"shared-family"}}"#.utf8)
                : nil
        )
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        errSecUnimplemented
    }
}

private final class AuthorizedClaudeTestKeychain: ProviderKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writeStatus: OSStatus
    private var readStatus: OSStatus = errSecSuccess

    init(writeStatus: OSStatus = errSecSuccess) { self.writeStatus = writeStatus }

    func failWrites(status: OSStatus) { lock.withLock { writeStatus = status } }
    func failReads(status: OSStatus) { lock.withLock { readStatus = status } }

    func value(service: String, account: String) throws -> String? {
        try lock.withLock {
            guard readStatus == errSecSuccess else { throw KeychainReadError(status: readStatus) }
            return values["\(service)\u{0}\(account)"]
        }
    }

    func set(_ value: String, service: String, account: String) throws {
        try lock.withLock {
            guard writeStatus == errSecSuccess else { throw KeychainReadError(status: writeStatus) }
            values["\(service)\u{0}\(account)"] = value
        }
    }

    func remove(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: "\(service)\u{0}\(account)") }
    }
}

private final class MutableSecurityItemAPI: SecurityItemAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private let copyStatus: OSStatus?
    private(set) var copyCount = 0
    private(set) var addCount = 0
    private(set) var updateCount = 0
    private(set) var deleteCount = 0
    private(set) var lastAdd: [String: Any]?

    init(copyStatus: OSStatus? = nil) { self.copyStatus = copyStatus }

    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        lock.withLock {
            copyCount += 1
            if let copyStatus { return SecurityItemCopyResult(status: copyStatus, value: nil) }
            guard let stored else { return SecurityItemCopyResult(status: errSecItemNotFound, value: nil) }
            return SecurityItemCopyResult(status: errSecSuccess, value: stored)
        }
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            addCount += 1
            lastAdd = attributes
            stored = attributes[key(kSecValueData)] as? Data
            return errSecSuccess
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            updateCount += 1
            stored = attributes[key(kSecValueData)] as? Data
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            deleteCount += 1
            stored = nil
            return errSecSuccess
        }
    }
}

private struct SecurityItemUpdateCall: @unchecked Sendable {
    let query: [String: Any]
    let attributes: [String: Any]
}

private final class RecordingSecurityItemAPI: SecurityItemAPI, @unchecked Sendable {
    private let lock = NSLock()
    private let copyResult: SecurityItemCopyResult
    private let updateStatus: OSStatus
    private var copies: [[String: Any]] = []
    private var updates: [SecurityItemUpdateCall] = []

    init(
        copyResult: SecurityItemCopyResult,
        updateStatus: OSStatus = errSecSuccess
    ) {
        self.copyResult = copyResult
        self.updateStatus = updateStatus
    }

    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        lock.withLock { copies.append(query) }
        return copyResult
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        lock.withLock {
            updates.append(
                SecurityItemUpdateCall(query: query, attributes: attributes)
            )
        }
        return updateStatus
    }

    func copyQueries() -> [[String: Any]] {
        lock.withLock { copies }
    }

    func updateCalls() -> [SecurityItemUpdateCall] {
        lock.withLock { updates }
    }
}

private func key(_ value: CFString) -> String {
    value as String
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
