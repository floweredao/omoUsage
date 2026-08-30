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
        self.percentRemaining = min(100, max(0, percentRemaining))
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

    var koreanLabel: String? {
        switch self {
        case .available: nil
        case .authenticationRequired: "인증 필요"
        case .unavailable: "사용할 수 없음"
        case .failed: "새로고침 실패"
        }
    }
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
    let updatedAt: Date?

    init(
        provider: ProviderID,
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue,
        planName: String,
        groups: [UsageGroup],
        availability: ProviderAvailability,
        updatedAt: Date?
    ) {
        self.provider = provider
        self.accountID = accountID
        self.accountLabel = AccountLabel.sanitized(accountLabel)
        self.planName = planName
        self.groups = groups
        self.availability = availability
        self.updatedAt = updatedAt
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
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case accountID
        case accountLabel
        case planName
        case groups
        case availability
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
        updatedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .updatedAt
        )
    }
}
