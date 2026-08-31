import OmoUsageCore
import SwiftUI

enum RefreshTimestampPresenter {
    static func footerText(
        lastRefreshAttemptAt: Date,
        now: Date,
        language: AppLanguage = .korean,
        timeZone: TimeZone = .current
    ) -> String {
        if age(of: lastRefreshAttemptAt, at: now) < 10 {
            return AppStrings(language: language).text(.justNow)
        }
        return clockText(lastRefreshAttemptAt, timeZone: timeZone)
    }

    static func footerText(
        refreshedAt: Date,
        now: Date,
        language: AppLanguage = .korean,
        timeZone: TimeZone = .current
    ) -> String {
        footerText(
            lastRefreshAttemptAt: refreshedAt,
            now: now,
            language: language,
            timeZone: timeZone
        )
    }

    static func providerText(
        lastSuccessfulAt: Date,
        now: Date,
        language: AppLanguage = .korean,
        timeZone: TimeZone = .current
    ) -> String {
        let strings = AppStrings(language: language)
        if age(of: lastSuccessfulAt, at: now) < 10 {
            return strings.text(.asOfNow)
        }
        return String(
            format: strings.text(.asOf),
            locale: language.locale,
            clockText(lastSuccessfulAt, timeZone: timeZone)
        )
    }

    static func providerText(
        updatedAt: Date,
        now: Date,
        language: AppLanguage = .korean,
        timeZone: TimeZone = .current
    ) -> String {
        providerText(
            lastSuccessfulAt: updatedAt,
            now: now,
            language: language,
            timeZone: timeZone
        )
    }

    private static func age(
        of updatedAt: Date,
        at now: Date
    ) -> TimeInterval {
        max(0, now.timeIntervalSince(updatedAt))
    }

    private static func clockText(
        _ date: Date,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct RefreshTimestampView: View {
    enum Style {
        case footer
        case provider
    }

    let updatedAt: Date
    let style: Style
    @Environment(\.appLocalization)
    private var localization

    @State
    private var now = Date()

    var body: some View {
        Text(text)
            .task(id: updatedAt) {
                let current = Date()
                now = current
                let delay = updatedAt
                    .addingTimeInterval(10)
                    .timeIntervalSince(current)
                guard delay > 0 else { return }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                now = Date()
            }
    }

    private var text: String {
        switch style {
        case .footer:
            let timestamp = RefreshTimestampPresenter.footerText(
                    lastRefreshAttemptAt: updatedAt,
                    now: now,
                    language: localization.language
                )
            return localization.format(.lastRefreshAttempt, timestamp)
        case .provider:
            return RefreshTimestampPresenter.providerText(
                lastSuccessfulAt: updatedAt,
                now: now,
                language: localization.language
            )
        }
    }
}
