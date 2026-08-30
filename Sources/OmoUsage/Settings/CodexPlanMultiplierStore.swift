import Foundation

enum CodexPlanMultiplier: String, CaseIterable, Identifiable {
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

struct CodexPlanMultiplierStore {
    static let defaultsKey = "codexPlanMultiplier"

    let defaults: UserDefaults

    func load() -> CodexPlanMultiplier {
        guard
            let rawValue = defaults.string(
                forKey: Self.defaultsKey
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
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(
                multiplier.rawValue,
                forKey: Self.defaultsKey
            )
        }
    }

    func planName(for reportedPlan: String) -> String {
        load().planName(for: reportedPlan)
    }
}
