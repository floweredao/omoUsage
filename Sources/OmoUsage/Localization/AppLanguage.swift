import Foundation
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case korean
    case english

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .korean:
            Locale(identifier: "ko_KR")
        case .english:
            Locale(identifier: "en_US")
        }
    }

    static func systemDefault(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        for identifier in preferredLanguages {
            let languageCode = Locale(identifier: identifier)
                .language
                .languageCode?
                .identifier
            switch languageCode {
            case "ko":
                return .korean
            case "en":
                return .english
            default:
                continue
            }
        }
        return .english
    }
}

struct AppLanguageStore {
    static let key = "OmoUsage.appLanguage"
    private static let explicitSelectionKey =
        "OmoUsage.appLanguageExplicitlySelected"

    private let defaults: UserDefaults
    private let systemLanguage: () -> AppLanguage

    init(
        defaults: UserDefaults,
        systemLanguage: (() -> AppLanguage)? = nil
    ) {
        self.defaults = defaults
        self.systemLanguage = systemLanguage ?? {
            AppLanguage.systemDefault(
                preferredLanguages: defaults.stringArray(
                    forKey: "AppleLanguages"
                ) ?? Locale.preferredLanguages
            )
        }
    }

    func load() -> AppLanguage {
        let language = defaults
            .string(forKey: Self.key)
            .flatMap(AppLanguage.init(rawValue:))

        if defaults.bool(forKey: Self.explicitSelectionKey),
           let language {
            return language
        }

        if language == .english {
            defaults.set(true, forKey: Self.explicitSelectionKey)
            return .english
        }

        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.explicitSelectionKey)
        return systemLanguage()
    }

    func save(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Self.key)
        defaults.set(true, forKey: Self.explicitSelectionKey)
    }
}

enum LocalizedText: Equatable, Sendable {
    case key(AppStringKey)
    case formatted(AppStringKey, String)
    case raw(String)
}

@MainActor
protocol LocalizationResolving {
    var language: AppLanguage { get }
}

struct LocalizationContext: Equatable, Sendable {
    let language: AppLanguage
}

private struct LocalizationContextKey: EnvironmentKey {
    static let defaultValue = LocalizationContext(language: .korean)
}

extension EnvironmentValues {
    var appLocalization: LocalizationContext {
        get { self[LocalizationContextKey.self] }
        set { self[LocalizationContextKey.self] = newValue }
    }
}

@Observable
@MainActor
final class LocalizationController: LocalizationResolving {
    private let store: AppLanguageStore
    private(set) var language: AppLanguage

    init(store: AppLanguageStore) {
        self.store = store
        language = store.load()
    }

    var locale: Locale {
        language.locale
    }

    var context: LocalizationContext {
        LocalizationContext(language: language)
    }

    func select(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        store.save(language)
    }

    func text(_ key: AppStringKey) -> String {
        context.text(key)
    }

    func resolve(_ text: LocalizedText) -> String {
        switch text {
        case .key(let key):
            self.text(key)
        case .formatted(let key, let argument):
            format(key, argument)
        case .raw(let value):
            context.providerText(value)
        }
    }

    func format(
        _ key: AppStringKey,
        _ arguments: any CVarArg...
    ) -> String {
        context.format(key, arguments: arguments)
    }
}

extension LocalizationContext: LocalizationResolving {}

extension LocalizationResolving {
    func text(_ key: AppStringKey) -> String {
        AppStrings(language: language).text(key)
    }

    func format(
        _ key: AppStringKey,
        _ arguments: any CVarArg...
    ) -> String {
        format(key, arguments: arguments)
    }

    func format(
        _ key: AppStringKey,
        arguments: [any CVarArg]
    ) -> String {
        String(
            format: text(key),
            locale: language.locale,
            arguments: arguments
        )
    }
}
