import Foundation
import SQLite3

enum ClaudeCookieDatabase {
    private static let names = """
        'sessionKey',
        'cf_clearance',
        '__cf_bm'
        """

    static func read(
        at url: URL,
        timeout: TimeInterval = 5
    ) throws -> [(String, Data)] {
        do {
            return try readDirectly(at: url, timeout: timeout)
        } catch {
            return try readWithSystemSQLite(at: url, timeout: timeout)
        }
    }

    private static func readDirectly(
        at url: URL,
        timeout: TimeInterval
    ) throws -> [(String, Data)] {
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                url.path(),
                &database,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK,
            let database
        else {
            throw ClaudeDesktopSessionError.databaseUnavailable
        }
        defer { sqlite3_close(database) }
        let deadline = ClaudeSQLiteDeadline(timeout: timeout)
        sqlite3_busy_timeout(
            database,
            Int32(max(0, min(timeout * 1_000, Double(Int32.max))))
        )
        sqlite3_progress_handler(
            database,
            1_000,
            { context in
                guard let context else { return 1 }
                let deadline = Unmanaged<ClaudeSQLiteDeadline>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                return deadline.hasExpired ? 1 : 0
            },
            Unmanaged.passUnretained(deadline).toOpaque()
        )
        defer { sqlite3_progress_handler(database, 0, nil, nil) }

        let query = """
            SELECT name, encrypted_value
            FROM cookies
            WHERE host_key IN ('claude.ai', '.claude.ai')
              AND name IN (\(names))
            ORDER BY name
            """
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                query,
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement
        else {
            throw ClaudeDesktopSessionError.databaseUnavailable
        }
        defer { sqlite3_finalize(statement) }

        var cookies: [(String, Data)] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard
                let nameBytes = sqlite3_column_text(statement, 0),
                let encryptedBytes = sqlite3_column_blob(statement, 1)
            else {
                throw ClaudeDesktopSessionError.malformedCookie
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            cookies.append(
                (
                    String(cString: nameBytes),
                    Data(bytes: encryptedBytes, count: byteCount)
                )
            )
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw ClaudeDesktopSessionError.databaseUnavailable
        }
        return cookies
    }

    private static func readWithSystemSQLite(
        at url: URL,
        timeout: TimeInterval
    ) throws -> [(String, Data)] {
        let query = """
            SELECT name, hex(encrypted_value) AS encryptedHex
            FROM cookies
            WHERE host_key IN ('claude.ai', '.claude.ai')
              AND name IN (\(names))
            ORDER BY name
            """
        let result: BoundedProcessResult
        do {
            result = try BoundedProcessRunner().run(
                executable: URL(filePath: "/usr/bin/sqlite3"),
                arguments: ["-readonly", "-json", url.path(), query],
                timeout: timeout
            )
        } catch {
            throw ClaudeDesktopSessionError.databaseUnavailable
        }
        guard result.status == 0 else {
            throw ClaudeDesktopSessionError.databaseUnavailable
        }
        let data = result.standardOutput
        let rows = try JSONDecoder().decode([CookieRow].self, from: data)
        return try rows.map { row in
            guard let encrypted = Data(hexadecimal: row.encryptedHex) else {
                throw ClaudeDesktopSessionError.malformedCookie
            }
            return (row.name, encrypted)
        }
    }
}

private final class ClaudeSQLiteDeadline {
    private let deadline: TimeInterval

    init(timeout: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
    }

    var hasExpired: Bool {
        ProcessInfo.processInfo.systemUptime >= deadline
    }
}

private struct CookieRow: Decodable {
    let name: String
    let encryptedHex: String
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        self = data
    }
}
