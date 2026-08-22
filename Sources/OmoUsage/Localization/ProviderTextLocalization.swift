import Foundation

extension LocalizationResolving {
    func providerText(_ value: String) -> String {
        ProviderTextLocalization.text(value, language: language)
    }

    func availabilityText(
        _ availability: ProviderAvailability
    ) -> String? {
        switch availability {
        case .available:
            nil
        case .authenticationRequired:
            text(.authenticationRequired)
        case .unavailable:
            text(.unavailable)
        case .failed:
            text(.refreshFailed)
        }
    }

    #if os(macOS)
    func providerSetupError(
        _ error: ProviderSetupError
    ) -> String {
        switch error {
        case .unavailable(let provider):
            return format(.unableToFindConnection, provider.displayName)
        case .unableToLaunch(let target):
            return format(.unableToLaunch, target)
        case .unableToOpen:
            return text(.unableToOpenOfficialAuthentication)
        case .requiredExecutableMissing(let executables):
            let separator = language == .english ? " or " : " 또는 "
            let targets = executables.joined(separator: separator)
            if language == .english {
                return "Install \(targets) to continue."
            }
            return "\(targets) 설치가 필요합니다."
        }
    }

    func launchStatus(
        _ status: LaunchAtLoginServiceStatus
    ) -> String {
        switch status {
        case .notRegistered:
            text(.launchDisabled)
        case .enabled:
            text(.launchEnabled)
        case .requiresApproval:
            text(.launchApproval)
        case .notFound:
            text(.launchNotFound)
        }
    }
    #endif
}

extension DashboardSnapshot {
    func localized(
        using localization: LocalizationContext
    ) -> DashboardSnapshot {
        let localize = {
            ProviderTextLocalization.text(
                $0,
                language: localization.language
            )
        }
        return DashboardSnapshot(
            providers: providers.map { provider in
                ProviderUsage(
                    provider: provider.provider,
                    planName: localize(provider.planName),
                    groups: provider.groups.map { group in
                        UsageGroup(
                            id: group.id,
                            title: group.title.map(localize),
                            meters: group.meters.map { meter in
                                UsageMeter(
                                    id: meter.id,
                                    title: localize(meter.title),
                                    period: meter.period,
                                    percentRemaining: meter.percentRemaining,
                                    resetsAt: meter.resetsAt,
                                    resetText: meter.resetText.map(localize),
                                    showsMenuBarBadge:
                                        meter.showsMenuBarBadge
                                )
                            },
                            creditText: group.creditText.map(localize)
                        )
                    },
                    availability: provider.availability,
                    updatedAt: provider.updatedAt
                )
            },
            refreshedAt: refreshedAt
        )
    }
}

enum ProviderTextLocalization {
    static func text(
        _ value: String,
        language: AppLanguage
    ) -> String {
        guard language == .english else { return value }
        if let exact = english[value] {
            return exact
        }
        if
            value.hasSuffix("분 후 리셋"),
            let minutes = Int(value.dropLast("분 후 리셋".count))
        {
            return format(.resetMinutes, language: language, minutes)
        }
        if value.hasSuffix("분 후 리셋") {
            let interval = value.dropLast("분 후 리셋".count)
                .components(separatedBy: "시간 ")
            if
                interval.count == 2,
                let hours = Int(interval[0]),
                let minutes = Int(interval[1])
            {
                return format(
                    .resetHoursMinutes,
                    language: language,
                    hours,
                    minutes
                )
            }
        }
        if
            value.hasSuffix("시간 후 리셋"),
            let hours = Int(value.dropLast("시간 후 리셋".count))
        {
            return format(.resetHours, language: language, hours)
        }
        if
            value.hasSuffix("일 후 리셋"),
            let days = Int(value.dropLast("일 후 리셋".count))
        {
            return format(.resetDays, language: language, days)
        }
        if
            value.hasSuffix("분 전 기준"),
            let minutes = Int(value.dropLast("분 전 기준".count))
        {
            return format(
                .asOfMinutesAgo,
                language: language,
                minutes
            )
        }
        if value.hasSuffix(" 주간") {
            let name = String(value.dropLast(" 주간".count))
            return format(.usageNamedWeek, language: language, name)
        }
        if value.hasSuffix(" 기준") {
            return format(
                .asOf,
                language: language,
                String(value.dropLast(" 기준".count))
            )
        }
        return value
            .replacingOccurrences(
                of: "풀 리셋 티켓",
                with: "Full reset tickets"
            )
            .replacingOccurrences(of: "최근 30일 ", with: "Last 30 days ")
            .replacingOccurrences(of: "크레딧", with: "Credits")
            .replacingOccurrences(of: "프롬프트", with: "Prompt")
            .replacingOccurrences(of: "플로우", with: "Flow")
            .replacingOccurrences(of: "추가 잔액", with: "Extra balance")
            .replacingOccurrences(of: "추가 사용량", with: "Extra usage")
            .replacingOccurrences(of: " 한도", with: " cap")
            .replacingOccurrences(of: " 사용", with: " used")
            .replacingOccurrences(of: "잔액", with: "Balance")
            .replacingOccurrences(of: "오늘", with: "Today")
    }

    private static func format(
        _ key: AppStringKey,
        language: AppLanguage,
        _ arguments: any CVarArg...
    ) -> String {
        String(
            format: AppStrings(language: language).text(key),
            locale: language.locale,
            arguments: arguments
        )
    }

    private static let english: [String: String] = [
        "세션": "Session",
        "세션 (5시간)": "Session (5 hours)",
        "주간": "Weekly",
        "월간": "Monthly",
        "일간": "Daily",
        "일일": "Daily",
        "추가 사용량": "Extra usage",
        "검색": "Search",
        "웹 검색": "Web search",
        "토큰 한도": "Token quota",
        "모델별 주간": "Weekly by model",
        "총 사용량": "Total usage",
        "Auto 사용량": "Auto usage",
        "API 사용량": "API usage",
        "추가 잔액": "Extra balance",
        "키 한도": "Key limit",
        "자동": "Automatic",
        "Claude Code OAuth 로그인": "Sign in with Claude Code OAuth",
        "codex 실행 후 ChatGPT로 로그인": "Run Codex and sign in with ChatGPT",
        "Cursor 앱의 Account에서 로그인": "Sign in from Account in the Cursor app",
        "Antigravity 앱 또는 agy CLI에서 로그인": "Sign in with the Antigravity app or agy CLI",
        "Copilot CLI 또는 GitHub CLI에서 로그인": "Sign in with Copilot CLI or GitHub CLI",
        "devin auth login 실행": "Run devin auth login",
        "grok login 실행": "Run grok login",
        "OpenCode Go 연결 또는 로컬 사용": "Connect OpenCode Go or use local usage",
        "OpenRouter API 키 입력": "Enter an OpenRouter API key",
        "Z.ai API 키 입력": "Enter a Z.ai API key",
        "Claude Code OAuth 로그인을 완료하세요.": "Complete Claude Code OAuth sign-in.",
        "Claude Desktop 로그인만으로는 실시간 리셋 시각을 읽을 수 없습니다.": "Claude Desktop sign-in alone cannot provide live reset times.",
        "인증이 끝나면 OmoUsage가 구독 사용량을 바로 새로고칩니다.": "OmoUsage refreshes subscription usage as soon as authentication completes.",
        "Codex CLI를 실행해 ChatGPT 계정으로 로그인하세요.": "Run Codex CLI and sign in with your ChatGPT account.",
        "OmoUsage는 Codex가 저장한 로컬 인증값을 자동으로 찾습니다.": "OmoUsage automatically finds the credential saved by Codex.",
        "Cursor 앱의 Account에서 로그인하거나 agent login을 실행하세요.": "Sign in under Account in Cursor, or run agent login.",
        "OmoUsage는 Cursor의 로컬 데이터베이스에서 인증값을 찾습니다.": "OmoUsage finds the credential in Cursor's local database.",
        "Antigravity 앱 또는 agy CLI에서 Google 계정으로 로그인하세요.": "Sign in to Antigravity with your Google account in the app or agy CLI.",
        "OmoUsage는 Antigravity가 Keychain에 저장한 인증값을 읽습니다.": "OmoUsage reads the credential Antigravity saved in Keychain.",
        "Copilot CLI가 있으면 브라우저 OAuth 로그인을 엽니다.": "If Copilot CLI is installed, it opens browser OAuth sign-in.",
        "없으면 설치된 GitHub CLI 인증을 엽니다.": "Otherwise, the installed GitHub CLI authentication flow opens.",
        "또는 사용하는 편집기에서 GitHub Copilot에 로그인하세요.": "You can also sign in to GitHub Copilot from your editor.",
        "연결 시작을 눌러 Devin CLI 인증을 진행하세요.": "Choose Connect to authenticate with Devin CLI.",
        "OmoUsage는 Devin이 저장한 로컬 인증값을 자동으로 찾습니다.": "OmoUsage automatically finds Devin's saved credential.",
        "연결 시작을 눌러 Grok CLI 인증을 진행하세요.": "Choose Connect to authenticate with Grok CLI.",
        "OmoUsage는 Grok의 로컬 auth.json을 자동으로 찾습니다.": "OmoUsage automatically finds Grok's local auth.json.",
        "연결 시작을 누르면 OpenCode의 공식 인증 흐름을 엽니다.": "Choose Connect to open OpenCode's official authentication flow.",
        "OmoUsage는 OpenCode의 auth.json과 로컬 사용 기록을 자동으로 찾습니다.": "OmoUsage automatically finds OpenCode auth.json and local usage.",
        "OpenCode가 없으면 CLI 설치가 필요하다고 안내합니다.": "If OpenCode is unavailable, OmoUsage explains that the CLI must be installed.",
        "OpenRouter의 Keys 페이지에서 API 키를 생성하세요.": "Create an API key on OpenRouter's Keys page.",
        "생성한 키를 API 키 입력란에 붙여 넣고 저장을 누르세요.": "Paste the key into the API Key field and choose Save.",
        "개인 플랜은 Z.ai API 키 관리 페이지에서 키를 생성하세요.": "For an individual plan, create a key on the Z.ai API key management page.",
        "팀 플랜은 https://z.ai/manage-apikey/coding-plan/team/my-plan 에서 전용 키를 생성하세요.": "For a team plan, create its dedicated key at https://z.ai/manage-apikey/coding-plan/team/my-plan."
    ]
}
