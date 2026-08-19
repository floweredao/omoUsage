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

struct ProviderUsage: Identifiable, Equatable, Codable, Sendable {
    var id: ProviderID { provider }

    let provider: ProviderID
    let planName: String
    let groups: [UsageGroup]
    let availability: ProviderAvailability
    let updatedAt: Date?
}
