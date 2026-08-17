import CommonCrypto
import Foundation

enum ClaudeDesktopSessionError: Error, Equatable {
    case databaseUnavailable
    case keychainUnavailable
    case cookiesUnavailable
    case malformedCookie
    case decryptionFailed
    case organizationUnavailable
}

extension ClaudeDesktopSessionDiscovery {
    static func live(
        homeDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser,
        keychain: any KeychainReading =
            ClaudeSafeStorageKeychainReader()
    ) -> ClaudeDesktopSessionDiscovery {
        let supportDirectory = homeDirectory.appending(
            components: "Library",
            "Application Support",
            "Claude"
        )
        return ClaudeDesktopSessionDiscovery {
            try ClaudeDesktopSessionReader(
                cookieDatabaseURL: supportDirectory
                    .appending(path: "Cookies"),
                historyURL: supportDirectory
                    .appending(path: "plan-usage-history.json"),
                keychain: keychain
            ).current()
        }
    }
}

struct ClaudeDesktopSessionReader {
    let cookieDatabaseURL: URL
    let historyURL: URL
    let keychain: any KeychainReading

    func current() throws -> ClaudeDesktopSession? {
        guard
            let password = try keychain.value(
                service: "Claude Safe Storage",
                account: ""
            )
        else {
            throw ClaudeDesktopSessionError.keychainUnavailable
        }
        let cookies = try ClaudeCookieDatabase.read(
            at: cookieDatabaseURL
        )
        guard !cookies.isEmpty else {
            throw ClaudeDesktopSessionError.cookiesUnavailable
        }
        let cookieHeader = try cookies.map { name, encryptedValue in
            let value = try ClaudeDesktopCookieDecryptor.decrypt(
                encryptedValue,
                password: password
            )
            return "\(name)=\(value)"
        }.joined(separator: "; ")
        return ClaudeDesktopSession(
            organizationID: try organizationID(),
            cookieHeader: cookieHeader
        )
    }

    private func organizationID() throws -> String {
        let data = try Data(contentsOf: historyURL)
        let history = try JSONDecoder().decode(
            ClaudeDesktopHistory.self,
            from: data
        )
        guard
            let organizationID = history.samples
                .max(by: { $0.timestamp < $1.timestamp })?
                .organizationID,
            !organizationID.isEmpty
        else {
            throw ClaudeDesktopSessionError.organizationUnavailable
        }
        return organizationID
    }
}

enum ClaudeDesktopCookieDecryptor {
    private static let prefix = Data("v10".utf8)
    private static let salt = Data("saltysalt".utf8)

    static func decrypt(
        _ encryptedValue: Data,
        password: String
    ) throws -> String {
        guard
            encryptedValue.starts(with: prefix),
            encryptedValue.count > prefix.count + kCCBlockSizeAES128
        else {
            throw ClaudeDesktopSessionError.malformedCookie
        }
        let key = try deriveKey(password: password)
        let vectorStart = prefix.count
        let payloadStart = vectorStart + kCCBlockSizeAES128
        let initializationVector = encryptedValue[
            vectorStart..<payloadStart
        ]
        let payload = encryptedValue[payloadStart...]
        var output = Data(
            count: payload.count + kCCBlockSizeAES128
        )
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            key.withUnsafeBytes { keyBuffer in
                initializationVector.withUnsafeBytes { vectorBuffer in
                    payload.withUnsafeBytes { payloadBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            key.count,
                            vectorBuffer.baseAddress,
                            payloadBuffer.baseAddress,
                            payload.count,
                            outputBuffer.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw ClaudeDesktopSessionError.decryptionFailed
        }
        output.removeSubrange(outputLength...)
        guard output.count > kCCBlockSizeAES128 else {
            throw ClaudeDesktopSessionError.decryptionFailed
        }
        let cookieValue = output.dropFirst(kCCBlockSizeAES128)
        guard let value = String(data: cookieValue, encoding: .utf8) else {
            throw ClaudeDesktopSessionError.decryptionFailed
        }
        return value
    }

    private static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        var key = Data(count: 16)
        let keyLength = key.count
        let status = key.withUnsafeMutableBytes { keyBuffer in
            salt.withUnsafeBytes { saltBuffer in
                passwordData.withUnsafeBytes { passwordBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?
                            .assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1_003,
                        keyBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw ClaudeDesktopSessionError.decryptionFailed
        }
        return key
    }
}

private struct ClaudeDesktopHistory: Decodable {
    let samples: [Sample]

    struct Sample: Decodable {
        let timestamp: Double
        let organizationID: String

        enum CodingKeys: String, CodingKey {
            case timestamp = "t"
            case organizationID = "org"
        }
    }
}
