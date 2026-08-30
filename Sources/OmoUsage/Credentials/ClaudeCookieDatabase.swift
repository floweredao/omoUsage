import Foundation
import SQLite3

enum ClaudeCookieDatabase {
    private static let names = """
        'sessionKey',
        'cf_clearance',
        '__cf_bm'
        """

    static func read(at url: URL) throws -> [(String, Data)] {
        do {
            return try readDirectly(at: url)
        } catch {
            return try readWithSystemSQLite(at: url)
        }
    }

    private static func readDirectly(
        at url: URL
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
        while sqlite3_step(statement) == SQLITE_ROW {
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
        }
        return cookies
    }

    private static func readWithSystemSQLite(
        at url: URL
    ) throws -> [(String, Data)] {
        let query = """
            SELECT name, hex(encrypted_value) AS encryptedHex
            FROM cookies
            WHERE host_key IN ('claude.ai', '.claude.ai')
              AND name IN (\(names))
            ORDER BY name
            """
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = ["-json", url.path(), query]
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClaudeDesktopSessionError.databaseUnavailable
        }
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let rows = try JSONDecoder().decode([CookieRow].self, from: data)
        return try rows.map { row in
            guard let encrypted = Data(hexadecimal: row.encryptedHex) else {
                throw ClaudeDesktopSessionError.malformedCookie
            }
            return (row.name, encrypted)
        }
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
