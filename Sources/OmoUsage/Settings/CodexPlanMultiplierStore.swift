import Foundation
import OmoUsageCore

enum CodexPlanMultiplier: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case fiveX = "5x"
    case twentyX = "20x"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "자동"
        case .fiveX: "Pro 5x"
        case .twentyX: "Pro 20x"
        }
    }

    func planName(for reportedPlan: String) -> String {
        guard reportedPlan == "Pro", self != .automatic else {
            return reportedPlan
        }
        return "Pro \(rawValue)"
    }
}

// UserDefaults documents concurrent access as thread-safe.
struct CodexPlanMultiplierStore: @unchecked Sendable {
    static let defaultsKey = "codexPlanMultiplier"

    let defaults: UserDefaults
    let accountID: AccountID

    init(defaults: UserDefaults, accountID: AccountID = .legacy) {
        self.defaults = defaults
        self.accountID = accountID
    }

    var defaultsKey: String {
        accountID == .legacy
            ? Self.defaultsKey
            : "\(Self.defaultsKey).\(accountID.rawValue)"
    }

    func load() -> CodexPlanMultiplier {
        guard
            let rawValue = defaults.string(
                forKey: defaultsKey
            ),
            let multiplier = CodexPlanMultiplier(
                rawValue: rawValue
            )
        else {
            return .automatic
        }
        return multiplier
    }

    func save(_ multiplier: CodexPlanMultiplier) {
        if multiplier == .automatic {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(
                multiplier.rawValue,
                forKey: defaultsKey
            )
        }
    }

    func planName(for reportedPlan: String) -> String {
        load().planName(for: reportedPlan)
    }
}
