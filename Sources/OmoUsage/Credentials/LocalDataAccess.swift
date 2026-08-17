import Foundation
import Darwin

enum LocalDataAccessError: Error, Equatable {
    case commandFailed
    case unreadableOutput
    case timedOut
}

enum LocalDataAccess {
    static func commandValue(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 5
    ) throws -> String? {
        let result = try run(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        guard result.status == 0 else {
            return nil
        }
        guard let text = String(data: result.data, encoding: .utf8) else {
            throw LocalDataAccessError.unreadableOutput
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func sqliteValue(
        database: URL,
        sql: String,
        timeout: TimeInterval = 5
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: database.path) else {
            return nil
        }
        let result = try run(
            executable: URL(filePath: "/usr/bin/sqlite3"),
            arguments: ["-readonly", database.path, sql],
            timeout: timeout
        )
        guard result.status == 0 else {
            throw LocalDataAccessError.commandFailed
        }
        guard let text = String(data: result.data, encoding: .utf8) else {
            throw LocalDataAccessError.unreadableOutput
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> (status: Int32, data: Data) {
        if Task.isCancelled {
            throw CancellationError()
        }
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
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
            throw LocalDataAccessError.timedOut
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        return (
            process.terminationStatus,
            output.fileHandleForReading.readDataToEndOfFile()
        )
    }
}
