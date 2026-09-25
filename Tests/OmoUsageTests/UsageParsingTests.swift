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
    @Test(arguments: [0.0, 0.1, 100.0], [
        "",
        ", \"resets_at\": null",
        ", \"resets_at\": \"2026-08-02T15:29:00Z\""
    ])
    func preservesFiveHourSessionRegardlessOfResetAvailability(
        used: Double,
        resetField: String
    ) throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": \(used)\(resetField)},
                  "seven_day": {"utilization": 25}
                }
                """.utf8
            ),
            planName: "Max",
            now: fixedNow
        )
        let meters = usage.groups.flatMap(\.meters)
        let session = try #require(meters.first { $0.id == "claude.session" })
        #expect(session.period == .session)
        #expect(session.percentRemaining == Int((100 - used).rounded()))
        #expect(session.showsMenuBarBadge)
        #expect(session.resetText == nil)
        #expect(session.resetsAt == (resetField.contains("2026")
            ? Date(timeIntervalSince1970: 1_785_684_540) : nil))
        #expect(SideNotchSummaryMeterPolicy.select(from: meters)?.id == session.id)
    }

    @Test
    func stillRejectsMalformedFiveHourResetDate() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": 0, "resets_at": "not-a-date"},
                  "seven_day": {"utilization": 25}
                }
                """.utf8
            ),
            planName: "Max",
            now: fixedNow
        )
        #expect(usage.groups.flatMap(\.meters).map(\.id) == ["claude.week"])
    }

    @Test
    func preservesFableWeeklyUsageWithoutAResetDate() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": 4},
                  "limits": [{
                    "kind": "weekly_scoped",
                    "percent": 44,
                    "resets_at": null,
                    "scope": {"model": {"id": null, "display_name": "Fable"}}
                  }]
                }
                """.utf8
            ),
            planName: "Max",
            now: fixedNow
        )
        let meter = try #require(
            usage.groups.flatMap(\.meters)
                .first { $0.id == "claude.week.model.fable" }
        )
        #expect(meter.percentRemaining == 56)
        #expect(meter.resetsAt == nil)
    }

    @Test
    func surfacesResetVouchersAndCloudSessionCredits() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": 100, "resets_at": "2026-08-02T18:30:00Z"},
                  "seven_day": {"utilization": 18, "resets_at": "2026-08-08T00:00:00Z"},
                  "cedar_ember": {
                    "eligible": true,
                    "at_limit": true,
                    "exhausted": ["five_hour"],
                    "grants": [
                      {
                        "id": "opus55-launch-promax-20260921",
                        "resets_total": 1,
                        "resets_left": 1,
                        "starts_at": "2026-08-01T00:00:00Z",
                        "ends_at": "2026-09-01T00:00:00Z",
                        "clears": ["five_hour", "seven_day"],
                        "paused": false,
                        "usable_now": true
                      },
                      {
                        "id": "expired-grant",
                        "resets_total": 1,
                        "resets_left": 1,
                        "starts_at": "2026-06-01T00:00:00Z",
                        "ends_at": "2026-07-01T00:00:00Z",
                        "clears": ["five_hour"],
                        "paused": false,
                        "usable_now": false
                      },
                      {
                        "id": "paused-grant",
                        "resets_total": 2,
                        "resets_left": 2,
                        "starts_at": "2026-08-01T00:00:00Z",
                        "ends_at": "2026-09-10T00:00:00Z",
                        "clears": ["five_hour"],
                        "paused": true,
                        "usable_now": false
                      }
                    ],
                    "next_grant_id": "opus55-launch-promax-20260921"
                  },
                  "iguana_necktie": {
                    "utilization": 12,
                    "resets_at": "2026-09-10T00:00:00Z",
                    "limit_dollars": 250,
                    "used_dollars": 30,
                    "remaining_dollars": 220
                  }
                }
                """.utf8
            ),
            planName: "Max",
            now: fixedNow
        )
        let meters = usage.groups.flatMap(\.meters)
        let resets = try #require(
            meters.first { $0.id == "claude.reset-tickets" }
        )
        #expect(resets.metric == .count(value: 1, unit: .tickets))
        #expect(resets.title == "초기화권")
        #expect(resets.resetText == "29일 후 만료")
        let credits = try #require(
            meters.first { $0.id == "claude.cloud-session-credits" }
        )
        #expect(credits.metric == .credit(balance: 220, unit: .usd))
        #expect(credits.resetText == "38일 후 만료") // 2026-09-10 minus 2026-08-02T15:30 = 38d 8.5h
    }

    @Test
    func omitsIneligibleOrSpentResetVouchersAndNullCredits() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": 42},
                  "cedar_ember": {
                    "eligible": false,
                    "ineligible_reason": "no_grant",
                    "grants": []
                  },
                  "iguana_necktie": null
                }
                """.utf8
            ),
            planName: "Max",
            now: fixedNow
        )
        #expect(usage.groups.flatMap(\.meters).map(\.id) == ["claude.session"])
    }

    @Test
    func cloudSessionCreditsFallBackToUtilizationWithoutDollars() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": 10},
                  "iguana_necktie": {
                    "utilization": 25,
                    "resets_at": null,
                    "limit_dollars": null,
                    "used_dollars": null,
                    "remaining_dollars": null
                  }
                }
                """.utf8
            ),
            planName: "Max",
            now: fixedNow
        )
        let meter = try #require(
            usage.groups.flatMap(\.meters)
                .first { $0.id == "claude.cloud-session-credits" }
        )
        #expect(meter.metric == .quotaRemaining(percent: 75))
        #expect(meter.resetText == nil)
    }

    @Test
    func usesScopedUtilizationWhenPercentIsNull() throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {
                  "five_hour": {"utilization": 4},
                  "limits": [{
                    "kind": "weekly_scoped",
                    "percent": null,
                    "utilization": 37,
                    "scope": {"model": {"display_name": "Fable"}}
                  }]
                }
                """.utf8
            ),
            planName: "Max",
            now: fixedNow
        )
        let meter = try #require(
            usage.groups.flatMap(\.meters)
                .first { $0.id == "claude.week.model.fable" }
        )
        #expect(meter.percentRemaining == 63)
    }

    @Test
    func doesNotInventScopedUsageFromMissingNumbersOrMalformedReset() throws {
        for fields in [
            "\"percent\": null, \"utilization\": null",
            "\"percent\": 44, \"resets_at\": \"not-a-date\""
        ] {
            let usage = try ClaudeUsageParser.parse(
                Data(
                    """
                    {
                      "five_hour": {"utilization": 4},
                      "limits": [{
                        "kind": "weekly_scoped",
                        \(fields),
                        "scope": {"model": {"display_name": "Fable"}}
                      }]
                    }
                    """.utf8
                ),
                planName: "Max",
                now: fixedNow
            )
            #expect(usage.groups.flatMap(\.meters).map(\.id) == ["claude.session"])
        }
    }

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
    @Test(arguments: [0.0, 0.1, 100.0], [
        "",
        ", \"reset_at\": null",
        ", \"reset_at\": 1785684540"
    ])
    func preservesFiveHourSessionRegardlessOfResetAvailability(
        used: Double,
        resetField: String
    ) throws {
        let usage = try CodexUsageParser.parse(
            Data(
                """
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": \(used),
                      "limit_window_seconds": 18000\(resetField)
                    },
                    "secondary_window": {
                      "used_percent": 25,
                      "limit_window_seconds": 604800
                    }
                  }
                }
                """.utf8
            ),
            now: fixedNow
        )
        let meters = usage.groups.flatMap(\.meters)
        let session = try #require(meters.first { $0.id == "codex.session" })
        #expect(session.period == .session)
        #expect(session.percentRemaining == Int((100 - used).rounded()))
        #expect(session.showsMenuBarBadge)
        #expect(session.resetText == nil)
        #expect(session.resetsAt == (resetField.contains("1785684540")
            ? Date(timeIntervalSince1970: 1_785_684_540) : nil))
        #expect(SideNotchSummaryMeterPolicy.select(from: meters)?.id == session.id)
    }

    @Test
    func stillRejectsMalformedFiveHourResetDate() throws {
        let usage = try CodexUsageParser.parse(
            Data(
                """
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 0,
                      "limit_window_seconds": 18000,
                      "reset_at": "not-a-date"
                    },
                    "secondary_window": {
                      "used_percent": 25,
                      "limit_window_seconds": 604800
                    }
                  }
                }
                """.utf8
            ),
            now: fixedNow
        )
        #expect(usage.groups.flatMap(\.meters).map(\.id) == ["codex.week"])
    }

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
        #expect(usage.groups.flatMap(\.meters).map(\.title) == ["주간", "크레딧"])
        #expect(usage.groups.flatMap(\.meters).map(\.metric) == [
            .quotaRemaining(percent: 60),
            .credit(balance: 0, unit: .credits)
        ])
        #expect(usage.groups.first?.creditText == nil)
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

        #expect(usage.groups.first?.meters.map(\.metric) == [
            .quotaRemaining(percent: 18),
            .credit(balance: 0, unit: .credits),
            .count(value: 1, unit: .tickets)
        ])
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
        #expect(usage.groups.map(\.title) == ["Gemini Models", "Claude and GPT models", nil])
        #expect(usage.groups.flatMap(\.meters).map(\.metric) == [
            .quotaRemaining(percent: 100), .quotaRemaining(percent: 73),
            .quotaRemaining(percent: 100), .quotaRemaining(percent: 83),
            .credit(balance: 500, unit: .credits),
            .credit(balance: 100, unit: .credits)
        ])
        #expect(usage.groups.last?.creditText == nil)
        #expect(usage.groups.flatMap(\.meters).first?.resetsAt?.timeIntervalSince1970 == 1_785_689_280)
        #expect(usage.updatedAt == fixedNow)
    }
}
