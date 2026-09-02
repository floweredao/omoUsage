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
                service: "Claude Safe Storage",
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
                == "Claude Safe Storage"
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
            service: "Claude Code-credentials",
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
                service: "Claude Safe Storage",
                account: ""
            )
        }
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
