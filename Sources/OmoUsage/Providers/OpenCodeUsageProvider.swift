import OmoUsageCore
import Foundation

struct OpenCodeUsageProvider: UsageProvider {
    let id = ProviderID.opencode
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
        let credential = try discovery.opencode(accountID: accountID)
        if credential.accessToken != "local" {
            return try await fetchGoUsage(
                token: credential.accessToken,
                now: now
            )
        }
        return try localUsage(now: now)
    }

    private func fetchGoUsage(
        token: String,
        now: Date
    ) async throws -> ProviderUsage {
        let endpoint = ProviderContractCatalog.endpoint(
            .openCodeGoUsage,
            for: id
        )
        var request = URLRequest(
            url: URL(
                string: "https://opencode.ai/zen/go/v1/usage"
            )!
        )
        request.timeoutInterval = 15
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await http.data(for: request, endpoint: endpoint)
        return try endpoint.schemaChecked {
            try parseGoUsage(data, now: now)
        }
    }

    private func parseGoUsage(
        _ data: Data,
        now: Date
    ) throws -> ProviderUsage {
        let root = try ProviderPayload.object(data)
        guard let usage = UsageJSON.object(root["usage"]) else {
            throw ProviderTransportError.invalidResponse(id)
        }
        let definitions: [(String, String, UsagePeriod)] = [
            ("rolling", "세션", .session),
            ("weekly", "주간", .week),
            ("monthly", "월간", .extra)
        ]
        let meters: [UsageMeter] = definitions.compactMap {
            definition -> UsageMeter? in
            let (key, title, period) = definition
            guard
                let window = UsageJSON.object(usage[key]),
                let used = UsageJSON.number(window["percent"]),
                let remaining = ProviderPayload.remainingPercent(
                    usedPercent: used
                )
            else {
                return nil
            }
            return UsageMeter(
                id: "opencode-\(key)",
                title: title,
                period: period,
                percentRemaining: remaining,
                resetsAt: UsageJSON.date(window["resetsAt"])
            )
        }
        guard !meters.isEmpty else {
            throw ProviderTransportError.invalidResponse(id)
        }
        return ProviderUsage(
            provider: id,
            planName: "Go",
            groups: [
                UsageGroup(
                    id: "opencode-usage",
                    title: nil,
                    meters: meters,
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    private func localUsage(now: Date) throws -> ProviderUsage {
        let database: URL
        do {
            guard let selected = try discovery.openCodeDatabase() else {
                throw CredentialDiscoveryError.malformed(.opencode)
            }
            database = selected
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CredentialDiscoveryError {
            throw error
        } catch {
            throw CredentialDiscoveryError.malformed(.opencode)
        }
        let hostedMonth: Double
        do {
            hostedMonth = try sum(
                database,
                providers: ["opencode-go", "opencode"],
                since: now.addingTimeInterval(-30 * 86_400)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CredentialDiscoveryError.malformed(.opencode)
        }
        return ProviderUsage(
            provider: id,
            planName: "Zen",
            groups: [
                UsageGroup(
                    id: "opencode-usage",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "opencode-local-spend",
                            title: "최근 30일",
                            period: .extra,
                            metric: .spend(
                                amount: hostedMonth,
                                currency: .usd
                            )
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    private func sum(
        _ database: URL,
        providers: [String],
        since: Date
    ) throws -> Double {
        let ids = providers.map { "'\($0)'" }.joined(separator: ",")
        let milliseconds = Int(since.timeIntervalSince1970 * 1_000)
        let sql = """
        SELECT COALESCE(SUM(json_extract(data, '$.cost')), 0)
        FROM message
        WHERE time_created >= \(milliseconds)
          AND json_valid(data)
          AND json_extract(data, '$.role') = 'assistant'
          AND json_extract(data, '$.providerID') IN (\(ids));
        """
        guard
            let value = try LocalDataAccess.sqliteValue(
                database: database,
                sql: sql
            ),
            let total = Double(value),
            total.isFinite
        else {
            throw CredentialDiscoveryError.malformed(.opencode)
        }
        return total
    }

}
