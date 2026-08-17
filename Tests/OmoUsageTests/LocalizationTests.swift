import Foundation
import Testing
@testable import OmoUsage

@Suite
struct LocalizationTests {
    @Test
    func languageStoreDefaultsToKoreanAndRepairsMalformedValue() {
        let suiteName = "LocalizationTests.default.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AppLanguageStore(defaults: defaults)

        #expect(store.load() == .korean)

        defaults.set("unsupported", forKey: AppLanguageStore.key)

        #expect(store.load() == .korean)
        #expect(
            defaults.string(forKey: AppLanguageStore.key)
                == AppLanguage.korean.rawValue
        )
    }

    @Test
    func languageStorePersistsEnglishAcrossInstances() {
        let suiteName = "LocalizationTests.persistence.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

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
    func switchingLanguageImmediatelyChangesExistingSemanticText() {
        let suiteName = "LocalizationTests.switching.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
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
    }
}
