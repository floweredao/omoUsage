import Foundation
import LocalAuthentication
import Security
import Testing
@testable import OmoUsage

@Suite
struct SecurityKeychainWriterTests {
    private let service = "synthetic.test.Claude Code-credentials"
    private let secret = "writer-test-secret-must-stay-private"

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
