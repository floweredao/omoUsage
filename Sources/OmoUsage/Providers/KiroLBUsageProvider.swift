import OmoUsageCore
import Foundation

struct KiroLBUsageProvider: UsageProvider {
    static let sessionCookieName = "kiro_lb_session"

    let id = ProviderID.kiroLB
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
        let base = try KiroLBGatewayConfiguration.validatedBaseURL(
            discovery.kiroLBGateway.baseURL
        )
        let credential = try discovery.kiroLB(accountID: accountID)
        let session = try await login(base: base, password: credential.accessToken)
        let data = try await accounts(base: base, session: session)
        return try ProviderContractCatalog.endpoint(.kiroLBAccounts, for: id)
            .schemaChecked {
                try KiroLBUsageParser.parse(data, now: now)
            }
    }

    private func login(base: URL, password: String) async throws -> String? {
        var request = URLRequest(url: base.appending(path: "api/dashboard/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["password": password]
        )
        let (data, response) = try await http.response(
            for: request,
            endpoint: ProviderContractCatalog.endpoint(.kiroLBLogin, for: id)
        )
        if let cookie = Self.sessionCookie(response) {
            return cookie
        }
        if (try? ProviderPayload.object(data))?["authRequired"] as? Bool == false {
            return nil
        }
        throw ProviderTransportError.invalidResponse(id)
    }

    private func accounts(base: URL, session: String?) async throws -> Data {
        var request = URLRequest(url: base.appending(path: "api/dashboard/accounts"))
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let session {
            request.setValue(
                "\(Self.sessionCookieName)=\(session)",
                forHTTPHeaderField: "Cookie"
            )
        }
        return try await http.data(
            for: request,
            endpoint: ProviderContractCatalog.endpoint(.kiroLBAccounts, for: id)
        )
    }

    static func sessionCookie(_ response: HTTPURLResponse) -> String? {
        guard
            let header = response.value(forHTTPHeaderField: "Set-Cookie"),
            let range = header.range(of: "\(sessionCookieName)=")
        else {
            return nil
        }
        let value = header[range.upperBound...].prefix {
            $0 != ";" && $0 != "," && !$0.isWhitespace
        }
        return value.isEmpty ? nil : String(value)
    }
}

enum KiroLBUsageParser {
    struct Account: Equatable {
        let title: String
        let used: Double
        let limit: Double
        let resetsAt: Date?
    }

    static func parse(_ data: Data, now: Date) throws -> ProviderUsage {
        let root = try ProviderPayload.object(data)
        guard let entries = UsageJSON.array(root["accounts"]) else {
            throw UsageParsingError.invalidPayload
        }
        let accounts = entries.compactMap(account)
        guard
            !accounts.isEmpty,
            let poolPercent = poolRemainingPercent(accounts)
                .flatMap(ProviderPayload.percent)
        else {
            throw UsageParsingError.invalidPayload
        }
        let poolReset = accounts.compactMap(\.resetsAt).min()
        var meters = [
            UsageMeter(
                id: "kirolb-pool",
                title: "전체",
                period: .session,
                percentRemaining: poolPercent,
                resetsAt: poolReset,
                resetText: ProviderPayload.resetText(poolReset, now: now)
            )
        ]
        for (offset, account) in accounts.enumerated() {
            guard
                let percent = ProviderPayload.percent(
                    (account.limit - min(account.used, account.limit))
                        / account.limit * 100
                )
            else {
                throw UsageParsingError.invalidPayload
            }
            let position = offset + 1
            meters.append(
                UsageMeter(
                    id: "kirolb-account-\(position)",
                    title: "\(account.title) \(position)",
                    period: .session,
                    percentRemaining: percent,
                    resetsAt: account.resetsAt,
                    resetText: ProviderPayload.resetText(account.resetsAt, now: now)
                )
            )
        }
        var seenTitles: Set<String> = []
        let planName = accounts.map(\.title)
            .filter { seenTitles.insert($0).inserted }
            .joined(separator: ", ")
        return ProviderUsage(
            provider: .kiroLB,
            planName: planName,
            groups: [
                UsageGroup(
                    id: "kirolb-usage",
                    title: nil,
                    meters: meters,
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    static func poolRemainingPercent(_ accounts: [Account]) -> Double? {
        let limit = accounts.reduce(0) { $0 + $1.limit }
        guard limit > 0 else { return nil }
        let used = accounts.reduce(0) { $0 + min($1.used, $1.limit) }
        return (limit - used) / limit * 100
    }

    static func account(_ entry: [String: Any]) -> Account? {
        guard
            entry["enabled"] as? Bool != false,
            let usage = UsageJSON.object(entry["usage"]),
            usage["error"] == nil || usage["error"] is NSNull,
            let limit = ProviderPayload.number(usage, paths: [["usageLimit"]]),
            limit > 0,
            let used = ProviderPayload.number(usage, paths: [["currentUsage"]])
        else {
            return nil
        }
        return Account(
            title: displayTitle(
                ProviderPayload.text(usage, paths: [["subscriptionTitle"]])
            ),
            used: max(0, used),
            limit: limit,
            resetsAt: ProviderPayload.date(usage, paths: [["nextDateReset"]])
                ?? ProviderPayload.date(entry, paths: [["quotaResetsAt"]])
        )
    }

    static func displayTitle(_ subscriptionTitle: String?) -> String {
        var title = subscriptionTitle ?? ""
        if title.uppercased().hasPrefix("KIRO ") {
            title = String(title.dropFirst("KIRO ".count))
        }
        let words = title.split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased().capitalized }
        return words.isEmpty ? "Kiro" : words.joined(separator: " ")
    }
}
