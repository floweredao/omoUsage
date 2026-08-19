import Foundation

enum CodexUsageParser {
    private static let weeklySeconds = 6 * 24 * 60 * 60

    static func parse(
        _ data: Data,
        now: Date
    ) throws -> ProviderUsage {
        let object = try UsageJSON.object(data)
        guard
            let rateLimit = UsageJSON.object(object["rate_limit"]),
            let weekly = weeklyWindow(rateLimit)
        else {
            throw UsageParsingError.invalidPayload
        }

        let credits = UsageJSON.object(object["credits"])
            .flatMap { UsageJSON.number($0["balance"]) }
            .map { max(0, Int($0.rounded(.down))) }
        let group = UsageGroup(
            id: "codex.main",
            title: nil,
            meters: [weekly],
            creditText: credits.map { "크레딧 \($0)" }
        )
        let reportedPlan = planName(object["plan_type"])
        return ProviderUsage(
            provider: .codex,
            planName: CodexPlanMultiplierStore(
                defaults: .standard
            ).planName(for: reportedPlan),
            groups: [group],
            availability: .available,
            updatedAt: now
        )
    }

    private static func weeklyWindow(_ rateLimit: [String: Any]) -> UsageMeter? {
        let candidates = ["primary_window", "secondary_window"]
            .compactMap { UsageJSON.object(rateLimit[$0]) }
        let weekly = candidates.first {
            guard let seconds = UsageJSON.number($0["limit_window_seconds"]) else {
                return false
            }
            return seconds >= Double(weeklySeconds)
        }

        guard
            let weekly,
            let used = UsageJSON.number(weekly["used_percent"])
        else {
            return nil
        }
        return UsageMeter(
            id: "codex.week",
            title: "주간",
            period: .week,
            percentRemaining: Int((100 - used).rounded()),
            resetsAt: UsageJSON.date(weekly["reset_at"]),
            resetText: weekly["reset_text"] as? String,
            showsMenuBarBadge: true
        )
    }

    private static func planName(_ value: Any?) -> String {
        guard let raw = value as? String else { return "" }
        return switch raw.lowercased() {
        case "plus": "Plus"
        case "pro", "prolite": "Pro"
        case "team": "Team"
        default: raw.capitalized
        }
    }
}
