enum AppStringKey: String, CaseIterable, Sendable {
    case aiUsage
    case settingsTitle
    case settingsSubtitle
    case language
    case korean
    case english
    case providerAuthentication
    case reconnect
    case launchAtLogin
    case launchDisabled
    case launchEnabled
    case launchApproval
    case launchNotFound
    case launchChangeFailed
    case openLoginItems
    case connected
    case checkFailed
    case notConnected
    case checking
    case moveUp
    case moveDown
    case setupHelp
    case startConnection
    case disconnect
    case reconnectProvider
    case codexUsageTier
    case apiKey
    case save
    case delete
    case openOfficialGuide
    case cannotStartConnection
    case confirm
    case openedConnection
    case openedOfficialAuthentication
    case disconnectedProvider
    case reconnectedProvider
    case savedKey
    case removedKey
    case saveKeyFailed
    case removeKeyFailed
    case refresh
    case settings
    case quit
    case inProgress
    case authenticationRequired
    case unavailable
    case refreshFailed
    case lastRefresh
    case justNow
    case asOfNow
    case asOf
    case remaining
    case noResetInfo
    case resetMinutes
    case resetHours
    case resetHoursMinutes
    case resetDays
    case usageSession
    case usageWeek
    case usageExtra
    case usageDay
    case usageMonth
    case usageNamedWeek
    case asOfMinutesAgo
    case providerConnectionMethod
    case unableToFindConnection
    case unableToLaunch
    case unableToOpenOfficialAuthentication
    case mobileNoDataTitle
    case mobileNoDataDescription
    case mobileSyncFailed
    case retry
    case syncedThroughICloud
}

struct AppStrings: Sendable {
    let language: AppLanguage

    func text(_ key: AppStringKey) -> String {
        switch language {
        case .korean:
            Self.korean[key, default: ""]
        case .english:
            Self.english[key, default: ""]
        }
    }

    private static let korean: [AppStringKey: String] = [
        .aiUsage: "AI 사용량",
        .settingsTitle: "설정",
        .settingsSubtitle: "로그인 실행과 프로바이더 인증을 관리합니다.",
        .language: "언어",
        .korean: "한국어",
        .english: "English",
        .providerAuthentication: "프로바이더 인증",
        .reconnect: "연결 다시 확인",
        .launchAtLogin: "로그인 시 실행",
        .launchDisabled: "로그인할 때 자동으로 실행하지 않습니다.",
        .launchEnabled: "로그인할 때 자동으로 실행됩니다.",
        .launchApproval: "시스템 설정에서 허용이 필요합니다.",
        .launchNotFound: "앱을 Applications 폴더에 설치한 뒤 다시 시도해 주세요.",
        .launchChangeFailed: "로그인 항목을 변경하지 못했습니다.",
        .openLoginItems: "로그인 항목 설정 열기",
        .connected: "연결됨",
        .checkFailed: "확인 실패",
        .notConnected: "연결 안 됨",
        .checking: "확인 중",
        .moveUp: "%@ 위로 이동",
        .moveDown: "%@ 아래로 이동",
        .setupHelp: "설정 도움말",
        .startConnection: "연결 시작",
        .disconnect: "연결 해제",
        .reconnectProvider: "다시 연결",
        .codexUsageTier: "Codex 사용량 등급",
        .apiKey: "API 키",
        .save: "저장",
        .delete: "삭제",
        .openOfficialGuide: "공식 안내 열기",
        .cannotStartConnection: "연결을 시작할 수 없습니다",
        .confirm: "확인",
        .openedConnection: "%@ 연결 화면을 열었습니다.",
        .openedOfficialAuthentication: "%@ 공식 인증 페이지를 열었습니다.",
        .disconnectedProvider:
            "%@ 연결을 OmoUsage에서 해제했습니다. 외부 로그인은 유지됩니다.",
        .reconnectedProvider: "%@ 연결을 OmoUsage에서 다시 사용합니다.",
        .savedKey: "%@ 키를 저장했습니다.",
        .removedKey: "%@ 키를 삭제했습니다.",
        .saveKeyFailed: "키를 저장하지 못했습니다.",
        .removeKeyFailed: "키를 삭제하지 못했습니다.",
        .refresh: "새로고침",
        .settings: "설정",
        .quit: "종료",
        .inProgress: "진행 중",
        .authenticationRequired: "인증 필요",
        .unavailable: "사용할 수 없음",
        .refreshFailed: "새로고침 실패",
        .lastRefresh: "마지막 갱신 %@",
        .justNow: "방금",
        .asOfNow: "방금 기준",
        .asOf: "%@ 기준",
        .remaining: "%d%% 남음",
        .noResetInfo: "리셋 정보 없음",
        .resetMinutes: "%d분 후 리셋",
        .resetHours: "%d시간 후 리셋",
        .resetHoursMinutes: "%d시간 %d분 후 리셋",
        .resetDays: "%d일 후 리셋",
        .usageSession: "세션",
        .usageWeek: "주간",
        .usageExtra: "추가 사용량",
        .usageDay: "일간",
        .usageMonth: "월간",
        .usageNamedWeek: "%@ 주간",
        .asOfMinutesAgo: "%d분 전 기준",
        .providerConnectionMethod: "%@ 연결 방법",
        .unableToFindConnection: "%@ 연결 방법을 찾지 못했습니다.",
        .unableToLaunch: "%@을(를) 열지 못했습니다.",
        .unableToOpenOfficialAuthentication: "공식 인증 페이지를 열지 못했습니다.",
        .mobileNoDataTitle: "아직 동기화된 사용량이 없습니다",
        .mobileNoDataDescription:
            "Mac에서 OmoUsage를 새로고침하고 두 기기가 같은 Apple ID를 사용하는지 확인하세요.",
        .mobileSyncFailed: "iCloud 사용량을 불러오지 못했습니다.",
        .retry: "다시 시도",
        .syncedThroughICloud: "iCloud로 동기화됨"
    ]

    private static let english: [AppStringKey: String] = [
        .aiUsage: "AI Usage",
        .settingsTitle: "Settings",
        .settingsSubtitle: "Manage launch at login and provider authentication.",
        .language: "Language",
        .korean: "한국어",
        .english: "English",
        .providerAuthentication: "Provider Authentication",
        .reconnect: "Check Connections",
        .launchAtLogin: "Launch at Login",
        .launchDisabled: "Does not launch automatically when you log in.",
        .launchEnabled: "Launches automatically when you log in.",
        .launchApproval: "Approval is required in System Settings.",
        .launchNotFound: "Install the app in Applications, then try again.",
        .launchChangeFailed: "Could not update the login item.",
        .openLoginItems: "Open Login Items Settings",
        .connected: "Connected",
        .checkFailed: "Check Failed",
        .notConnected: "Not Connected",
        .checking: "Checking",
        .moveUp: "Move %@ up",
        .moveDown: "Move %@ down",
        .setupHelp: "Setup Help",
        .startConnection: "Connect",
        .disconnect: "Disconnect",
        .reconnectProvider: "Reconnect",
        .codexUsageTier: "Codex Usage Tier",
        .apiKey: "API Key",
        .save: "Save",
        .delete: "Delete",
        .openOfficialGuide: "Open Official Guide",
        .cannotStartConnection: "Could Not Start Connection",
        .confirm: "OK",
        .openedConnection: "Opened the %@ connection flow.",
        .openedOfficialAuthentication: "Opened the official %@ authentication page.",
        .disconnectedProvider:
            "Disconnected %@ from OmoUsage. The external login remains active.",
        .reconnectedProvider: "Re-enabled %@ in OmoUsage.",
        .savedKey: "Saved the %@ key.",
        .removedKey: "Removed the %@ key.",
        .saveKeyFailed: "Could not save the key.",
        .removeKeyFailed: "Could not remove the key.",
        .refresh: "Refresh",
        .settings: "Settings",
        .quit: "Quit",
        .inProgress: "In Progress",
        .authenticationRequired: "Authentication Required",
        .unavailable: "Unavailable",
        .refreshFailed: "Refresh Failed",
        .lastRefresh: "Last refreshed %@",
        .justNow: "Just now",
        .asOfNow: "As of now",
        .asOf: "As of %@",
        .remaining: "%d%% remaining",
        .noResetInfo: "No reset information",
        .resetMinutes: "Resets in %d min",
        .resetHours: "Resets in %d hr",
        .resetHoursMinutes: "Resets in %d hr %d min",
        .resetDays: "Resets in %d days",
        .usageSession: "Session",
        .usageWeek: "Weekly",
        .usageExtra: "Extra usage",
        .usageDay: "Daily",
        .usageMonth: "Monthly",
        .usageNamedWeek: "%@ weekly",
        .asOfMinutesAgo: "As of %d min ago",
        .providerConnectionMethod: "Connect %@",
        .unableToFindConnection: "Could not find a connection method for %@.",
        .unableToLaunch: "Could not open %@.",
        .unableToOpenOfficialAuthentication: "Could not open the official authentication page.",
        .mobileNoDataTitle: "No synced usage yet",
        .mobileNoDataDescription:
            "Refresh OmoUsage on your Mac and make sure both devices use the same Apple ID.",
        .mobileSyncFailed: "Could not load usage from iCloud.",
        .retry: "Try Again",
        .syncedThroughICloud: "Synced through iCloud"
    ]
}
