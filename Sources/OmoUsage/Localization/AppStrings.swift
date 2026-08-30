enum AppStringKey: String, CaseIterable, Sendable {
    case aiUsage
    case settingsTitle
    case settingsSubtitle
    case registryRecoveredTitle
    case registryRecoveredDescription
    case registryBlockedTitle
    case registryBlockedDescription
    case restoreRegistryBackup
    case resetRegistry
    case registryResetTitle
    case registryResetDescription
    case registryRestoreSucceeded
    case registryResetSucceeded
    case registryRecoveryFailed
    case cancel
    case language
    case korean
    case english
    case dashboardPresentation
    case popoverPresentation
    case sideNotchPresentation
    case sideNotchHideDelay
    case sideNotchHideDelayOption
    case sideNotchShowDetails
    case providerAuthentication
    case dashboardOrder
    case resetToDefault
    case orderPosition
    case hiddenFromDashboard
    case dragToReorder
    case launchAtLogin
    case launchDisabled
    case launchEnabled
    case launchApproval
    case launchNotFound
    case launchChangeFailed
    case openLoginItems
    case webDashboard
    case webDashboardDescription
    case openWebDashboard
    case webDashboardOpenFailed
    case diagnostics
    case diagnosticsDescription
    case exportDiagnostics
    case diagnosticsExportSucceeded
    case diagnosticsExportFailed
    case connected
    case checkFailed
    case notConnected
    case checking
    case companionRequired
    case waitingForCompanionCredentials
    case moveUp
    case moveDown
    case setupHelp
    case startConnection
    case disconnect
    case reconnectProvider
    case codexUsageTier
    case apiKey
    case apiKeyAccounts
    case keySourceEnvironment
    case keySourceKeychain
    case keySourceLegacyFile
    case retryLegacyKeyCleanup
    case legacyKeyCleanupSucceeded
    case legacyKeyCleanupFailed
    case accountProvider
    case accountAlias
    case addAccount
    case removeAccount
    case addedAccount
    case removedAccount
    case accountChangeFailed
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
    case lastRefreshAttempt
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
        .registryRecoveredTitle: "계정 레지스트리를 백업에서 불러왔습니다",
        .registryRecoveredDescription:
            "손상된 원본은 격리했습니다. 백업을 복원하거나 새 레지스트리로 재설정하세요.",
        .registryBlockedTitle: "계정 레지스트리를 사용할 수 없습니다",
        .registryBlockedDescription:
            "유효한 레지스트리가 없어 프로바이더와 계정 변경을 차단했습니다. 손상된 파일은 격리되어 있습니다.",
        .restoreRegistryBackup: "백업 복원",
        .resetRegistry: "레지스트리 재설정",
        .registryResetTitle: "계정 레지스트리를 재설정할까요?",
        .registryResetDescription:
            "현재 계정 구성을 새 기본 구성으로 바꿉니다. 격리된 파일은 보존됩니다.",
        .registryRestoreSucceeded: "계정 레지스트리 백업을 복원했습니다.",
        .registryResetSucceeded: "새 계정 레지스트리를 만들었습니다.",
        .registryRecoveryFailed: "계정 레지스트리를 복구하지 못했습니다.",
        .cancel: "취소",
        .language: "언어",
        .korean: "한국어",
        .english: "English",
        .dashboardPresentation: "UI 방식",
        .popoverPresentation: "기존 팝오버",
        .sideNotchPresentation: "사이드 노치",
        .sideNotchHideDelay: "사이드 노치 숨김 시간",
        .sideNotchHideDelayOption: "%.1f초 후",
        .sideNotchShowDetails: "사용량 상세 보기",
        .providerAuthentication: "프로바이더 인증",
        .dashboardOrder: "대시보드 순서",
        .resetToDefault: "기본 순서로 재설정",
        .orderPosition: "%d / %d",
        .hiddenFromDashboard: "대시보드에서 숨김",
        .dragToReorder: "드래그하여 순서 변경",
        .launchAtLogin: "로그인 시 실행",
        .launchDisabled: "로그인할 때 자동으로 실행하지 않습니다.",
        .launchEnabled: "로그인할 때 자동으로 실행됩니다.",
        .launchApproval: "시스템 설정에서 허용이 필요합니다.",
        .launchNotFound: "앱을 Applications 폴더에 설치한 뒤 다시 시도해 주세요.",
        .launchChangeFailed: "로그인 항목을 변경하지 못했습니다.",
        .openLoginItems: "로그인 항목 설정 열기",
        .webDashboard: "웹 대시보드",
        .webDashboardDescription:
            "일회용 보안 링크로 이 Mac의 대시보드를 엽니다.",
        .openWebDashboard: "대시보드 열기",
        .webDashboardOpenFailed: "웹 대시보드를 열지 못했습니다.",
        .diagnostics: "진단 정보",
        .diagnosticsDescription:
            "민감한 내용을 제외한 기계 판독용 진단 정보를 내보냅니다.",
        .exportDiagnostics: "진단 정보 내보내기",
        .diagnosticsExportSucceeded: "진단 정보를 내보냈습니다.",
        .diagnosticsExportFailed: "진단 정보를 내보내지 못했습니다.",
        .connected: "연결됨",
        .checkFailed: "확인 실패",
        .notConnected: "연결 안 됨",
        .checking: "확인 중",
        .companionRequired: "컴패니언 필요",
        .waitingForCompanionCredentials: "컴패니언 인증 대기 중",
        .moveUp: "%@ 위로 이동",
        .moveDown: "%@ 아래로 이동",
        .setupHelp: "설정 도움말",
        .startConnection: "연결 시작",
        .disconnect: "연결 해제",
        .reconnectProvider: "다시 연결",
        .codexUsageTier: "Codex 사용량 등급",
        .apiKey: "API 키",
        .apiKeyAccounts: "API 키 계정",
        .keySourceEnvironment: "소스: 환경 변수",
        .keySourceKeychain: "소스: 키체인",
        .keySourceLegacyFile: "소스: 이전 키 파일",
        .retryLegacyKeyCleanup: "이전 파일 정리 다시 시도",
        .legacyKeyCleanupSucceeded: "이전 키 파일을 정리했습니다.",
        .legacyKeyCleanupFailed: "이전 키 파일을 정리하지 못했습니다.",
        .accountProvider: "프로바이더",
        .accountAlias: "계정 별칭",
        .addAccount: "계정 추가",
        .removeAccount: "%@ 계정 삭제",
        .addedAccount: "%@ 계정을 추가했습니다.",
        .removedAccount: "%@ 계정을 삭제했습니다.",
        .accountChangeFailed: "API 키 계정을 변경하지 못했습니다.",
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
        .lastRefreshAttempt: "마지막 갱신 %@",
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
        .unableToLaunch: "%@ 열기에 실패했습니다.",
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
        .registryRecoveredTitle: "Account registry loaded from backup",
        .registryRecoveredDescription:
            "The damaged original was quarantined. Restore the backup or reset to a new registry.",
        .registryBlockedTitle: "Account registry unavailable",
        .registryBlockedDescription:
            "No valid registry exists, so providers and account changes are blocked. Damaged files remain quarantined.",
        .restoreRegistryBackup: "Restore Backup",
        .resetRegistry: "Reset Registry",
        .registryResetTitle: "Reset the account registry?",
        .registryResetDescription:
            "This replaces the account configuration with a new default registry. Quarantined files are preserved.",
        .registryRestoreSucceeded: "Restored the account registry backup.",
        .registryResetSucceeded: "Created a new account registry.",
        .registryRecoveryFailed: "Could not recover the account registry.",
        .cancel: "Cancel",
        .language: "Language",
        .korean: "한국어",
        .english: "English",
        .dashboardPresentation: "Interface",
        .popoverPresentation: "Popover",
        .sideNotchPresentation: "Side Notch",
        .sideNotchHideDelay: "Side Notch Hide Delay",
        .sideNotchHideDelayOption: "After %.1f sec",
        .sideNotchShowDetails: "Show usage details",
        .providerAuthentication: "Provider Authentication",
        .dashboardOrder: "Dashboard Order",
        .resetToDefault: "Reset to Default",
        .orderPosition: "%d of %d",
        .hiddenFromDashboard: "Hidden from dashboard",
        .dragToReorder: "Drag to reorder",
        .launchAtLogin: "Launch at Login",
        .launchDisabled: "Does not launch automatically when you log in.",
        .launchEnabled: "Launches automatically when you log in.",
        .launchApproval: "Approval is required in System Settings.",
        .launchNotFound: "Install the app in Applications, then try again.",
        .launchChangeFailed: "Could not update the login item.",
        .openLoginItems: "Open Login Items Settings",
        .webDashboard: "Web Dashboard",
        .webDashboardDescription:
            "Open this Mac's dashboard with a one-use secure link.",
        .openWebDashboard: "Open Dashboard",
        .webDashboardOpenFailed: "Could not open the web dashboard.",
        .diagnostics: "Diagnostics",
        .diagnosticsDescription:
            "Export machine-readable diagnostics with sensitive data excluded.",
        .exportDiagnostics: "Export Diagnostics",
        .diagnosticsExportSucceeded: "Exported diagnostics.",
        .diagnosticsExportFailed: "Could not export diagnostics.",
        .connected: "Connected",
        .checkFailed: "Check Failed",
        .notConnected: "Not Connected",
        .checking: "Checking",
        .companionRequired: "Companion required",
        .waitingForCompanionCredentials: "Waiting for companion credentials",
        .moveUp: "Move %@ up",
        .moveDown: "Move %@ down",
        .setupHelp: "Setup Help",
        .startConnection: "Connect",
        .disconnect: "Disconnect",
        .reconnectProvider: "Reconnect",
        .codexUsageTier: "Codex Usage Tier",
        .apiKey: "API Key",
        .apiKeyAccounts: "API Key Accounts",
        .keySourceEnvironment: "Source: Environment",
        .keySourceKeychain: "Source: Keychain",
        .keySourceLegacyFile: "Source: Legacy key file",
        .retryLegacyKeyCleanup: "Retry Legacy File Cleanup",
        .legacyKeyCleanupSucceeded: "Removed the legacy key file.",
        .legacyKeyCleanupFailed: "Could not remove the legacy key file.",
        .accountProvider: "Provider",
        .accountAlias: "Account Alias",
        .addAccount: "Add Account",
        .removeAccount: "Remove %@ account",
        .addedAccount: "Added the %@ account.",
        .removedAccount: "Removed the %@ account.",
        .accountChangeFailed: "Could not update API key accounts.",
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
        .lastRefreshAttempt: "Last refreshed %@",
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
