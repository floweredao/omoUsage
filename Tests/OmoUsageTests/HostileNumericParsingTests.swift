import Foundation
import Testing
@testable import OmoUsage

private let hostileNumericNow = Date(timeIntervalSince1970: 1_785_675_000)

@Suite
struct HostileNumericParsingTests {
    @Test
    func rejectsNonFiniteNumbersAndOverflowingStrings() {
        let strings = ["NaN", "Infinity", "-Infinity", "1e309"]
        for value in strings {
            #expect(UsageJSON.number(value) == nil)
        }

        let numbers = [
            NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity),
            NSNumber(value: -Double.infinity)
        ]
        for value in numbers {
            #expect(UsageJSON.number(value) == nil)
        }

        #expect(UsageJSON.number(true) == nil)
        #expect(UsageJSON.number(false) == nil)
    }

    @Test
    func rejectsUnsafeNumericDates() {
        #expect(UsageJSON.date(Double.greatestFiniteMagnitude) == nil)
        #expect(UsageJSON.date(-Double.greatestFiniteMagnitude) == nil)
        #expect(UsageJSON.date("1e309") == nil)

        let object: [String: Any] = [
            "positive": Double.greatestFiniteMagnitude,
            "negative": -Double.greatestFiniteMagnitude
        ]
        #expect(ProviderPayload.date(object, paths: [["positive"]]) == nil)
        #expect(ProviderPayload.date(object, paths: [["negative"]]) == nil)
    }

    @Test
    func rejectsInvalidPercentageInputsWithoutIntegerConversion() {
        let invalidUsedPercents = [
            -1,
            101,
            Double.greatestFiniteMagnitude,
            Double.nan,
            Double.infinity,
            -Double.infinity
        ]
        for value in invalidUsedPercents {
            #expect(ProviderPayload.remainingPercent(usedPercent: value) == nil)
        }

        #expect(ProviderPayload.remainingPercent(used: 1, limit: 0) == nil)
        #expect(ProviderPayload.remainingPercent(used: 1, limit: -1) == nil)
        #expect(ProviderPayload.remainingPercent(used: -1, limit: 10) == nil)
        #expect(ProviderPayload.remainingPercent(used: 11, limit: 10) == nil)
        #expect(
            ProviderPayload.remainingPercent(
                used: Double.greatestFiniteMagnitude,
                limit: 1
            ) == nil
        )
    }

    @Test
    func preservesValidPercentageBoundariesAndUsedLimitValues() {
        #expect(ProviderPayload.remainingPercent(usedPercent: 0) == 100)
        #expect(ProviderPayload.remainingPercent(usedPercent: 100) == 0)
        #expect(ProviderPayload.remainingPercent(used: 0, limit: 10) == 100)
        #expect(ProviderPayload.remainingPercent(used: 10, limit: 10) == 0)
        #expect(ProviderPayload.remainingPercent(used: 4, limit: 10) == 60)
    }

    @Test
    func modelConstructionDoesNotSilentlyClampCorruptPercentages() {
        let belowRange = UsageMeter(
            id: "invalid-low",
            title: "Invalid",
            period: .session,
            percentRemaining: -1
        )
        let aboveRange = UsageMeter(
            id: "invalid-high",
            title: "Invalid",
            period: .session,
            percentRemaining: 101
        )

        #expect(belowRange.percentRemaining == -1)
        #expect(aboveRange.percentRemaining == 101)
    }

    @Test(arguments: ["-1", "101", "NaN", "Infinity", "-Infinity", "1e309"])
    func claudeRejectsHostileUtilizationWithTypedFailure(_ value: String) {
        #expect(throws: UsageParsingError.invalidPayload) {
            try ClaudeUsageParser.parse(
                Data(
                    """
                    {"five_hour":{"utilization":"\(value)"}}
                    """.utf8
                ),
                planName: "Pro",
                now: hostileNumericNow
            )
        }
    }

    @Test
    func claudeRejectsInvalidUsedLimitPairs() {
        let pairs = [(-1, 10), (11, 10), (1, 0), (1, -1)]
        for (used, limit) in pairs {
            #expect(throws: UsageParsingError.invalidPayload) {
                try ClaudeUsageParser.parse(
                    Data(
                        """
                        {
                          "extra_usage": {
                            "is_enabled": true,
                            "used_credits": \(used),
                            "monthly_limit": \(limit)
                          }
                        }
                        """.utf8
                    ),
                    planName: "Pro",
                    now: hostileNumericNow
                )
            }
        }
    }

    @Test
    func claudeRejectsUnsafeResetDateWithNoMeter() {
        #expect(throws: UsageParsingError.invalidPayload) {
            try ClaudeUsageParser.parse(
                Data(
                    """
                    {
                      "five_hour": {
                        "utilization": 50,
                        "resets_at": 1e308
                      }
                    }
                    """.utf8
                ),
                planName: "Pro",
                now: hostileNumericNow
            )
        }
    }

    @Test
    func codexRejectsOverflowingPercentAndUnsafeDate() {
        let payloads = [
            """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 1e308,
                  "limit_window_seconds": 3600
                }
              }
            }
            """,
            """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 50,
                  "limit_window_seconds": 3600,
                  "reset_at": 1e308
                }
              }
            }
            """
        ]
        for payload in payloads {
            #expect(throws: UsageParsingError.invalidPayload) {
                try CodexUsageParser.parse(
                    Data(payload.utf8),
                    now: hostileNumericNow
                )
            }
        }
    }

    @Test(arguments: ["-1", "1.01", "1e308"])
    func antigravityRejectsOutOfRangeOrOverflowingFractions(
        _ fraction: String
    ) {
        #expect(throws: UsageParsingError.invalidPayload) {
            try AntigravityUsageParser.parse(
                Data(
                    """
                    {
                      "groups": [{
                        "buckets": [{
                          "bucketId": "gemini-5h",
                          "remainingFraction": \(fraction)
                        }]
                      }]
                    }
                    """.utf8
                ),
                now: hostileNumericNow
            )
        }
    }

    @Test(arguments: ["0", "100"])
    func claudePreservesUtilizationBoundaries(_ value: String) throws {
        let usage = try ClaudeUsageParser.parse(
            Data(
                """
                {"five_hour":{"utilization":\(value)}}
                """.utf8
            ),
            planName: "Pro",
            now: hostileNumericNow
        )

        #expect(usage.groups.flatMap(\.meters).count == 1)
        #expect(
            usage.groups.flatMap(\.meters).first?.percentRemaining
                == (value == "0" ? 100 : 0)
        )
    }
}
