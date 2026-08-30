import Foundation

struct FixtureUsageProvider: UsageProvider {
    let id: ProviderID
    let accountID: AccountID
    let accountLabel: String

    init(
        id: ProviderID,
        accountID: AccountID = .legacy,
        accountLabel: String = AccountLabel.defaultValue
    ) {
        self.id = id
        self.accountID = accountID
        self.accountLabel = accountLabel
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        switch id {
        case .claude:
            try ClaudeUsageParser.parse(
                Data(Self.claudeJSON.utf8),
                planName: "Pro",
                now: now.addingTimeInterval(-60)
            )
        case .codex:
            try CodexUsageParser.parse(
                Data(Self.codexJSON.utf8),
                now: now.addingTimeInterval(-15 * 60)
            )
        case .antigravity:
            try AntigravityUsageParser.parse(
                Data(Self.antigravityJSON.utf8),
                now: now
            )
        case .cursor, .copilot, .devin, .grok, .opencode,
             .openrouter, .zai:
            Self.additionalFixture(provider: id, now: now)
        }
    }

    private static func additionalFixture(
        provider: ProviderID,
        now: Date
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: "\(provider.rawValue)-usage",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "\(provider.rawValue)-week",
                            title: "주간",
                            period: .week,
                            percentRemaining: 72,
                            resetText: "4일 후 리셋"
                        )
                    ],
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
      }
    }
    """

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
