import Foundation
import Security

/// Writes a generic-password item back through `/usr/bin/security`, the same
/// binary `SecurityKeychainReader` reads with, so an item created by another
/// app (Claude Code) is updated under the keychain grant the user already
/// gave that binary instead of prompting again for OmoUsage itself.
struct SecurityKeychainWriter: KeychainWriting {
    let executable: URL
    let timeout: TimeInterval

    init(
        executable: URL = URL(filePath: "/usr/bin/security"),
        timeout: TimeInterval = 5
    ) {
        self.executable = executable
        self.timeout = timeout
    }

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        let resolvedAccount = account.isEmpty
            ? try existingAccount(service: service)
            : account
        let status = try run(
            arguments: [
                "add-generic-password",
                "-U",
                "-s", service,
                "-a", resolvedAccount,
                "-w", value
            ]
        ).status
        guard status == 0 else {
            throw KeychainReadError(status: OSStatus(status))
        }
    }

    /// `add-generic-password -U` matches on service *and* account, so the
    /// existing account has to be read back first or the update would create
    /// a second item instead of replacing the stored credential.
    private func existingAccount(service: String) throws -> String {
        let result = try run(
            arguments: ["find-generic-password", "-s", service]
        )
        guard result.status == 0 else {
            throw KeychainReadError(status: OSStatus(result.status))
        }
        guard
            let line = result.output
                .split(separator: "\n")
                .first(where: {
                    $0.contains("\"acct\"<blob>=\"")
                }),
            let start = line.range(of: "\"acct\"<blob>=\""),
            let end = line.range(
                of: "\"",
                range: start.upperBound..<line.endIndex
            )
        else {
            throw KeychainReadError(status: errSecItemNotFound)
        }
        let account = String(line[start.upperBound..<end.lowerBound])
        guard !account.isEmpty else {
            throw KeychainReadError(status: errSecItemNotFound)
        }
        return account
    }

    private func run(
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard
            finished.wait(timeout: .now() + max(0.01, timeout)) == .success
        else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
            throw KeychainReadError(status: errSecInteractionNotAllowed)
        }
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }
}
