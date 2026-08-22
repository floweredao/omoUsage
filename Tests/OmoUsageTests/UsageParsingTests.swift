import Foundation
import Testing
@testable import OmoUsage

private let fixedNow = Date(timeIntervalSince1970: 1_785_675_000)

@Suite
struct UsageJSONTests {
    @Test
    func booleansAreNotAcceptedAsUsageNumbers() {
        #expect(UsageJSON.number(true) == nil)
        #expect(UsageJSON.number(false) == nil)
        #expect(UsageJSON.number(NSNumber(value: 2)) == 2)
    }
}

@Suite
struct ClaudeUsageParsingTests {
    @Test
    func parsesScreenshotVisibleMeters() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {
                    "utilization": 64,
                    "resets_at": "2026-08-02T15:29:00Z"
                  },
                  "seven_day": {
                    "utilization": 7,
                    "resets_at": "2026-08-08T12:00:00Z"
                  },
                  "extra_usage": {
                    "is_enabled": true,
                    "used_credits": 7800,
                    "monthly_limit": 10000
                  }
                }
                """.utf8
            ),
            planName: "Pro",
            now: fixedNow
        )

        #expect(usage.provider == .claude)
        #expect(usage.planName == "Pro")
        #expect(usage.groups.flatMap(\.meters).map(\.percentRemaining) == [36, 93, 22])
        #expect(usage.groups.flatMap(\.meters).map(\.title) == ["세션 (5시간)", "주간", "추가 사용량"])
        #expect(usage.groups.flatMap(\.meters).first?.showsMenuBarBadge == true)
        #expect(usage.groups.flatMap(\.meters).first?.resetsAt?.timeIntervalSince1970 == 1_785_684_540)
        #expect(usage.updatedAt == fixedNow)
    }

    @Test
    func usesFreshClaudeDesktopHistoryWhenClaudeCodeCredentialMissing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageClaudeDesktopTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let historyURL = directory.appending(path: "plan-usage-history.json")
        try Data(
            """
            {
              "version": 2,
              "samples": [
                {
                  "t": 1785674940000,
                  "org": "fixture-org",
                  "u": {
                    "fh": 64,
                    "sd": 7,
                    "xu": 78
                  }
                }
              ]
            }
            """.utf8
        ).write(to: historyURL)
        let missing = directory.appending(path: "missing.json")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: MissingClaudeKeychain()
        )
        let provider = ClaudeUsageProvider(
            discovery: discovery,
            http: ProviderHTTP(),
            desktopUsageURL: historyURL,
            desktopSessionDiscovery: .unavailable
        )

        let usage = try await provider.fetch(now: fixedNow)

        #expect(usage.provider == .claude)
        #expect(usage.planName.isEmpty)
        #expect(
            usage.groups.flatMap(\.meters).map(\.percentRemaining)
                == [36, 93, 22]
        )
        #expect(
            usage.updatedAt
                == Date(timeIntervalSince1970: 1_785_674_940)
        )
    }

    @Test
    func parsesLastKnownClaudeDesktopHistoryAfterIdlePeriod() throws {
        let usage = try ClaudeUsageParser.parseDesktopHistory(
            Data(
                """
                {
                  "version": 2,
                  "samples": [
                    {
                      "t": 1785653400000,
                      "u": {
                        "fh": 1,
                        "sd": 0
                      }
                    }
                  ]
                }
                """.utf8
            ),
            now: fixedNow
        )

        #expect(usage.provider == .claude)
        #expect(
            usage.groups.flatMap(\.meters).map(\.percentRemaining)
                == [99, 100]
        )
        #expect(
            usage.updatedAt
                == Date(timeIntervalSince1970: 1_785_653_400)
        )
    }
}

private struct MissingClaudeKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

@Suite(.serialized)
struct CodexUsageParsingTests {
    @Test
    func classifiesWeeklyWindowAndCredits() throws {
        let usage = try CodexUsageParser.parse(
            Data(
                """
                {
                  "plan_type": "plus",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 40,
                      "limit_window_seconds": 604800,
                      "reset_at": 1786100400
                    }
                  },
                  "credits": {
                    "balance": 0
                  }
                }
                """.utf8
            ),
            now: fixedNow
        )

        #expect(usage.provider == .codex)
        #expect(usage.planName == "Plus")
        #expect(usage.groups.flatMap(\.meters).map(\.title) == ["주간"])
        #expect(usage.groups.flatMap(\.meters).map(\.percentRemaining) == [60])
        #expect(usage.groups.first?.creditText == "크레딧 0")
        #expect(usage.groups.flatMap(\.meters).first?.resetsAt?.timeIntervalSince1970 == 1_786_100_400)
        #expect(usage.updatedAt == fixedNow)
    }

    @Test
    func reportsAvailableFullResetTickets() throws {
        let usage = try CodexUsageParser.parse(
            Data(
                """
                {
                  "plan_type": "pro",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 82,
                      "limit_window_seconds": 604800,
                      "reset_at": 1787467868
                    }
                  },
                  "credits": {
                    "balance": 0
                  },
                  "rate_limit_reset_credits": {
                    "available_count": 1,
                    "applicable_available_count": 0
                  }
                }
                """.utf8
            ),
            now: fixedNow
        )

        #expect(
            usage.groups.first?.creditText
                == "크레딧 0    풀 리셋 티켓 1"
        )
    }

    @Test
    func usesPersistedManualCodexProMultiplier() throws {
        let defaults = UserDefaults.standard
        let key = "codexPlanMultiplier"
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let data = Data(
            """
            {
              "plan_type": "pro",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 40,
                  "limit_window_seconds": 604800,
                  "reset_at": 1786100400
                }
              }
            }
            """.utf8
        )

        defaults.set("5x", forKey: key)
        #expect(
            try CodexUsageParser.parse(data, now: fixedNow)
                .planName == "Pro 5x"
        )

        defaults.set("20x", forKey: key)
        #expect(
            try CodexUsageParser.parse(data, now: fixedNow)
                .planName == "Pro 20x"
        )

        defaults.removeObject(forKey: key)
        #expect(
            try CodexUsageParser.parse(data, now: fixedNow)
                .planName == "Pro"
        )
    }

    @Test
    func mapsCurrentProlitePlanToPersistedProMultiplier() throws {
        let defaults = UserDefaults.standard
        let key = CodexPlanMultiplierStore.defaultsKey
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set("5x", forKey: key)
        let data = Data(
            """
            {
              "plan_type": "prolite",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 40,
                  "limit_window_seconds": 604800,
                  "reset_at": 1786100400
                }
              }
            }
            """.utf8
        )

        #expect(
            try CodexUsageParser.parse(data, now: fixedNow)
                .planName == "Pro 5x"
        )
    }
}

@Suite
struct AntigravityUsageParsingTests {
    @Test
    func parsesModelPoolsAndCredits() throws {
        let usage = try AntigravityUsageParser.parse(
            Data(
                """
                {
                  "plan": "pro",
                  "groups": [{
                    "buckets": [
                      {
                        "bucketId": "gemini-5h",
                        "remainingFraction": 1,
                        "resetTime": "2026-08-02T16:48:00Z"
                      },
                      {
                        "bucketId": "gemini-weekly",
                        "remainingFraction": 0.73,
                        "resetTime": "2026-08-04T12:00:00Z"
                      },
                      {
                        "bucketId": "3p-5h",
                        "remainingFraction": 1,
                        "resetTime": "2026-08-02T16:53:00Z"
                      },
                      {
                        "bucketId": "3p-weekly",
                        "remainingFraction": 0.83,
                        "resetTime": "2026-08-05T12:00:00Z"
                      }
                    ]
                  }],
                  "credits": {
                    "prompt": 500,
                    "flow": 100
                  }
                }
                """.utf8
            ),
            now: fixedNow
        )

        #expect(usage.provider == .antigravity)
        #expect(usage.planName == "Pro")
        #expect(usage.groups.map(\.title) == ["Gemini Models", "Claude and GPT models"])
        #expect(usage.groups.flatMap(\.meters).map(\.percentRemaining) == [100, 73, 100, 83])
        #expect(usage.groups.last?.creditText == "프롬프트 크레딧 500    플로우 크레딧 100")
        #expect(usage.groups.flatMap(\.meters).first?.resetsAt?.timeIntervalSince1970 == 1_785_689_280)
        #expect(usage.updatedAt == fixedNow)
    }
}
