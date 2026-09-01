import OmoUsageCore
import Foundation

struct OpenRouterUsageProvider: UsageProvider {
    let id = ProviderID.openrouter
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
        let credential = try discovery.openrouter(accountID: accountID)
        async let credits = attempt(
            "https://openrouter.ai/api/v1/credits",
            purpose: .openRouterCredits,
            token: credential.accessToken
        )
        async let key = attempt(
            "https://openrouter.ai/api/v1/key",
            purpose: .openRouterKey,
            token: credential.accessToken
        )
        let attempts = try await [credits, key]
        let data = attempts.map(\.data)
        if data.allSatisfy({ $0 == nil }) {
            if attempts.contains(where: { $0.authenticationFailed }) {
                throw ProviderTransportError
                    .authenticationRequired(id)
            }
            if let error = attempts.compactMap(\.error).first {
                throw error
            }
            throw ProviderTransportError.invalidResponse(id)
        }
        let endpoint = ProviderContractCatalog.endpoint(
            .openRouterCredits,
            for: id
        )
        return try endpoint.schemaChecked {
            try parse(data[0], key: data[1], now: now)
        }
    }

    private func attempt(
        _ url: String,
        purpose: ProviderEndpointPurpose,
        token: String
    ) async throws -> OpenRouterAttempt {
        do {
            return OpenRouterAttempt(
                data: try await get(
                    url,
                    purpose: purpose,
                    token: token
                ),
                error: nil
            )
        } catch let error as ProviderTransportError {
            return OpenRouterAttempt(data: nil, error: error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw error
        }
    }

    private func get(
        _ url: String,
        purpose: ProviderEndpointPurpose,
        token: String
    ) async throws -> Data {
        let endpoint = ProviderContractCatalog.endpoint(purpose, for: id)
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 15
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.data(for: request, endpoint: endpoint)
    }

    private func parse(
        _ data: Data?,
        key: Data?,
        now: Date
    ) throws -> ProviderUsage {
        let credits: [String: Any]? = if let data,
            let root = try? ProviderPayload.object(data)
        {
            ProviderPayload.dictionary(root, ["data"]) ?? root
        } else {
            nil
        }
        let keyObject: [String: Any]? = if let key {
            try? ProviderPayload.object(key)
        } else {
            nil
        }
        let keyRoot = keyObject.map {
            ProviderPayload.dictionary($0, ["data"]) ?? $0
        }
        let keyLimit = keyRoot.flatMap {
            ProviderPayload.number($0, paths: [["limit"]])
        }
        let keyUsage = keyRoot.flatMap {
            ProviderPayload.number($0, paths: [["usage"]])
        }
        let total = credits.flatMap {
            ProviderPayload.number(
                $0,
                paths: [["total_credits"], ["totalCredits"]]
            )
        }
        let usage = credits.flatMap {
            ProviderPayload.number(
                $0,
                paths: [["total_usage"], ["totalUsage"]]
            )
        }
        var meters: [UsageMeter] = []
        if let usage,
           let metric = UsageMetric.spend(
               validating: usage,
               currency: .usd
           ) {
            meters.append(
                UsageMeter(
                    id: "openrouter-total-spend",
                    title: "총 사용량",
                    period: .extra,
                    metric: metric
                )
            )
        }
        if let total, let usage,
           let metric = UsageMetric.credit(
               validating: max(0, total - usage),
               unit: .usd
           ) {
            meters.append(
                UsageMeter(
                    id: "openrouter-credit-balance",
                    title: "잔액",
                    period: .extra,
                    metric: metric
                )
            )
        }
        if let keyLimit, keyLimit > 0 {
            let remaining = keyRoot.flatMap {
                ProviderPayload.number(
                    $0,
                    paths: [["limit_remaining"], ["limitRemaining"]]
                )
            } ?? keyUsage.map { max(0, keyLimit - $0) }
            if
                let remaining,
                let percentRemaining = ProviderPayload.percent(
                    remaining / keyLimit * 100
                )
            {
                meters.append(
                    UsageMeter(
                        id: "openrouter-key",
                        title: "키 한도",
                        period: .extra,
                        percentRemaining: percentRemaining
                    )
                )
            }
        }
        guard !meters.isEmpty else {
            throw ProviderTransportError.invalidResponse(id)
        }
        let daily = keyRoot.flatMap {
            ProviderPayload.number(
                $0,
                paths: [["usage_daily"], ["usageDaily"]]
            )
        }
        if let daily,
           let metric = UsageMetric.spend(
               validating: daily,
               currency: .usd
           ) {
            meters.append(
                UsageMeter(
                    id: "openrouter-daily-spend",
                    title: "오늘",
                    period: .extra,
                    metric: metric
                )
            )
        }
        return ProviderUsage(
            provider: id,
            planName: planName(keyRoot),
            groups: [
                UsageGroup(
                    id: "openrouter-usage",
                    title: nil,
                    meters: meters,
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    private func planName(
        _ root: [String: Any]?
    ) -> String {
        guard let root else { return "" }
        if let isFree = root["is_free_tier"] as? Bool {
            return isFree ? "Free" : "Paid"
        }
        return ProviderPayload.text(
            root,
            paths: [["label"], ["tier"]]
        ) ?? ""
    }
}

private struct OpenRouterAttempt: Sendable {
    let data: Data?
    let error: ProviderTransportError?

    var authenticationFailed: Bool {
        if case .authenticationRequired = error {
            return true
        }
        return false
    }
}
