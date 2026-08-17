import Foundation
import Security
import Darwin

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
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        var arguments = [
            "find-generic-password",
            "-s",
            service
        ]
        if !account.isEmpty {
            arguments.append(contentsOf: ["-a", account])
        }
        arguments.append("-w")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }
        try process.run()
        guard
            finished.wait(
                timeout: .now() + max(0.01, timeout)
            ) == .success
        else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            throw KeychainReadError(status: errSecInteractionNotAllowed)
        }
        if process.terminationStatus == 44 {
            return nil
        }
        guard process.terminationStatus == 0 else {
            throw KeychainReadError(
                status: OSStatus(process.terminationStatus)
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
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
