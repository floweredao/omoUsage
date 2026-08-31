import Foundation
import Observation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case korean
    case english

    public var id: String { rawValue }

    public var locale: Locale {
        switch self {
        case .korean:
            Locale(identifier: "ko_KR")
        case .english:
            Locale(identifier: "en_US")
        }
    }

    public static func systemDefault(
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

public struct AppLanguageStore {
    public static let key = "OmoUsage.appLanguage"
    private static let explicitSelectionKey =
        "OmoUsage.appLanguageExplicitlySelected"

    private let defaults: UserDefaults
    private let systemLanguage: () -> AppLanguage

    public init(
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

    public func load() -> AppLanguage {
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

    public func save(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: Self.key)
        defaults.set(true, forKey: Self.explicitSelectionKey)
    }
}

public enum LocalizedText: Equatable, Sendable {
    case key(AppStringKey)
    case formatted(AppStringKey, String)
    case raw(String)
}

@MainActor
public protocol LocalizationResolving {
    var language: AppLanguage { get }
}

public struct LocalizationContext: Equatable, Sendable {
    public let language: AppLanguage

    public init(language: AppLanguage) {
        self.language = language
    }
}

private struct LocalizationContextKey: EnvironmentKey {
    static let defaultValue = LocalizationContext(language: .korean)
}

extension EnvironmentValues {
    public var appLocalization: LocalizationContext {
        get { self[LocalizationContextKey.self] }
        set { self[LocalizationContextKey.self] = newValue }
    }
}

@Observable
@MainActor
public final class LocalizationController: LocalizationResolving {
    private let store: AppLanguageStore
    public private(set) var language: AppLanguage

    public init(store: AppLanguageStore) {
        self.store = store
        language = store.load()
    }

    public var locale: Locale {
        language.locale
    }

    public var context: LocalizationContext {
        LocalizationContext(language: language)
    }

    public func select(_ language: AppLanguage) {
        guard self.language != language else { return }
        self.language = language
        store.save(language)
    }

    public func text(_ key: AppStringKey) -> String {
        context.text(key)
    }

    public func resolve(_ text: LocalizedText) -> String {
        switch text {
        case .key(let key):
            self.text(key)
        case .formatted(let key, let argument):
            format(key, argument)
        case .raw(let value):
            context.providerText(value)
        }
    }

    public func format(
        _ key: AppStringKey,
        _ arguments: any CVarArg...
    ) -> String {
        context.format(key, arguments: arguments)
    }
}

extension LocalizationContext: LocalizationResolving {}

extension LocalizationResolving {
    public func text(_ key: AppStringKey) -> String {
        AppStrings(language: language).text(key)
    }

    public func format(
        _ key: AppStringKey,
        _ arguments: any CVarArg...
    ) -> String {
        format(key, arguments: arguments)
    }

    public func format(
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
