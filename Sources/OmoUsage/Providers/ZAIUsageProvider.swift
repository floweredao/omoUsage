import Foundation

struct ZAIUsageProvider: UsageProvider {
    let id = ProviderID.zai
    let accountID: AccountID
    let accountLabel: String
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    init(
        discovery: CredentialDiscovery,
        http: ProviderHTTP,
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue
    ) {
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.discovery = discovery
        self.http = http
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        let credential = try discovery.zai(accountID: accountID)
        async let quota = get(
            "https://api.z.ai/api/monitor/usage/quota/limit",
            token: credential.accessToken
        )
        async let subscription = try? get(
            "https://api.z.ai/api/biz/subscription/list",
            token: credential.accessToken
        )
        let (quotaData, subscriptionData) = try await (
            quota,
            subscription
        )
        return try parse(
            quotaData,
            subscription: subscriptionData,
            now: now
        )
    }

    private func get(
        _ url: String,
        token: String
    ) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 15
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.data(for: request, provider: id)
    }

    private func parse(
        _ data: Data,
        subscription: Data?,
        now: Date
    ) throws -> ProviderUsage {
        let root = try ProviderPayload.object(data)
        if
            let message = ProviderPayload.text(
                root,
                paths: [["msg"], ["message"]]
            )?.lowercased(),
            message.contains("no active coding plan")
        {
            return ProviderUsage(
                provider: id,
                planName: "",
                groups: [],
                availability: .unavailable,
                updatedAt: now
            )
        }
        let payload = ProviderPayload.dictionary(root, ["data"]) ?? root
        let plan = subscription.flatMap(subscriptionPlanName)
        guard
            let limits = (
                payload["limits"] as? [[String: Any]]
                ?? payload["limitList"] as? [[String: Any]]
            )
        else {
            throw ProviderTransportError.invalidResponse(id)
        }
        if limits.isEmpty && plan == nil {
            return ProviderUsage(
                provider: id,
                planName: "",
                groups: [],
                availability: .unavailable,
                updatedAt: now
            )
        }
        var metersByID: [String: UsageMeter] = [:]
        for limit in limits {
            let type = ProviderPayload.text(
                limit,
                paths: [["type"], ["limitType"]]
            )?.uppercased() ?? ""
            let explicitUsed = ProviderPayload.number(
                limit,
                paths: [["used"], ["currentValue"]]
            )
            let usage = ProviderPayload.number(
                limit,
                paths: [["usage"]]
            )
            let explicitCap = ProviderPayload.number(
                limit,
                paths: [["limit"], ["total"], ["maxValue"]]
            )
            let usedPercent = ProviderPayload.number(
                limit,
                paths: [["percentage"], ["usedPercent"]]
            )
            let remaining: Int?
            if let usedPercent {
                remaining = ProviderPayload.remainingPercent(
                    usedPercent: usedPercent
                )
            } else if let explicitUsed, let cap = explicitCap ?? usage {
                remaining = ProviderPayload.remainingPercent(
                    used: explicitUsed,
                    limit: cap
                )
            } else if let usage, let explicitCap {
                remaining = ProviderPayload.remainingPercent(
                    used: usage,
                    limit: explicitCap
                )
            } else {
                remaining = nil
            }
            guard let remaining else { continue }
            let reset = ProviderPayload.date(
                limit,
                paths: [
                    ["nextResetTime"],
                    ["resetAt"],
                    ["reset_at"]
                ]
            )
            let meter: UsageMeter
            if type.contains("TIME") || type.contains("SEARCH") {
                meter = UsageMeter(
                    id: "zai-search",
                    title: "웹 검색",
                    period: .extra,
                    percentRemaining: remaining,
                    resetsAt: reset,
                    resetText: ProviderPayload.resetText(reset, now: now)
                )
            } else {
                let unit = ProviderPayload.number(
                    limit,
                    paths: [["unit"]]
                ).flatMap(ProviderPayload.nonnegativeInteger)
                let number = ProviderPayload.number(
                    limit,
                    paths: [["number"]]
                ).flatMap(ProviderPayload.nonnegativeInteger)
                let period: UsagePeriod
                let meterID: String
                let title: String
                if unit == 6 && number == 1 {
                    period = .week
                    meterID = "zai-week"
                    title = "주간"
                } else if unit == 3 && number == 5 {
                    period = .session
                    meterID = "zai-session"
                    title = "세션"
                } else {
                    period = .extra
                    meterID = [
                        "zai-token",
                        unit.map(String.init) ?? "unknown",
                        number.map(String.init) ?? "unknown"
                    ].joined(separator: "-")
                    title = "토큰 한도"
                }
                meter = UsageMeter(
                    id: meterID,
                    title: title,
                    period: period,
                    percentRemaining: remaining,
                    resetsAt: reset,
                    resetText: ProviderPayload.resetText(reset, now: now)
                )
            }
            if let current = metersByID[meter.id] {
                if shouldReplace(current, with: meter) {
                    metersByID[meter.id] = meter
                }
            } else {
                metersByID[meter.id] = meter
            }
        }
        var tokenMeters = Array(metersByID.values)
        tokenMeters.sort {
            let rank: [UsagePeriod: Int] = [
                .session: 0,
                .week: 1,
                .extra: 2
            ]
            return (rank[$0.period] ?? 3, $0.id)
                < (rank[$1.period] ?? 3, $1.id)
        }
        guard !tokenMeters.isEmpty else {
            throw ProviderTransportError.invalidResponse(id)
        }
        return ProviderUsage(
            provider: id,
            planName: plan ?? "",
            groups: [
                UsageGroup(
                    id: "zai-usage",
                    title: nil,
                    meters: tokenMeters,
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    private func shouldReplace(
        _ current: UsageMeter,
        with candidate: UsageMeter
    ) -> Bool {
        if candidate.percentRemaining != current.percentRemaining {
            return candidate.percentRemaining < current.percentRemaining
        }
        switch (current.resetsAt, candidate.resetsAt) {
        case let (.some(currentReset), .some(candidateReset)):
            return candidateReset < currentReset
        case (.none, .some):
            return true
        default:
            return false
        }
    }

    private func subscriptionPlanName(
        _ data: Data
    ) -> String? {
        guard let root = try? ProviderPayload.object(data) else {
            return nil
        }
        if let plans = UsageJSON.array(root["data"]) {
            return plans.lazy.compactMap {
                ProviderPayload.text(
                    $0,
                    paths: [
                        ["productName"],
                        ["planName"],
                        ["subscriptionName"],
                        ["name"]
                    ]
                )
            }.first
        }
        let payload = ProviderPayload.dictionary(root, ["data"]) ?? root
        return ProviderPayload.text(
            payload,
            paths: [
                ["productName"],
                ["planName"],
                ["subscriptionName"],
                ["name"]
            ]
        )
    }
}
