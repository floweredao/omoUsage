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
            token: credential.accessToken
        )
        async let key = attempt(
            "https://openrouter.ai/api/v1/key",
            token: credential.accessToken
        )
        let attempts = await [credits, key]
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
        return try parse(data[0], key: data[1], now: now)
    }

    private func attempt(
        _ url: String,
        token: String
    ) async -> OpenRouterAttempt {
        do {
            return OpenRouterAttempt(
                data: try await get(url, token: token),
                error: nil
            )
        } catch let error as ProviderTransportError {
            return OpenRouterAttempt(data: nil, error: error)
        } catch {
            return OpenRouterAttempt(data: nil, error: nil)
        }
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
        if let total, let usage {
            meters.append(
                UsageMeter(
                    id: "openrouter-credits",
                    title: "크레딧",
                    period: .extra,
                    percentRemaining: ProviderPayload.remainingPercent(
                        used: usage,
                        limit: total
                    ) ?? 0,
                    resetText: "\(ProviderPayload.money(usage)) 사용"
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
            if let remaining {
                meters.append(
                    UsageMeter(
                        id: "openrouter-key",
                        title: "키 한도",
                        period: .extra,
                        percentRemaining: Int(
                            (remaining / keyLimit * 100).rounded()
                        )
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
        var creditParts: [String] = []
        if let total, let usage {
            creditParts.append(
                "잔액 \(ProviderPayload.money(max(0, total - usage)))"
            )
        }
        if let daily {
            creditParts.append("오늘 \(ProviderPayload.money(daily))")
        }
        return ProviderUsage(
            provider: id,
            planName: planName(keyRoot),
            groups: [
                UsageGroup(
                    id: "openrouter-usage",
                    title: nil,
                    meters: meters,
                    creditText: creditParts.isEmpty
                        ? nil
                        : creditParts.joined(separator: " · ")
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
