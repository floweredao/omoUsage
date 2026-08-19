import Foundation

enum ClaudeUsageParser {
    static func parse(
        _ data: Data,
        planName: String,
        now: Date
    ) throws -> ProviderUsage {
        let object = try UsageJSON.object(data)
        var meters: [UsageMeter] = []

        if let meter = usageWindow(
            object["five_hour"],
            id: "claude.session",
            title: "세션 (5시간)",
            period: .session,
            showsMenuBarBadge: true
        ) {
            meters.append(meter)
        }
        if let meter = usageWindow(
            object["seven_day"],
            id: "claude.week",
            title: "주간",
            period: .week
        ) {
            meters.append(meter)
        }
        let scopedMeters = scopedWeeklyMeters(object["limits"])
        if scopedMeters.isEmpty {
            meters.append(contentsOf: legacyWeeklyMeters(object))
        } else {
            meters.append(contentsOf: scopedMeters)
        }
        if let meter = extraUsage(object["extra_usage"]) {
            meters.append(meter)
        }

        guard !meters.isEmpty else {
            throw UsageParsingError.invalidPayload
        }
        return ProviderUsage(
            provider: .claude,
            planName: planName,
            groups: [
                UsageGroup(id: "claude.main", title: nil, meters: meters, creditText: nil)
            ],
            availability: .available,
            updatedAt: now
        )
    }

    static func parseDesktopHistory(
        _ data: Data,
        now: Date
    ) throws -> ProviderUsage {
        let object = try UsageJSON.object(data)
        guard
            UsageJSON.number(object["version"]) == 2,
            let samples = UsageJSON.array(object["samples"]),
            let sample = samples.max(by: {
                (UsageJSON.number($0["t"]) ?? 0)
                    < (UsageJSON.number($1["t"]) ?? 0)
            }),
            let milliseconds = UsageJSON.number(sample["t"]),
            let utilization = UsageJSON.object(sample["u"])
        else {
            throw UsageParsingError.invalidPayload
        }

        let updatedAt = Date(
            timeIntervalSince1970: milliseconds / 1_000
        )
        guard updatedAt <= now else {
            throw UsageParsingError.invalidPayload
        }

        var meters: [UsageMeter] = []
        if let used = UsageJSON.number(utilization["fh"]) {
            meters.append(
                UsageMeter(
                    id: "claude.session",
                    title: "세션 (5시간)",
                    period: .session,
                    percentRemaining: Int((100 - used).rounded()),
                    showsMenuBarBadge: true
                )
            )
        }
        if let used = UsageJSON.number(utilization["sd"]) {
            meters.append(
                UsageMeter(
                    id: "claude.week",
                    title: "주간",
                    period: .week,
                    percentRemaining: Int((100 - used).rounded())
                )
            )
        }
        if let used = UsageJSON.number(utilization["xu"]) {
            meters.append(
                UsageMeter(
                    id: "claude.extra",
                    title: "추가 사용량",
                    period: .extra,
                    percentRemaining: Int((100 - used).rounded())
                )
            )
        }
        guard !meters.isEmpty else {
            throw UsageParsingError.invalidPayload
        }
        return ProviderUsage(
            provider: .claude,
            planName: "",
            groups: [
                UsageGroup(
                    id: "claude.main",
                    title: nil,
                    meters: meters,
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: updatedAt
        )
    }

    private static func usageWindow(
        _ value: Any?,
        id: String,
        title: String,
        period: UsagePeriod,
        showsMenuBarBadge: Bool = false
    ) -> UsageMeter? {
        guard
            let object = UsageJSON.object(value),
            let utilization = UsageJSON.number(object["utilization"])
        else {
            return nil
        }
        return UsageMeter(
            id: id,
            title: title,
            period: period,
            percentRemaining: Int((100 - utilization).rounded()),
            resetsAt: UsageJSON.date(object["resets_at"]),
            resetText: object["reset_text"] as? String,
            showsMenuBarBadge: showsMenuBarBadge
        )
    }

    private static func extraUsage(_ value: Any?) -> UsageMeter? {
        guard
            let object = UsageJSON.object(value),
            object["is_enabled"] as? Bool == true,
            let used = UsageJSON.number(object["used_credits"]),
            let limit = UsageJSON.number(object["monthly_limit"]),
            limit > 0
        else {
            return nil
        }
        return UsageMeter(
            id: "claude.extra",
            title: "추가 사용량",
            period: .extra,
            percentRemaining: Int(((limit - used) / limit * 100).rounded()),
            resetText: object["reset_text"] as? String
        )
    }

    private static func scopedWeeklyMeters(
        _ value: Any?
    ) -> [UsageMeter] {
        guard let limits = UsageJSON.array(value) else { return [] }
        return limits.compactMap { limit in
            guard
                limit["kind"] as? String == "weekly_scoped",
                let scope = UsageJSON.object(limit["scope"]),
                let model = UsageJSON.object(scope["model"]),
                let modelID = model["id"] as? String,
                !modelID.isEmpty,
                let percent = UsageJSON.number(
                    limit["percent"] ?? limit["utilization"]
                )
            else {
                return nil
            }
            let displayName = model["display_name"] as? String
                ?? modelID
            return UsageMeter(
                id: "claude.week.model.\(modelID)",
                title: "\(displayName) 주간",
                period: .week,
                percentRemaining: Int((100 - percent).rounded()),
                resetsAt: UsageJSON.date(limit["resets_at"])
            )
        }
    }

    private static func legacyWeeklyMeters(
        _ object: [String: Any]
    ) -> [UsageMeter] {
        object.keys
            .filter { $0.hasPrefix("seven_day_") }
            .sorted()
            .compactMap { key in
                let suffix = String(key.dropFirst("seven_day_".count))
                let title = suffix
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                return usageWindow(
                    object[key],
                    id: "claude.week.\(suffix)",
                    title: "\(title) 주간",
                    period: .week
                )
            }
    }
}
