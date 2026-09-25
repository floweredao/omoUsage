import OmoUsageCore
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
        if let meter = resetGrantMeter(object["cedar_ember"], now: now) {
            meters.append(meter)
        }
        if let meter = cloudSessionCredit(object["iguana_necktie"], now: now) {
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
            let updatedAt = UsageJSON.date(
                timeIntervalSince1970: milliseconds / 1_000
            ),
            let utilization = UsageJSON.object(sample["u"])
        else {
            throw UsageParsingError.invalidPayload
        }

        guard updatedAt <= now else {
            throw UsageParsingError.invalidPayload
        }

        var meters: [UsageMeter] = []
        if
            let used = UsageJSON.number(utilization["fh"]),
            let remaining = ProviderPayload.remainingPercent(
                usedPercent: used
            )
        {
            meters.append(
                UsageMeter(
                    id: "claude.session",
                    title: "세션 (5시간)",
                    period: .session,
                    percentRemaining: remaining,
                    showsMenuBarBadge: true
                )
            )
        }
        if
            let used = UsageJSON.number(utilization["sd"]),
            let remaining = ProviderPayload.remainingPercent(
                usedPercent: used
            )
        {
            meters.append(
                UsageMeter(
                    id: "claude.week",
                    title: "주간",
                    period: .week,
                    percentRemaining: remaining
                )
            )
        }
        if
            let used = UsageJSON.number(utilization["xu"]),
            let remaining = ProviderPayload.remainingPercent(
                usedPercent: used
            )
        {
            meters.append(
                UsageMeter(
                    id: "claude.extra",
                    title: "추가 사용량",
                    period: .extra,
                    percentRemaining: remaining
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
            let utilization = UsageJSON.number(object["utilization"]),
            let remaining = ProviderPayload.remainingPercent(
                usedPercent: utilization
            )
        else {
            return nil
        }
        let resetValue = object["resets_at"]
        let resetsAt = resetValue.flatMap(UsageJSON.date)
        guard resetValue == nil || resetValue is NSNull || resetsAt != nil else {
            return nil
        }
        return UsageMeter(
            id: id,
            title: title,
            period: period,
            percentRemaining: remaining,
            resetsAt: resetsAt,
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
            let remaining = ProviderPayload.remainingPercent(
                used: used,
                limit: limit
            )
        else {
            return nil
        }
        return UsageMeter(
            id: "claude.extra",
            title: "추가 사용량",
            period: .extra,
            percentRemaining: remaining,
            resetText: object["reset_text"] as? String
        )
    }

    /// Claude's usage-limit reset vouchers ship inside the `cedar_ember`
    /// block (requested via `?cedar_ember=1`). A voucher counts while it is
    /// unpaused, has resets left, and has not expired — matching the grant
    /// rules the official clients apply before offering a reset.
    private static func resetGrantMeter(_ value: Any?, now: Date) -> UsageMeter? {
        guard
            let object = UsageJSON.object(value),
            object["eligible"] as? Bool == true,
            let grants = UsageJSON.array(object["grants"])
        else {
            return nil
        }
        var available = 0
        var earliestExpiry: Date?
        for grant in grants {
            guard
                grant["paused"] as? Bool != true,
                let left = UsageJSON.number(grant["resets_left"])
                    .flatMap(ProviderPayload.nonnegativeInteger),
                left > 0
            else {
                continue
            }
            let endsAtValue = grant["ends_at"]
            let endsAt = endsAtValue.flatMap(UsageJSON.date)
            if endsAtValue != nil, !(endsAtValue is NSNull) {
                guard let endsAt, endsAt > now else { continue }
                if
                    let current = earliestExpiry,
                    endsAt < current
                {} else {
                    earliestExpiry = endsAt
                }
            }
            available += left
        }
        guard available > 0 else { return nil }
        return UsageMeter(
            id: "claude.reset-tickets",
            title: "초기화권",
            period: .extra,
            metric: .count(value: available, unit: .tickets),
            resetText: ProviderPayload.expiryText(earliestExpiry, now: now)
        )
    }

    /// Cloud session credits ship as the `iguana_necktie` bucket: a
    /// dollar-denominated promotional balance that cloud sessions consume
    /// before plan usage. `resets_at` is the credit's expiry, so the meter
    /// carries an expiry label instead of a reset label.
    private static func cloudSessionCredit(
        _ value: Any?,
        now: Date
    ) -> UsageMeter? {
        guard let object = UsageJSON.object(value) else { return nil }
        let resetValue = object["resets_at"]
        let expiresAt = resetValue.flatMap(UsageJSON.date)
        guard
            resetValue == nil || resetValue is NSNull || expiresAt != nil
        else {
            return nil
        }
        let resetText = ProviderPayload.expiryText(expiresAt, now: now)
        if
            let remaining = UsageJSON.number(object["remaining_dollars"]),
            remaining.isFinite,
            remaining >= 0
        {
            return UsageMeter(
                id: "claude.cloud-session-credits",
                title: "클라우드 세션 크레딧",
                period: .extra,
                metric: .credit(balance: remaining, unit: .usd),
                resetText: resetText
            )
        }
        if
            let utilization = UsageJSON.number(object["utilization"]),
            let remaining = ProviderPayload.remainingPercent(
                usedPercent: utilization
            )
        {
            return UsageMeter(
                id: "claude.cloud-session-credits",
                title: "클라우드 세션 크레딧",
                period: .extra,
                percentRemaining: remaining,
                resetText: resetText
            )
        }
        return nil
    }

    private static func scopedWeeklyMeters(
        _ value: Any?
    ) -> [UsageMeter] {
        guard let limits = UsageJSON.array(value) else { return [] }
        return limits.compactMap { limit in
            let model = UsageJSON.object(
                UsageJSON.object(limit["scope"])?["model"]
            )
            let modelID = (model?["id"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            let displayName = (model?["display_name"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            guard
                limit["kind"] as? String == "weekly_scoped",
                let title = displayName ?? modelID,
                let percent = UsageJSON.number(limit["percent"])
                    ?? UsageJSON.number(limit["utilization"]),
                let remaining = ProviderPayload.remainingPercent(
                    usedPercent: percent
                )
            else {
                return nil
            }
            let resetValue = limit["resets_at"]
            let resetsAt = resetValue.flatMap(UsageJSON.date)
            guard resetValue == nil || resetValue is NSNull || resetsAt != nil else {
                return nil
            }
            let stableID = modelID
                ?? title
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-")
            return UsageMeter(
                id: "claude.week.model.\(stableID)",
                title: "\(title) 주간",
                period: .week,
                percentRemaining: remaining,
                resetsAt: resetsAt
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
