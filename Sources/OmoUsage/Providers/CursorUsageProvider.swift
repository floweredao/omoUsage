import Foundation

struct CursorUsageProvider: UsageProvider {
    let id = ProviderID.cursor
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    func fetch(now: Date) async throws -> ProviderUsage {
        let credential = try discovery.cursor(now: now)
        async let usageData = get(
            "/api/usage-summary",
            purpose: .cursorUsageSummary,
            token: credential.accessToken
        )
        async let planData = try? get(
            "/auth/me",
            purpose: .cursorAccount,
            token: credential.accessToken
        )
        let (usage, plan) = try await (usageData, planData)
        let endpoint = ProviderContractCatalog.endpoint(
            .cursorUsageSummary,
            for: id
        )
        return try endpoint.schemaChecked {
            try parse(usage, plan: plan, now: now)
        }
    }

    private func get(
        _ path: String,
        purpose: ProviderEndpointPurpose,
        token: String
    ) async throws -> Data {
        let endpoint = ProviderContractCatalog.endpoint(purpose, for: id)
        var request = URLRequest(
            url: URL(string: "https://api2.cursor.sh\(path)")!
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await http.data(for: request, endpoint: endpoint)
    }

    private func parse(
        _ data: Data,
        plan: Data?,
        now: Date
    ) throws -> ProviderUsage {
        let root = try ProviderPayload.object(data)
        let definitions: [
            (String, UsagePeriod, [[String]])
        ] = [
            ("총 사용량", .week, [
                ["individualUsage", "plan", "totalPercentUsed"],
                ["planUsage", "usedPercent"],
                ["currentPeriodUsage", "usedPercent"],
                ["usedPercent"],
                ["usagePercent"]
            ]),
            ("Auto 사용량", .extra, [
                ["individualUsage", "plan", "autoPercentUsed"],
                ["autoUsage", "usedPercent"],
                ["auto", "usedPercent"],
                ["autoPercentUsed"]
            ]),
            ("API 사용량", .extra, [
                ["individualUsage", "plan", "apiPercentUsed"],
                ["apiUsage", "usedPercent"],
                ["api", "usedPercent"],
                ["apiPercentUsed"]
            ])
        ]
        let reset = ProviderPayload.date(
            root,
            paths: [
                ["billingCycleEnd"],
                ["currentPeriodUsage", "endDate"],
                ["resetAt"]
            ]
        )
        let meters = definitions.compactMap {
            definition -> UsageMeter? in
            let (title, period, paths) = definition
            guard
                let used = ProviderPayload.number(root, paths: paths),
                let remaining = ProviderPayload.remainingPercent(
                    usedPercent: used
                )
            else {
                return nil
            }
            return UsageMeter(
                id: "cursor-\(title)",
                title: title,
                period: period,
                percentRemaining: remaining,
                resetsAt: reset,
                resetText: ProviderPayload.resetText(reset, now: now)
            )
        }
        let credits = ProviderPayload.number(
            root,
            paths: [
                ["individualUsage", "onDemand", "remaining"],
                ["creditBalance"],
                ["creditsBalance"],
                ["credits", "balance"]
            ]
        )
        guard !meters.isEmpty || credits != nil else {
            throw ProviderTransportError.invalidResponse(id)
        }
        let planRoot: [String: Any]? = if let plan {
            try? ProviderPayload.object(plan)
        } else {
            nil
        }
        let reportedPlan = ProviderPayload.text(
            root,
            paths: [["membershipType"], ["planName"], ["plan"]]
        ) ?? planRoot.flatMap {
            ProviderPayload.text(
                $0,
                paths: [["membershipType"], ["planName"], ["plan"]]
            )
        }
        let planName = reportedPlan?.capitalized ?? ""
        return ProviderUsage(
            provider: id,
            planName: planName,
            groups: [
                UsageGroup(
                    id: "cursor-usage",
                    title: nil,
                    meters: meters,
                    creditText: credits.map {
                        "크레딧 \(ProviderPayload.money($0))"
                    }
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }
}
