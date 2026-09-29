import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

private let systemLanguagesKey = "AppleLanguages"

@Suite
struct LocalizationTests {
    @Test
    func freshInstallFollowsSystemLanguageWithoutPersistingIt() {
        let suiteName = "LocalizationTests.systemDefault.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            ["en-KR", "ko-KR"],
            forKey: systemLanguagesKey
        )
        let store = AppLanguageStore(defaults: defaults)

        #expect(store.load() == .english)
        #expect(defaults.string(forKey: AppLanguageStore.key) == nil)
    }

    @Test
    func legacyKoreanDefaultMigratesToSystemLanguage() {
        let suiteName = "LocalizationTests.legacyKorean.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            AppLanguage.korean.rawValue,
            forKey: AppLanguageStore.key
        )
        defaults.set(
            ["en-KR", "ko-KR"],
            forKey: systemLanguagesKey
        )
        let store = AppLanguageStore(defaults: defaults)

        #expect(store.load() == .english)
        #expect(defaults.string(forKey: AppLanguageStore.key) == nil)
    }

    @Test
    func legacyEnglishPreferenceRemainsExplicit() {
        let suiteName = "LocalizationTests.legacyEnglish.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            AppLanguage.english.rawValue,
            forKey: AppLanguageStore.key
        )
        defaults.set(["ko-KR"], forKey: systemLanguagesKey)
        let store = AppLanguageStore(defaults: defaults)

        #expect(store.load() == .english)
    }

    @Test
    func malformedPreferenceFallsBackToSystemLanguage() {
        let suiteName = "LocalizationTests.malformed.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set("unsupported", forKey: AppLanguageStore.key)
        defaults.set(["en-KR"], forKey: systemLanguagesKey)
        let store = AppLanguageStore(defaults: defaults)

        #expect(store.load() == .english)
        #expect(defaults.string(forKey: AppLanguageStore.key) == nil)
    }

    @Test
    func systemLanguageUsesFirstSupportedPreference() {
        let suiteName = "LocalizationTests.supportedSystem.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            ["ja-JP", "ko-KR"],
            forKey: systemLanguagesKey
        )

        #expect(
            AppLanguageStore(defaults: defaults).load() == .korean
        )
    }

    @Test
    func languageStorePersistsEnglishAcrossInstances() {
        let suiteName = "LocalizationTests.persistence.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(["ko-KR"], forKey: systemLanguagesKey)
        AppLanguageStore(defaults: defaults).save(.english)

        #expect(
            AppLanguageStore(defaults: defaults).load() == .english
        )
    }

    @Test
    func catalogResolvesEveryKeyInKoreanAndEnglish() {
        for language in AppLanguage.allCases {
            let strings = AppStrings(language: language)

            for key in AppStringKey.allCases {
                let resolved = strings.text(key)
                #expect(!resolved.isEmpty)
                #expect(resolved != key.rawValue)
            }
        }
    }

    @Test
    @MainActor
    func webDashboardPortIdentifiersNeverUseLocaleGrouping() {
        for language in AppLanguage.allCases {
            let localization = LocalizationContext(language: language)
            let local = localization.format(
                .webDashboardEndpointDetails,
                "17827"
            )
            let tailscale = localization.format(
                .webDashboardTailscaleEndpointDetails,
                "8443",
                "17827"
            )

            #expect(local.contains("17827"))
            #expect(tailscale.contains("8443"))
            #expect(tailscale.contains("17827"))
        }
    }

    @Test
    @MainActor
    func destructiveConfirmationTitlesNameTheirTarget() {
        for language in AppLanguage.allCases {
            let localization = LocalizationContext(language: language)

            #expect(
                localization.format(.removeAccount, "QA Team")
                    .contains("QA Team")
            )
            #expect(
                localization.format(.removeKeyTitle, "OpenRouter")
                    .contains("OpenRouter")
            )
        }
    }

    @Test
    @MainActor
    func switchingLanguageImmediatelyChangesExistingSemanticText() {
        let suiteName = "LocalizationTests.switching.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["ko-KR"], forKey: systemLanguagesKey)
        let controller = LocalizationController(
            store: AppLanguageStore(defaults: defaults)
        )
        let existingText = LocalizedText.key(.usageWeek)

        let korean = controller.resolve(existingText)
        controller.select(.english)
        let english = controller.resolve(existingText)

        #expect(korean == "주간")
        #expect(english == "Weekly")
        #expect(korean != english)
    }

    @Test
    @MainActor
    func formattedFeedbackRelocalizesAfterLanguageSwitch() {
        let suiteName = "LocalizationTests.feedback.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["ko-KR"], forKey: systemLanguagesKey)
        let controller = LocalizationController(
            store: AppLanguageStore(defaults: defaults)
        )
        let feedback = LocalizedText.formatted(
            .disconnectedProvider,
            "Copilot"
        )

        #expect(
            controller.resolve(feedback)
                == "Copilot 연결을 OmoUsage에서 해제했습니다. 외부 로그인은 유지됩니다."
        )

        controller.select(.english)

        #expect(
            controller.resolve(feedback)
                == "Disconnected Copilot from OmoUsage. The external login remains active."
        )
    }

    @Test
    func timestampPresenterUsesSelectedLanguage() {
        let updatedAt = Date(timeIntervalSince1970: 1_767_225_600)
        let now = updatedAt.addingTimeInterval(60)

        #expect(
            RefreshTimestampPresenter.providerText(
                updatedAt: updatedAt,
                now: now,
                language: .korean
            ).hasSuffix("기준")
        )
        #expect(
            RefreshTimestampPresenter.providerText(
                updatedAt: updatedAt,
                now: now,
                language: .english
            ).hasPrefix("As of ")
        )
    }

    @Test
    @MainActor
    func providerGeneratedIntervalsAndTitlesStayFullyEnglish() {
        let localization = LocalizationContext(language: .english)

        #expect(
            localization.providerText("1일 후 리셋")
                == "Resets in 1 day"
        )
        #expect(
            localization.providerText("1일 후 만료")
                == "Expires in 1 day"
        )
        #expect(
            localization.providerText("3일 후 리셋")
                == "Resets in 3 days"
        )
    }

    @Test
    @MainActor
    func resetDescriptionKeepsRemainingHoursAndLocalResetTime() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        // Saturday 2026-09-26 18:59:04 KST.
        let now = Date(timeIntervalSince1970: 1_790_416_744)
        let english = LocalizationContext(language: .english)
        let korean = LocalizationContext(language: .korean)
        func text(
            _ localization: LocalizationContext,
            after seconds: TimeInterval
        ) -> String {
            localization.resetDescription(
                until: now.addingTimeInterval(seconds),
                now: now,
                timeZone: seoul
            )
            .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let sundayEvening: TimeInterval = 1_790_514_796 - 1_790_416_744

        #expect(
            text(english, after: sundayEvening)
                == "Resets in 1 day 3 hr · Sun 10:13 PM"
        )
        #expect(
            text(korean, after: sundayEvening)
                == "1일 3시간 후 리셋 · (일) 오후 10:13"
        )
        #expect(
            text(english, after: 3 * 3_600 + 14 * 60)
                == "Resets in 3 hr 14 min · 10:13 PM"
        )
        #expect(
            text(english, after: 10 * 3_600)
                == "Resets in 10 hr 0 min · Sun 4:59 AM"
        )
        #expect(
            text(english, after: 2 * 86_400 + 600)
                == "Resets in 2 days · Mon 7:09 PM"
        )
        #expect(
            text(korean, after: 2 * 86_400 + 5 * 3_600)
                == "2일 5시간 후 리셋 · (월) 오후 11:59"
        )
        #expect(text(english, after: 20 * 60) == "Resets in 20 min")
    }

    @Test
    @MainActor
    func providerGeneratedHoursAndTitlesStayFullyEnglish() {
        let localization = LocalizationContext(language: .english)

        #expect(
            localization.providerText("3시간 후 리셋")
                == "Resets in 3 hr"
        )
        #expect(
            localization.providerText("3시간 32분 후 리셋")
                == "Resets in 3 hr 32 min"
        )
        #expect(
            localization.providerText("Sonnet 주간")
                == "Sonnet weekly"
        )
        #expect(
            localization.providerText("1분 전 기준")
                == "As of 1 min ago"
        )
        #expect(
            localization.providerText("크레딧 0    풀 리셋 티켓 1")
                == "Credits 0    Full reset tickets 1"
        )
    }

    @Test
    func webSnapshotUsesSelectedLanguageWithoutMutatingStoredUsage() {
        let snapshot = DashboardSnapshot(
            providers: [
                ProviderUsage(
                    provider: .codex,
                    accountID: AccountID(
                        rawValue:
                            "11111111-1111-4111-8111-111111111111"
                    )!,
                    accountLabel: "QA Team",
                    planName: "Plus",
                    groups: [
                        UsageGroup(
                            id: "limits",
                            title: "모델별 주간",
                            meters: [
                                UsageMeter(
                                    id: "session",
                                    title: "세션 (5시간)",
                                    period: .session,
                                    percentRemaining: 72,
                                    resetText: "3시간 32분 후 리셋"
                                )
                            ],
                            creditText:
                                "크레딧 0    풀 리셋 티켓 1"
                        )
                    ],
                    availability: .available,
                    updatedAt: nil
                )
            ],
            refreshedAt: Date(timeIntervalSince1970: 1_786_867_200)
        )

        let localized = snapshot.localized(
            using: LocalizationContext(language: .english)
        )

        #expect(
            localized.providers[0].accountProviderID
                == snapshot.providers[0].accountProviderID
        )
        #expect(localized.providers[0].accountLabel == "QA Team")
        #expect(localized.providers[0].groups[0].title == "Weekly by model")
        #expect(
            localized.providers[0].groups[0].meters[0].title
                == "Session (5 hours)"
        )
        #expect(
            localized.providers[0].groups[0].meters[0].resetText
                == "Resets in 3 hr 32 min"
        )
        #expect(
            localized.providers[0].groups[0].creditText
                == "Credits 0    Full reset tickets 1"
        )
        #expect(
            snapshot.providers[0].groups[0].meters[0].title
                == "세션 (5시간)"
        )
    }
}
