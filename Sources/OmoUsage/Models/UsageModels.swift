import Foundation

enum UsagePeriod: String, Codable, Sendable {
    case session
    case week
    case extra
}

struct UsageMeter: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let period: UsagePeriod
    let percentRemaining: Int
    let resetsAt: Date?
    let resetText: String?
    let showsMenuBarBadge: Bool

    init(
        id: String,
        title: String,
        period: UsagePeriod,
        percentRemaining: Int,
        resetsAt: Date? = nil,
        resetText: String? = nil,
        showsMenuBarBadge: Bool = false
    ) {
        self.id = id
        self.title = title
        self.period = period
        self.percentRemaining = percentRemaining
        self.resetsAt = resetsAt
        self.resetText = resetText
        self.showsMenuBarBadge = showsMenuBarBadge
    }
}

struct UsageGroup: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String?
    let meters: [UsageMeter]
    let creditText: String?
}

enum ProviderAvailability: String, Equatable, Codable, Sendable {
    case available
    case authenticationRequired
    case unavailable
    case failed
    case schemaChanged

    var koreanLabel: String? {
        switch self {
        case .available: nil
        case .authenticationRequired: "인증 필요"
        case .unavailable: "사용할 수 없음"
        case .failed: "새로고침 실패"
        case .schemaChanged: "스키마 변경됨"
        }
    }
}

/// Whether displayed usage came from the most recent refresh attempt.
enum UsageFreshness: String, Codable, Sendable {
    case current
    case stale
}

/// Why the most recent refresh attempt failed while its values were kept.
enum ProviderRefreshFailure: String, Codable, Sendable, CaseIterable {
    case network
    case service
    case schema
    case credential
    case unknown
}

enum AccountLabel {
    static let defaultValue = "Default Account"
    static let maximumLength = 128

    static func sanitized(_ rawValue: String?) -> String {
        guard let rawValue else { return defaultValue }
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !value.isEmpty,
            value.count <= maximumLength,
            !value.contains("@"),
            !value.contains("/"),
            !value.contains("\\"),
            !value.hasPrefix("~")
        else {
            return defaultValue
        }
        return value
    }
}

enum DashboardAccountIdentityRule {
    static func showsAlias(
        for usage: ProviderUsage,
        sameProviderCount: Int
    ) -> Bool {
        usage.accountID != .legacy || sameProviderCount > 1
    }
}

struct ProviderUsage: Identifiable, Equatable, Codable, Sendable {
    var id: AccountProviderID { accountProviderID }
    var accountProviderID: AccountProviderID {
        AccountProviderID(accountID: accountID, providerID: provider)
    }

    let provider: ProviderID
    let accountID: AccountID
    let accountLabel: String
    let planName: String
    let groups: [UsageGroup]
    let availability: ProviderAvailability
    let lastSuccessfulAt: Date?
    let lastRefreshAttemptAt: Date?
    let refreshFailure: ProviderRefreshFailure?

    var updatedAt: Date? { lastSuccessfulAt }

    /// Displayed values are stale once an attempt failed after the last
    /// success and the previous values were kept on screen.
    var freshness: UsageFreshness {
        refreshFailure == nil ? .current : .stale
    }

    init(
        provider: ProviderID,
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue,
        planName: String,
        groups: [UsageGroup],
        availability: ProviderAvailability,
        lastSuccessfulAt: Date?,
        lastRefreshAttemptAt: Date? = nil,
        refreshFailure: ProviderRefreshFailure? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
        self.accountLabel = AccountLabel.sanitized(accountLabel)
        self.planName = planName
        self.groups = groups
        self.availability = availability
        self.lastSuccessfulAt = lastSuccessfulAt
        self.lastRefreshAttemptAt = lastRefreshAttemptAt
        self.refreshFailure = refreshFailure
    }

    init(
        provider: ProviderID,
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue,
        planName: String,
        groups: [UsageGroup],
        availability: ProviderAvailability,
        updatedAt: Date?
    ) {
        self.init(
            provider: provider,
            accountID: accountID,
            accountLabel: accountLabel,
            planName: planName,
            groups: groups,
            availability: availability,
            lastSuccessfulAt: updatedAt
        )
    }

    func assigningAccount(
        id accountID: AccountID,
        label accountLabel: String
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            accountID: accountID,
            accountLabel: accountLabel,
            planName: planName,
            groups: groups,
            availability: availability,
            lastSuccessfulAt: lastSuccessfulAt,
            lastRefreshAttemptAt: lastRefreshAttemptAt,
            refreshFailure: refreshFailure
        )
    }

    /// Records the outcome of a refresh attempt without ever moving
    /// `lastSuccessfulAt` forward on failure.
    func recordingRefreshAttempt(
        at attemptedAt: Date,
        failure: ProviderRefreshFailure? = nil
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            accountID: accountID,
            accountLabel: accountLabel,
            planName: planName,
            groups: groups,
            availability: availability,
            lastSuccessfulAt: lastSuccessfulAt,
            lastRefreshAttemptAt: attemptedAt,
            refreshFailure: failure
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case accountID
        case accountLabel
        case planName
        case groups
        case availability
        case lastSuccessfulAt
        case lastRefreshAttemptAt
        case refreshFailure
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        accountID = try container.decodeIfPresent(
            AccountID.self,
            forKey: .accountID
        ) ?? .legacy
        accountLabel = AccountLabel.sanitized(
            try container.decodeIfPresent(
                String.self,
                forKey: .accountLabel
            )
        )
        planName = try container.decode(String.self, forKey: .planName)
        groups = try container.decode([UsageGroup].self, forKey: .groups)
        availability = try container.decode(
            ProviderAvailability.self,
            forKey: .availability
        )
        let legacyContainer = try decoder.container(
            keyedBy: LegacyCodingKeys.self
        )
        lastSuccessfulAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastSuccessfulAt
        ) ?? legacyContainer.decodeIfPresent(
            Date.self,
            forKey: .updatedAt
        )
        lastRefreshAttemptAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastRefreshAttemptAt
        )
        refreshFailure = try container.decodeIfPresent(
            ProviderRefreshFailure.self,
            forKey: .refreshFailure
        )
    }
}

/// Freshness rows shared by the popover, Side Notch, web, and mobile cards so
/// every surface reports the same success and attempt times.
struct ProviderFreshnessDisplay: Equatable, Sendable {
    let showsStaleBadge: Bool
    let successAt: Date?
    let attemptAt: Date?

    var rowCount: Int {
        (successAt == nil ? 0 : 1) + (attemptAt == nil ? 0 : 1)
    }

    /// - Parameter includesSuccessRow: whether the surface already shows the
    ///   last successful refresh time while the provider is current.
    static func make(
        for usage: ProviderUsage,
        includesSuccessRow: Bool
    ) -> ProviderFreshnessDisplay {
        let isStale = usage.freshness == .stale
        return ProviderFreshnessDisplay(
            showsStaleBadge: isStale,
            successAt: includesSuccessRow || isStale
                ? usage.lastSuccessfulAt
                : nil,
            attemptAt: isStale ? usage.lastRefreshAttemptAt : nil
        )
    }
}
