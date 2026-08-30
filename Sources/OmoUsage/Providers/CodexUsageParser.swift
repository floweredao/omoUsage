import Foundation

enum CodexUsageParser {
    private static let weeklySeconds = 6 * 24 * 60 * 60

    static func parse(
        _ data: Data,
        now: Date
    ) throws -> ProviderUsage {
        let object = try UsageJSON.object(data)
        guard let rateLimit = UsageJSON.object(object["rate_limit"]) else {
            throw UsageParsingError.invalidPayload
        }
        let meters = usageWindows(rateLimit)
        guard !meters.isEmpty else {
            throw UsageParsingError.invalidPayload
        }

        let credits = UsageJSON.object(object["credits"])
            .flatMap { UsageJSON.number($0["balance"]) }
            .flatMap(ProviderPayload.nonnegativeInteger)
        let resetTickets = UsageJSON.object(
            object["rate_limit_reset_credits"]
        )
            .flatMap { UsageJSON.number($0["available_count"]) }
            .flatMap(ProviderPayload.nonnegativeInteger)
        let creditText = [
            credits.map { "크레딧 \($0)" },
            resetTickets.map { "풀 리셋 티켓 \($0)" }
        ]
            .compactMap { $0 }
            .joined(separator: "    ")
        let group = UsageGroup(
            id: "codex.main",
            title: nil,
            meters: meters,
            creditText: creditText.isEmpty ? nil : creditText
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

    private static func usageWindows(
        _ rateLimit: [String: Any]
    ) -> [UsageMeter] {
        let windows = ["primary_window", "secondary_window"]
            .compactMap { key -> ([String: Any], Double)? in
                guard
                    let window = UsageJSON.object(rateLimit[key]),
                    let seconds = UsageJSON.number(
                        window["limit_window_seconds"]
                    ),
                    seconds > 0,
                    UsageJSON.number(window["used_percent"]) != nil
                else {
                    return nil
                }
                return (window, seconds)
            }

        return windows.enumerated().compactMap { index, candidate in
            let (window, seconds) = candidate
            guard
                let used = UsageJSON.number(window["used_percent"]),
                let remaining = ProviderPayload.remainingPercent(
                    usedPercent: used
                )
            else {
                return nil
            }
            let resetValue = window["reset_at"]
            let resetsAt = resetValue.flatMap(UsageJSON.date)
            guard resetValue == nil || resetsAt != nil else { return nil }
            let isWeekly = seconds >= Double(weeklySeconds)
            let period: UsagePeriod = isWeekly ? .week : .session
            let sessionHours = ProviderPayload.nonnegativeInteger(
                seconds / 3_600
            )
            guard isWeekly || sessionHours != nil else { return nil }
            let title = isWeekly
                ? "주간"
                : "세션 (\(max(1, sessionHours ?? 0))시간)"
            return UsageMeter(
                id: isWeekly ? "codex.week" : "codex.session",
                title: title,
                period: period,
                percentRemaining: remaining,
                resetsAt: resetsAt,
                resetText: window["reset_text"] as? String,
                showsMenuBarBadge: index == 0
            )
        }
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
