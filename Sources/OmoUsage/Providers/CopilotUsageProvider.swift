import OmoUsageCore
import Foundation

struct CopilotUsageProvider: UsageProvider {
    let id = ProviderID.copilot
    let accountID: AccountID
    let accountLabel: String
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    init(
        discovery: CredentialDiscovery,
        http: ProviderHTTP = ProviderHTTP(),
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue
    ) {
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.discovery = discovery
        self.http = http
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        let credential = try discovery.copilot(accountID: accountID)
        let endpoint = ProviderContractCatalog.endpoint(.copilotUser, for: id)
        var request = URLRequest(
            url: URL(
                string: "https://api.github.com/copilot_internal/user"
            )!
        )
        request.timeoutInterval = 15
        request.setValue(
            "token \(credential.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue(
            "copilot-chat/0.26.7",
            forHTTPHeaderField: "Editor-Plugin-Version"
        )
        request.setValue(
            "2025-04-01",
            forHTTPHeaderField: "X-Github-Api-Version"
        )
        request.setValue(
            "GitHubCopilotChat/0.26.7",
            forHTTPHeaderField: "User-Agent"
        )
        let data = try await http.data(for: request, endpoint: endpoint)
        return try endpoint.schemaChecked {
            try parse(data, now: now)
        }
    }

    private func parse(_ data: Data, now: Date) throws -> ProviderUsage {
        let root = try ProviderPayload.object(data)
        let snapshots = ProviderPayload.dictionary(
            root,
            ["quota_snapshots", "quotaSnapshots"]
        ) ?? [:]
        let reset = ProviderPayload.date(
            root,
            paths: [["quota_reset_date"], ["quotaResetDate"]]
        )
        let definitions = [
            ("premium_interactions", "크레딧"),
            ("extra_usage", "추가 사용량"),
            ("chat", "Chat"),
            ("completions", "Completions")
        ]
        let meters = definitions.compactMap {
            definition -> UsageMeter? in
            let (key, title) = definition
            guard
                let entry = UsageJSON.object(snapshots[key]),
                entry["unlimited"] as? Bool != true,
                let value = UsageJSON.number(
                    entry["percent_remaining"]
                        ?? entry["percentRemaining"]
                ),
                let remaining = ProviderPayload.percent(value)
            else {
                return nil
            }
            let entryReset = UsageJSON.date(
                entry["reset_date"] ?? entry["resetDate"]
            ) ?? reset
            return UsageMeter(
                id: "copilot-\(key)",
                title: title,
                period: key == "chat" ? .session : .extra,
                percentRemaining: remaining,
                resetsAt: entryReset,
                resetText: ProviderPayload.resetText(
                    entryReset,
                    now: now
                )
            )
        }
        let freeMeters = freeQuotaMeters(root, now: now)
        let allMeters = meters + freeMeters
        let plan = ProviderPayload.text(
            root,
            paths: [["copilot_plan"], ["copilotPlan"], ["plan"]]
        )?.replacingOccurrences(of: "_", with: " ").capitalized ?? ""
        guard !allMeters.isEmpty || !plan.isEmpty else {
            throw ProviderTransportError.invalidResponse(id)
        }
        return ProviderUsage(
            provider: id,
            planName: plan,
            groups: allMeters.isEmpty ? [] : [
                UsageGroup(
                    id: "copilot-usage",
                    title: nil,
                    meters: allMeters,
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    private func freeQuotaMeters(
        _ root: [String: Any],
        now: Date
    ) -> [UsageMeter] {
        guard
            let used = ProviderPayload.dictionary(
                root,
                ["limited_user_quotas"]
            ),
            let limits = ProviderPayload.dictionary(
                root,
                ["monthly_quotas"]
            )
        else {
            return []
        }
        let reset = ProviderPayload.date(
            root,
            paths: [["limited_user_reset_date"]]
        )
        let definitions: [(String, String, UsagePeriod)] = [
            ("chat", "Chat", .session),
            ("completions", "Completions", .extra)
        ]
        return definitions.compactMap { key, title, period in
            guard
                let current = UsageJSON.number(used[key]),
                let limit = UsageJSON.number(limits[key]),
                let remaining = ProviderPayload.percent(
                    current / limit * 100
                )
            else {
                return nil
            }
            return UsageMeter(
                id: "copilot-\(key)",
                title: title,
                period: period,
                percentRemaining: remaining,
                resetsAt: reset,
                resetText: ProviderPayload.resetText(reset, now: now)
            )
        }
    }
}
