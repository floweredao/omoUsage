import Foundation

struct OpenCodeUsageProvider: UsageProvider {
    let id = ProviderID.opencode
    let discovery: CredentialDiscovery
    let http: ProviderHTTP

    init(
        discovery: CredentialDiscovery,
        http: ProviderHTTP = ProviderHTTP()
    ) {
        self.discovery = discovery
        self.http = http
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        let credential = try discovery.opencode()
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
        let data = try await http.data(for: request, provider: id)
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
                let used = UsageJSON.number(window["percent"])
            else {
                return nil
            }
            return UsageMeter(
                id: "opencode-\(key)",
                title: title,
                period: period,
                percentRemaining: ProviderPayload.remainingPercent(
                    usedPercent: used
                ),
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
        let directory = discovery.openCodeDataDirectory
        let databases = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("opencode")
                && $0.pathExtension == "db"
        }
        var hostedMonth = 0.0
        for database in databases {
            hostedMonth += try sum(
                database,
                providers: ["opencode-go", "opencode"],
                since: now.addingTimeInterval(-30 * 86_400)
            )
        }
        return ProviderUsage(
            provider: id,
            planName: "Zen",
            groups: [
                UsageGroup(
                    id: "opencode-usage",
                    title: nil,
                    meters: [],
                    creditText: "최근 30일 \(ProviderPayload.money(hostedMonth))"
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
        let value = try LocalDataAccess.sqliteValue(
            database: database,
            sql: sql
        )
        return Double(value ?? "0") ?? 0
    }

}
