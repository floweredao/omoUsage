import Foundation

enum AntigravityUsageParser {
    private struct BucketSpec {
        let groupID: String
        let groupTitle: String
        let meterID: String
        let title: String
        let period: UsagePeriod
        let menuBarBadge: Bool
    }

    private static let specs: [String: BucketSpec] = [
        "gemini-5h": BucketSpec(
            groupID: "antigravity.gemini",
            groupTitle: "Gemini Models",
            meterID: "antigravity.gemini.session",
            title: "세션 (5시간)",
            period: .session,
            menuBarBadge: true
        ),
        "gemini-weekly": BucketSpec(
            groupID: "antigravity.gemini",
            groupTitle: "Gemini Models",
            meterID: "antigravity.gemini.week",
            title: "주간",
            period: .week,
            menuBarBadge: false
        ),
        "3p-5h": BucketSpec(
            groupID: "antigravity.third-party",
            groupTitle: "Claude and GPT models",
            meterID: "antigravity.third-party.session",
            title: "세션 (5시간)",
            period: .session,
            menuBarBadge: true
        ),
        "3p-weekly": BucketSpec(
            groupID: "antigravity.third-party",
            groupTitle: "Claude and GPT models",
            meterID: "antigravity.third-party.week",
            title: "주간",
            period: .week,
            menuBarBadge: false
        )
    ]

    static func parse(
        _ data: Data,
        now: Date
    ) throws -> ProviderUsage {
        let object = try UsageJSON.object(data)
        if let models = UsageJSON.object(object["models"]) {
            return try parseModels(models, root: object, now: now)
        }
        let bucketValues = UsageJSON.array(object["groups"])?
            .flatMap { UsageJSON.array($0["buckets"]) ?? [] } ?? []
        let metersByGroup = Dictionary(grouping: bucketValues.compactMap(meter), by: \.groupID)

        let credits = UsageJSON.object(object["credits"])
        let creditText = creditText(credits)
        let groups = [
            makeGroup(id: "antigravity.gemini", metersByGroup: metersByGroup),
            makeGroup(
                id: "antigravity.third-party",
                metersByGroup: metersByGroup,
                creditText: creditText
            )
        ].compactMap { $0 }

        guard !groups.isEmpty else {
            throw UsageParsingError.invalidPayload
        }
        return ProviderUsage(
            provider: .antigravity,
            planName: planName(object["plan"]),
            groups: groups,
            availability: .available,
            updatedAt: now
        )
    }

    private static func parseModels(
        _ models: [String: Any],
        root: [String: Any],
        now: Date
    ) throws -> ProviderUsage {
        var gemini: [UsageMeter] = []
        var thirdParty: [UsageMeter] = []
        for key in models.keys.sorted() {
            guard
                let model = UsageJSON.object(models[key]),
                let quota = UsageJSON.object(model["quotaInfo"]),
                let fraction = UsageJSON.number(
                    quota["remainingFraction"]
                )
            else {
                continue
            }
            let title = (model["displayName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let meterTitle = title.flatMap {
                $0.isEmpty ? nil : $0
            } ?? key
            let meter = UsageMeter(
                id: "antigravity.model.\(key)",
                title: meterTitle,
                period: .session,
                percentRemaining: Int((fraction * 100).rounded()),
                resetsAt: UsageJSON.date(quota["resetTime"]),
                showsMenuBarBadge: true
            )
            let modelName = (
                model["model"] as? String ?? key
            ).lowercased()
            if modelName.contains("gemini") {
                gemini.append(meter)
            } else {
                thirdParty.append(meter)
            }
        }
        let groups = [
            modelGroup(
                id: "antigravity.gemini",
                title: "Gemini Models",
                meters: gemini
            ),
            modelGroup(
                id: "antigravity.third-party",
                title: "Claude and GPT models",
                meters: thirdParty
            )
        ].compactMap { $0 }
        guard !groups.isEmpty else {
            throw UsageParsingError.invalidPayload
        }
        return ProviderUsage(
            provider: .antigravity,
            planName: planName(root["plan"]),
            groups: groups,
            availability: .available,
            updatedAt: now
        )
    }

    private static func modelGroup(
        id: String,
        title: String,
        meters: [UsageMeter]
    ) -> UsageGroup? {
        guard !meters.isEmpty else { return nil }
        return UsageGroup(
            id: id,
            title: title,
            meters: meters.sorted { $0.title < $1.title },
            creditText: nil
        )
    }

    private static func meter(
        _ bucket: [String: Any]
    ) -> (groupID: String, order: Int, meter: UsageMeter)? {
        guard
            let bucketID = bucket["bucketId"] as? String,
            let spec = specs[bucketID],
            let fraction = UsageJSON.number(bucket["remainingFraction"])
        else {
            return nil
        }
        let order = spec.period == .session ? 0 : 1
        return (
            spec.groupID,
            order,
            UsageMeter(
                id: spec.meterID,
                title: spec.title,
                period: spec.period,
                percentRemaining: Int((fraction * 100).rounded()),
                resetsAt: UsageJSON.date(bucket["resetTime"]),
                resetText: bucket["resetText"] as? String,
                showsMenuBarBadge: spec.menuBarBadge
            )
        )
    }

    private static func makeGroup(
        id: String,
        metersByGroup: [String: [(groupID: String, order: Int, meter: UsageMeter)]],
        creditText: String? = nil
    ) -> UsageGroup? {
        guard let entries = metersByGroup[id], let first = entries.first else { return nil }
        let spec = specs.values.first { $0.groupID == first.groupID }
        return UsageGroup(
            id: id,
            title: spec?.groupTitle,
            meters: entries.sorted { $0.order < $1.order }.map(\.meter),
            creditText: creditText
        )
    }

    private static func creditText(_ object: [String: Any]?) -> String? {
        guard
            let object,
            let prompt = UsageJSON.number(object["prompt"]),
            let flow = UsageJSON.number(object["flow"])
        else {
            return nil
        }
        return "프롬프트 크레딧 \(Int(prompt))    플로우 크레딧 \(Int(flow))"
    }

    private static func planName(_ value: Any?) -> String {
        guard let raw = value as? String else { return "" }
        return raw.lowercased() == "pro" ? "Pro" : raw.capitalized
    }
}
