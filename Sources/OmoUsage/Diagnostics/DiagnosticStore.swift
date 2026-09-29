import OmoUsageCore
import Darwin
import Foundation
import os

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
        record(event, httpStatus: nil)
    }

    private func record(_ event: DiagnosticEvent, httpStatus: Int?) {
        let event = DiagnosticRedactor.sanitize(event)
        Self.log(event, httpStatus: httpStatus)
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
        var httpStatus: Int?
        if case let ProviderTransportError.requestFailed(_, status) = error {
            httpStatus = status
        }
        record(
            DiagnosticRedactor.event(
                error: error,
                provider: provider,
                category: category,
                accountOrdinal: accountOrdinal,
                occurredAt: occurredAt
            ),
            httpStatus: httpStatus
        )
    }

    /// Mirrors a sanitized event to the unified log. Only allowlisted enum
    /// values and a status code reach it: never tokens, payloads, or paths.
    private static func log(_ event: DiagnosticEvent, httpStatus: Int?) {
        let logger = Logger(
            subsystem: "com.omo.usage",
            category: event.category.rawValue
        )
        let provider = event.provider?.rawValue ?? "none"
        let status = event.status.rawValue
        if let httpStatus {
            logger.error(
                "provider=\(provider, privacy: .public) status=\(status, privacy: .public) http=\(httpStatus, privacy: .public)"
            )
        } else {
            logger.error(
                "provider=\(provider, privacy: .public) status=\(status, privacy: .public)"
            )
        }
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
