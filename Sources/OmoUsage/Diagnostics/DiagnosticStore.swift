import Darwin
import Foundation

final class DiagnosticStore: @unchecked Sendable {
    static let shared = DiagnosticStore()

    private let lock = NSLock()
    private let capacity: Int
    private var storedEvents: [DiagnosticEvent] = []

    init(capacity: Int = 200) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var events: [DiagnosticEvent] {
        lock.withLock { storedEvents }
    }

    func record(_ event: DiagnosticEvent) {
        let event = DiagnosticRedactor.sanitize(event)
        lock.withLock {
            storedEvents.append(event)
            if storedEvents.count > capacity {
                storedEvents.removeFirst(storedEvents.count - capacity)
            }
        }
    }

    func record(
        error: any Error,
        provider: ProviderID? = nil,
        category: DiagnosticCategory,
        accountOrdinal: Int? = nil,
        occurredAt: Date = Date()
    ) {
        record(
            DiagnosticRedactor.event(
                error: error,
                provider: provider,
                category: category,
                accountOrdinal: accountOrdinal,
                occurredAt: occurredAt
            )
        )
    }

    func exportData() throws -> Data {
        let allowlisted = events.map(DiagnosticRedactor.sanitize)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(allowlisted)
    }

    func export(to destination: URL) throws {
        let data = try exportData()
        let temporary = destination.deletingLastPathComponent().appending(
            path: ".omo-diagnostics-\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            _ = unlink(temporary.path)
            throw error
        }
    }
}

enum DiagnosticExportError: Error, Equatable {
    case writeFailed
}

struct DiagnosticExportAction {
    let store: DiagnosticStore
    let chooseDestination: () -> URL?

    func perform() -> Result<URL?, DiagnosticExportError> {
        guard let destination = chooseDestination() else {
            return .success(nil)
        }
        do {
            try store.export(to: destination)
            return .success(destination)
        } catch {
            return .failure(.writeFailed)
        }
    }
}
