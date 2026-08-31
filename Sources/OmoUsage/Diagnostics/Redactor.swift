import OmoUsageCore
import Foundation

enum DiagnosticRedactor {
    static func event(
        error: any Error,
        provider: ProviderID? = nil,
        category: DiagnosticCategory,
        accountOrdinal: Int? = nil,
        occurredAt: Date = Date()
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            provider: provider,
            status: status(for: error),
            category: category,
            contractRevision: contractRevision(for: error),
            accountOrdinal: accountOrdinal,
            occurredAt: occurredAt
        )
    }

    static func sanitize(_ event: DiagnosticEvent) -> DiagnosticEvent {
        DiagnosticEvent(
            provider: event.provider,
            status: event.status,
            category: event.category,
            contractRevision: sanitizedRevision(event.contractRevision),
            accountOrdinal: sanitizedOrdinal(event.accountOrdinal),
            occurredAt: event.occurredAt
        )
    }

    private static func contractRevision(for error: any Error) -> Int? {
        guard case let ProviderContractError.schemaChanged(
            _, _, contractRevision
        ) = error else {
            return nil
        }
        return sanitizedRevision(contractRevision)
    }

    private static func status(for error: any Error) -> DiagnosticStatus {
        if case ProviderContractError.schemaChanged = error {
            return .schemaChanged
        }
        if let transport = error as? ProviderTransportError {
            switch transport {
            case .authenticationRequired:
                return .authenticationRequired
            case .requestFailed:
                return .requestRejected
            case .transientTransport:
                return .transient
            case .invalidResponse, .invalidContentType, .responseTooLarge,
                 .invalidJSON:
                return .invalidResponse
            case .operationTimedOut:
                return .timedOut
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timedOut
            case .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed,
                 .notConnectedToInternet:
                return .transient
            default:
                break
            }
        }
        return .failed
    }

    private static func sanitizedRevision(_ revision: Int?) -> Int? {
        guard let revision, (1...10_000).contains(revision) else {
            return nil
        }
        return revision
    }

    private static func sanitizedOrdinal(_ ordinal: Int?) -> Int? {
        guard let ordinal, (1...10_000).contains(ordinal) else {
            return nil
        }
        return ordinal
    }
}
