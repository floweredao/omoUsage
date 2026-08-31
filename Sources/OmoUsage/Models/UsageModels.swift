import Foundation

enum UsagePeriod: String, Codable, Sendable {
    case session
    case week
    case extra
}

enum UsageMetricKind: String, Codable, CaseIterable, Sendable {
    case quotaRemaining
    case spend
    case credit
    case count
    case informational
}

enum UsageCurrency: String, Codable, CaseIterable, Sendable {
    case usd = "USD"
}

enum UsageMetricUnit: String, Codable, CaseIterable, Sendable {
    case usd = "USD"
    case credits
    case requests
    case tokens
    case tickets
}

struct UsageMetricPresentation: Equatable, Sendable {
    let showsProgress: Bool
}

enum UsageMetric: Equatable, Codable, Sendable {
    case quotaRemaining(percent: Int)
    case spend(amount: Double, currency: UsageCurrency)
    case credit(balance: Double, unit: UsageMetricUnit)
    case count(value: Int, unit: UsageMetricUnit)
    case informational(value: String)

    static let maximumAmount = 1_000_000_000.0
    static let maximumCount = 1_000_000_000_000
    static let maximumInformationLength = 512

    var kind: UsageMetricKind {
        switch self {
        case .quotaRemaining: .quotaRemaining
        case .spend: .spend
        case .credit: .credit
        case .count: .count
        case .informational: .informational
        }
    }

    var progressFraction: Double? {
        switch self {
        case .quotaRemaining(let percent): Double(percent) / 100
        case .spend, .credit, .count, .informational: nil
        }
    }

    var presentation: UsageMetricPresentation {
        switch self {
        case .quotaRemaining:
            UsageMetricPresentation(showsProgress: true)
        case .spend, .credit, .count, .informational:
            UsageMetricPresentation(showsProgress: false)
        }
    }

    var isValid: Bool {
        switch self {
        case .quotaRemaining(let percent):
            (0...100).contains(percent)
        case .spend(let amount, _), .credit(let amount, _):
            amount.isFinite && (0...Self.maximumAmount).contains(amount)
        case .count(let value, let unit):
            unit != .usd && (0...Self.maximumCount).contains(value)
        case .informational(let value):
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.count <= Self.maximumInformationLength
        }
    }

    static func quotaRemaining(validating percent: Int) -> UsageMetric? {
        let metric = UsageMetric.quotaRemaining(percent: percent)
        return metric.isValid ? metric : nil
    }

    static func spend(
        validating amount: Double,
        currency: UsageCurrency
    ) -> UsageMetric? {
        let metric = UsageMetric.spend(amount: amount, currency: currency)
        return metric.isValid ? metric : nil
    }

    static func credit(
        validating balance: Double,
        unit: UsageMetricUnit
    ) -> UsageMetric? {
        let metric = UsageMetric.credit(balance: balance, unit: unit)
        return metric.isValid ? metric : nil
    }

    static func count(
        validating value: Int,
        unit: UsageMetricUnit
    ) -> UsageMetric? {
        let metric = UsageMetric.count(value: value, unit: unit)
        return metric.isValid ? metric : nil
    }

    static func informational(validating value: String) -> UsageMetric? {
        let metric = UsageMetric.informational(value: value)
        return metric.isValid ? metric : nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case amount
        case currency
        case balance
        case unit
        case value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(UsageMetricKind.self, forKey: .kind)
        self = switch kind {
        case .quotaRemaining:
            .quotaRemaining(
                percent: try container.decode(Int.self, forKey: .percent)
            )
        case .spend:
            .spend(
                amount: try container.decode(Double.self, forKey: .amount),
                currency: try container.decode(
                    UsageCurrency.self,
                    forKey: .currency
                )
            )
        case .credit:
            .credit(
                balance: try container.decode(Double.self, forKey: .balance),
                unit: try container.decode(UsageMetricUnit.self, forKey: .unit)
            )
        case .count:
            .count(
                value: try container.decode(Int.self, forKey: .value),
                unit: try container.decode(UsageMetricUnit.self, forKey: .unit)
            )
        case .informational:
            .informational(
                value: try container.decode(String.self, forKey: .value)
            )
        }
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Invalid typed usage metric"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Invalid typed usage metric"
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .quotaRemaining(let percent):
            try container.encode(percent, forKey: .percent)
        case .spend(let amount, let currency):
            try container.encode(amount, forKey: .amount)
            try container.encode(currency, forKey: .currency)
        case .credit(let balance, let unit):
            try container.encode(balance, forKey: .balance)
            try container.encode(unit, forKey: .unit)
        case .count(let value, let unit):
            try container.encode(value, forKey: .value)
            try container.encode(unit, forKey: .unit)
        case .informational(let value):
            try container.encode(value, forKey: .value)
        }
    }
}

struct UsageMeter: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let period: UsagePeriod
    let metric: UsageMetric
    let resetsAt: Date?
    let resetText: String?
    let showsMenuBarBadge: Bool

    var percentRemaining: Int? {
        guard case .quotaRemaining(let percent) = metric else { return nil }
        return percent
    }

    init(
        id: String,
        title: String,
        period: UsagePeriod,
        metric: UsageMetric,
        resetsAt: Date? = nil,
        resetText: String? = nil,
        showsMenuBarBadge: Bool = false
    ) {
        self.id = id
        self.title = title
        self.period = period
        self.metric = metric
        self.resetsAt = resetsAt
        self.resetText = resetText
        self.showsMenuBarBadge = showsMenuBarBadge
    }

    init(
        id: String,
        title: String,
        period: UsagePeriod,
        percentRemaining: Int,
        resetsAt: Date? = nil,
        resetText: String? = nil,
        showsMenuBarBadge: Bool = false
    ) {
        self.init(
            id: id,
            title: title,
            period: period,
            metric: .quotaRemaining(percent: percentRemaining),
            resetsAt: resetsAt,
            resetText: resetText,
            showsMenuBarBadge: showsMenuBarBadge
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case period
        case metric
        case percentRemaining
        case resetsAt
        case resetText
        case showsMenuBarBadge
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        period = try container.decode(UsagePeriod.self, forKey: .period)
        if let typed = try container.decodeIfPresent(
            UsageMetric.self,
            forKey: .metric
        ) {
            metric = typed
        } else {
            metric = .quotaRemaining(
                percent: try container.decode(
                    Int.self,
                    forKey: .percentRemaining
                )
            )
        }
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        resetText = try container.decodeIfPresent(String.self, forKey: .resetText)
        showsMenuBarBadge = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsMenuBarBadge
        ) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(period, forKey: .period)
        try container.encode(metric, forKey: .metric)
        try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try container.encodeIfPresent(resetText, forKey: .resetText)
        try container.encode(showsMenuBarBadge, forKey: .showsMenuBarBadge)
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
