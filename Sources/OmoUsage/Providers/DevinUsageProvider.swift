import Foundation

struct DevinUsageProvider: UsageProvider {
    let id = ProviderID.devin
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    func fetch(now: Date) async throws -> ProviderUsage {
        let credential = try discovery.devin()
        let server = credential.accountID
            ?? "https://server.codeium.com"
        let service = "exa.seat_management_pb.SeatManagementService"
        guard
            let baseURL = URL(string: server),
            baseURL.scheme == "https",
            let host = baseURL.host?.lowercased(),
            host == "codeium.com" || host.hasSuffix(".codeium.com"),
            let url = URL(
                string: "\(server.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(service)/GetUserStatus"
            )
        else {
            throw ProviderTransportError.invalidResponse(id)
        }
        var request = URLRequest(
            url: url
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "metadata": [
                    "apiKey": credential.accessToken,
                    "ideName": "devin",
                    "ideVersion": "1.108.2",
                    "extensionName": "devin",
                    "extensionVersion": "1.108.2",
                    "locale": "ko"
                ]
            ]
        )
        let data = try await http.data(for: request, provider: id)
        return try parse(data, now: now)
    }

    private func parse(_ data: Data, now: Date) throws -> ProviderUsage {
        let root = try ProviderPayload.object(data)
        if
            let userStatus = UsageJSON.object(root["userStatus"]),
            let planStatus = UsageJSON.object(userStatus["planStatus"])
        {
            return try parsePlanStatus(planStatus, now: now)
        }
        let definitions: [
            (String, UsagePeriod, [[String]], [[String]])
        ] = [
            ("주간", .week, [
                ["weeklyQuota", "usedPercent"],
                ["weeklyQuotaUsedPercent"],
                ["weeklyUsagePercent"]
            ], [
                ["weeklyQuota", "resetAt"],
                ["weeklyResetAt"]
            ]),
            ("일간", .session, [
                ["dailyQuota", "usedPercent"],
                ["dailyQuotaUsedPercent"],
                ["dailyUsagePercent"]
            ], [
                ["dailyQuota", "resetAt"],
                ["dailyResetAt"]
            ])
        ]
        let meters = definitions.compactMap {
            definition -> UsageMeter? in
            let (title, usagePeriod, valuePaths, resetPaths) = definition
            guard
                let used = ProviderPayload.number(root, paths: valuePaths)
            else {
                return nil
            }
            let reset = ProviderPayload.date(root, paths: resetPaths)
            return UsageMeter(
                id: "devin-\(title)",
                title: title,
                period: usagePeriod,
                percentRemaining: ProviderPayload.remainingPercent(
                    usedPercent: used
                ),
                resetsAt: reset,
                resetText: ProviderPayload.resetText(reset, now: now)
            )
        }
        let balance = ProviderPayload.number(
            root,
            paths: [
                ["extraBalance"],
                ["extraUsageBalance"],
                ["planStatus", "extraBalance"]
            ]
        )
        guard !meters.isEmpty || balance != nil else {
            throw ProviderTransportError.invalidResponse(id)
        }
        return ProviderUsage(
            provider: id,
            planName: ProviderPayload.text(
                root,
                paths: [["planName"], ["plan"], ["subscriptionTier"]]
            ) ?? "",
            groups: [
                UsageGroup(
                    id: "devin-usage",
                    title: nil,
                    meters: meters,
                    creditText: balance.map {
                        "추가 잔액 \(ProviderPayload.money($0))"
                    }
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    private func parsePlanStatus(
        _ status: [String: Any],
        now: Date
    ) throws -> ProviderUsage {
        let planInfo = UsageJSON.object(status["planInfo"])
        let hideDaily = planInfo?["hideDailyQuota"] as? Bool == true
        var meters: [UsageMeter] = []
        if
            !hideDaily,
            let remaining = UsageJSON.number(
                status["dailyQuotaRemainingPercent"]
            )
        {
            let reset = UsageJSON.date(
                status["dailyQuotaResetAtUnix"]
            )
            meters.append(
                UsageMeter(
                    id: "devin-daily",
                    title: "일간",
                    period: .session,
                    percentRemaining: Int(remaining.rounded()),
                    resetsAt: reset,
                    resetText: ProviderPayload.resetText(
                        reset,
                        now: now
                    )
                )
            )
        }
        if let remaining = UsageJSON.number(
            status["weeklyQuotaRemainingPercent"]
        ) {
            let reset = UsageJSON.date(
                status["weeklyQuotaResetAtUnix"]
            )
            meters.append(
                UsageMeter(
                    id: "devin-weekly",
                    title: "주간",
                    period: .week,
                    percentRemaining: Int(remaining.rounded()),
                    resetsAt: reset,
                    resetText: ProviderPayload.resetText(
                        reset,
                        now: now
                    )
                )
            )
        }
        let balance = UsageJSON.number(
            status["overageBalanceMicros"]
        ).map { $0 / 1_000_000 }
        guard !meters.isEmpty || balance != nil else {
            throw ProviderTransportError.invalidResponse(id)
        }
        return ProviderUsage(
            provider: id,
            planName: (planInfo?["planName"] as? String) ?? "",
            groups: [
                UsageGroup(
                    id: "devin-usage",
                    title: nil,
                    meters: meters,
                    creditText: balance.map {
                        "추가 잔액 \(ProviderPayload.money($0))"
                    }
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }
}
