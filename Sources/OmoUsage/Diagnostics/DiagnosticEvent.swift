import OmoUsageCore
import Foundation

enum DiagnosticStatus: String, Codable, Sendable {
    case failed
    case authenticationRequired = "authentication_required"
    case requestRejected = "request_rejected"
    case transient
    case invalidResponse = "invalid_response"
    case schemaChanged = "schema_changed"
    case timedOut = "timed_out"
    case recovered
    case blocked
}

enum DiagnosticCategory: String, Codable, Sendable {
    case accountRegistry = "account_registry"
    case accountOrderPersistence = "account_order_persistence"
    case accountVisibilityPersistence = "account_visibility_persistence"
    case snapshotPublish = "snapshot_publish"
    case webServer = "web_server"
    case webListener = "web_listener"
    case providerRefresh = "provider_refresh"
    case credentialPersistence = "credential_persistence"
    case desktopSession = "desktop_session"
    case singleInstance = "single_instance"
    case activationPolicy = "activation_policy"
    case fixture = "fixture"
}

struct DiagnosticEvent: Codable, Equatable, Sendable {
    static let currentSchemaRevision = 1

    let provider: ProviderID?
    let status: DiagnosticStatus
    let category: DiagnosticCategory
    let schemaRevision: Int
    let contractRevision: Int?
    let accountOrdinal: Int?
    let occurredAt: Date

    init(
        provider: ProviderID? = nil,
        status: DiagnosticStatus,
        category: DiagnosticCategory,
        contractRevision: Int? = nil,
        accountOrdinal: Int? = nil,
        occurredAt: Date = Date()
    ) {
        self.provider = provider
        self.status = status
        self.category = category
        schemaRevision = Self.currentSchemaRevision
        self.contractRevision = contractRevision
        self.accountOrdinal = accountOrdinal
        self.occurredAt = occurredAt
    }
}
