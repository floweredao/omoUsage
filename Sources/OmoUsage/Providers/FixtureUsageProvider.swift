import OmoUsageCore
import Foundation

private actor FixtureRateLimitReads {
    static let shared = FixtureRateLimitReads()
    private var read: Set<AccountID> = []

    /// Records this read and returns whether the account was read before.
    func hasRead(_ accountID: AccountID) -> Bool {
        !read.insert(accountID).inserted
    }
}

struct FixtureUsageProvider: UsageProvider {
    let id: ProviderID
    let accountID: AccountID
    let accountLabel: String
    private let claudeCredentialDiscovery: CredentialDiscovery?
    private let codexPlanMultiplierStore: CodexPlanMultiplierStore
    private let codexReportedPlan: String

    init(
        id: ProviderID,
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue,
        claudeCredentialDiscovery: CredentialDiscovery? = nil,
        defaults: UserDefaults = .standard,
        codexReportedPlan: String = "plus"
    ) {
        self.id = id
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.claudeCredentialDiscovery = claudeCredentialDiscovery
        self.codexPlanMultiplierStore = CodexPlanMultiplierStore(defaults: defaults, accountID: accountID)
        self.codexReportedPlan = codexReportedPlan
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        switch id {
        case .claude:
            // The native Claude UI QA fixture supplies this real discovery
            // path. Without the persisted, explicitly authorized mirror it
            // throws notFound rather than making fixture usage look connected.
            _ = try claudeCredentialDiscovery?.claude(now: now)
            // Rate-limit QA: the first read succeeds, every later one gets
            // the 429 a throttled account sees.
            if
                ProcessInfo.processInfo.environment[
                    "OMO_USAGE_FIXTURE_CLAUDE_RATE_LIMIT"
                ] == "1",
                await FixtureRateLimitReads.shared.hasRead(accountID)
            {
                throw ProviderTransportError.requestFailed(.claude, 429)
            }
            let json = claudeCredentialDiscovery == nil
                ? Self.claudeJSON
                : Self.claudeAuthenticationUIJSON
            return try ClaudeUsageParser.parse(
                Data(json.utf8),
                planName: "Pro",
                now: now.addingTimeInterval(-60)
            )
        case .codex:
            return try CodexUsageParser.parse(
                Data(Self.codexJSON.replacingOccurrences(
                    of: "\"plan_type\": \"plus\"",
                    with: "\"plan_type\": \"\(codexReportedPlan)\""
                ).utf8),
                now: now.addingTimeInterval(-15 * 60),
                planMultiplier: codexPlanMultiplierStore.load()
            )
        case .antigravity:
            return try AntigravityUsageParser.parse(
                Data(Self.antigravityJSON.utf8),
                now: now
            )
        case .kiro:
            return ProviderUsage(
                provider: .kiro,
                planName: "Kiro Pro",
                groups: [
                    UsageGroup(
                        id: "kiro-credits",
                        title: nil,
                        meters: [
                            UsageMeter(
                                id: "kiro-monthly",
                                title: "월간",
                                period: .session,
                                percentRemaining: 72,
                                resetsAt: now.addingTimeInterval(604_800),
                                resetText: "7일 후 리셋"
                            )
                        ],
                        creditText: "360 / 500 크레딧"
                    )
                ],
                availability: .available,
                updatedAt: now
            )
        case .cursor, .copilot, .devin, .grok, .opencode,
             .openrouter, .zai:
            return Self.additionalFixture(provider: id, now: now)
        }
    }

    private static func additionalFixture(
        provider: ProviderID,
        now: Date
    ) -> ProviderUsage {
        var meters = [
            UsageMeter(
                id: "\(provider.rawValue)-week",
                title: "주간",
                period: .week,
                percentRemaining: 72,
                resetText: "4일 후 리셋"
            )
        ]
        if provider == .openrouter {
            meters.append(contentsOf: [
                UsageMeter(
                    id: "fixture-spend",
                    title: "최근 30일",
                    period: .extra,
                    metric: .spend(amount: 3, currency: .usd)
                ),
                UsageMeter(
                    id: "fixture-credit",
                    title: "크레딧",
                    period: .extra,
                    metric: .credit(balance: 12, unit: .credits)
                ),
                UsageMeter(
                    id: "fixture-count",
                    title: "요청",
                    period: .extra,
                    metric: .count(value: 500, unit: .requests)
                ),
                UsageMeter(
                    id: "fixture-information",
                    title: "결제",
                    period: .extra,
                    metric: .informational(value: "수동 갱신")
                )
            ])
        }
        return ProviderUsage(
            provider: provider,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: "\(provider.rawValue)-usage",
                    title: nil,
                    meters: meters,
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: now
        )
    }

    private static let claudeJSON = """
    {
      "five_hour": {
        "utilization": 64,
        "resets_at": "2099-01-01T03:32:00Z",
        "reset_text": "3시간 32분 후 리셋"
      },
      "seven_day": {
        "utilization": 7,
        "resets_at": "2099-01-07T00:00:00Z",
        "reset_text": "6일 후 리셋"
      },
      "limits": [
        {
          "kind": "weekly_scoped",
          "group": "weekly",
          "percent": 44,
          "resets_at": "2099-01-07T00:00:00Z",
          "scope": {
            "model": {
              "id": null,
              "display_name": "Fable"
            }
          }
        }
      ],
      "extra_usage": {
        "is_enabled": true,
        "used_credits": 7800,
        "monthly_limit": 10000,
        "reset_text": "1분 전 기준"
      },
      "cedar_ember": {
        "eligible": true,
        "grants": [
          {
            "id": "opus55-launch-promax-20260921",
            "resets_total": 1,
            "resets_left": 1,
            "starts_at": "2098-01-01T00:00:00Z",
            "ends_at": "2099-02-01T00:00:00Z",
            "clears": ["five_hour", "seven_day"],
            "paused": false,
            "usable_now": true
          }
        ],
        "next_grant_id": "opus55-launch-promax-20260921"
      },
      "iguana_necktie": {
        "utilization": 12,
        "resets_at": "2099-02-05T00:00:00Z",
        "limit_dollars": 250,
        "used_dollars": 30,
        "remaining_dollars": 220
      }
    }
    """

    /// Isolated native-auth QA exercises the parser's fallback from a null
    /// percent to utilization, plus a null scoped reset timestamp. Default
    /// fixture mode intentionally retains the stable payload above.
    private static let claudeAuthenticationUIJSON = claudeJSON
        .replacingOccurrences(
            of: "\"percent\": 44,\n      \"resets_at\": \"2099-01-07T00:00:00Z\"",
            with: "\"percent\": null,\n      \"utilization\": 44,\n      \"resets_at\": null"
        )

    private static let codexJSON = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "primary_window": {
          "used_percent": 40,
          "limit_window_seconds": 18000,
          "reset_at": 4070926800,
          "reset_text": "3시간 후 리셋"
        },
        "secondary_window": {
          "used_percent": 12,
          "limit_window_seconds": 604800,
          "reset_at": 4071340800,
          "reset_text": "5일 후 리셋"
        }
      },
      "credits": { "balance": 0 }
    }
    """

    private static let antigravityJSON = """
    {
      "plan": "pro",
      "groups": [{
        "buckets": [
          {
            "bucketId": "gemini-5h",
            "remainingFraction": 1,
            "resetTime": "2099-01-01T04:51:00Z",
            "resetText": "4시간 51분 후 리셋"
          },
          {
            "bucketId": "gemini-weekly",
            "remainingFraction": 0.73,
            "resetTime": "2099-01-03T00:00:00Z",
            "resetText": "2일 후 리셋"
          },
          {
            "bucketId": "3p-5h",
            "remainingFraction": 1,
            "resetTime": "2099-01-01T04:56:00Z",
            "resetText": "4시간 56분 후 리셋"
          },
          {
            "bucketId": "3p-weekly",
            "remainingFraction": 0.83,
            "resetTime": "2099-01-04T00:00:00Z",
            "resetText": "3일 후 리셋"
          }
        ]
      }],
      "credits": { "prompt": 500, "flow": 100 }
    }
    """
}
