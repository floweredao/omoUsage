import Foundation
import Security

struct SecurityKeychainReader: KeychainReading {
    let executable: URL
    let timeout: TimeInterval

    init(
        executable: URL = URL(filePath: "/usr/bin/security"),
        timeout: TimeInterval = 3
    ) {
        self.executable = executable
        self.timeout = timeout
    }

    func value(service: String, account: String) throws -> String? {
        var arguments = [
            "find-generic-password",
            "-s",
            service
        ]
        if !account.isEmpty {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")
        let result: BoundedProcessResult
        do {
            result = try BoundedProcessRunner().run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        } catch BoundedProcessError.timedOut {
            throw KeychainReadError(status: errSecInteractionNotAllowed)
        }
        if result.status == 44 {
            return nil
        }
        guard result.status == 0 else {
            throw KeychainReadError(status: OSStatus(result.status))
        }
        let data = result.standardOutput
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainReadError(status: errSecDecode)
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct KeychainReadError: Error, Equatable {
    let status: OSStatus
}
