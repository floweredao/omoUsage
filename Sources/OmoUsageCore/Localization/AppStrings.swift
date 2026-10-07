public enum AppStringKey: String, CaseIterable, Sendable {
    case aiUsage
    case settingsTitle
    case settingsSubtitle
    case generalSettings
    case displaySettings
    case webAccessSettings
    case dashboardEmptyTitle
    case dashboardEmptyDescription
    case dashboardChecking
    case openSettings
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
    case fileMenu
    case close
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
    case webDashboardDisabled
    case webDashboardStarting
    case webDashboardReady
    case webDashboardFailed
    case webDashboardEndpointDetails
    case webDashboardTailscaleEndpointDetails
    case webDashboardPortInUse
    case webDashboardPermissionDenied
    case webDashboardUnavailable
    case openQRCode
    case shareLink
    case webDashboardQRCodeTitle
    case webDashboardQRCodeDescription
    case webDashboardQRCodeLabel
    case webDashboardLinkCreationFailed
    case appUpdates
    case appUpdatesDescription
    case appUpdateVersion
    case checkForAppUpdates
    case appUpdatesUnavailable
    case connected
    case checkFailed
    case notConnected
    case checking
    case companionRequired
    case waitingForCompanionCredentials
    case waitingForBrowserLogin
    case waitingForSignIn
    case browserLoginFailed
    case claudeSignInTimedOut
    case claudeSignInCancelled
    case claudeSignInFailed
    case claudeSignInSaveFailed
    case browserSignInTimedOut
    case browserSignInDenied
    case browserUsageUnavailable
    case browserCredentialSaveFailed
    case kiroAccountMismatch
    case kiroAccountAlreadyConnected
    case kiroUnsupportedOrganization
    case connectionVerificationFailed
    case moveUp
    case moveDown
    case setupHelp
    case startConnection
    case disconnect
    case reconnectProvider
    case codexUsageTier
    case apiKey
    case keySourceEnvironment
    case keySourceKeychain
    case keySourceLegacyFile
    case retryLegacyKeyCleanup
    case legacyKeyCleanupSucceeded
    case legacyKeyCleanupFailed
    case accountAlias
    case addAccount
    case accountAliasExample
    case additionalAccountLogin
    case additionalAccountInstructions
    case additionalAPIKeyInstructions
    case accountLoginPending
    case removeAccount
    case addedAccount
    case removedAccount
    case accountChangeFailed
    case checkAgainForCompanionCredentials
    case companionCredentialMissing
    case companionCredentialUnchanged
    case companionCredentialUnavailable
    case accountAdditionFailed
    case primaryAccount
    case additionalAccount
    case editAccountAlias
    case accountIdentity
    case accountCodexUsageTier
    case savedAccountAlias
    case accountAliasInvalid
    case saveAccountAliasFailed
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
    case removeKeyTitle
    case refresh
    case settings
    case quit
    case moreActions
    case inProgress
    case authenticationRequired
    case unavailable
    case refreshFailed
    case rateLimitRetryNotice
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
    case resetOneDay
    case resetOneDayHours
    case resetDaysHours
    case expiryMinutes
    case expiryHours
    case expiryHoursMinutes
    case expiryDays
    case expiryOneDay
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
    case macLastChecked
    case mobileSnapshotOutOfDate
    case mobileRetainedAfterSyncFailure
    case checkICloud
    case mobileICloudCheckExplanation
    // settings
    case checkConnectionsAgain
    case checkConnectionsAgainDescription
    case dashboardPresentationDescription
    case dashboardOrderDescription
}

public struct AppStrings: Sendable {
    public let language: AppLanguage

    public init(language: AppLanguage) {
        self.language = language
    }

    public func text(_ key: AppStringKey) -> String {
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
        .settingsSubtitle: "프로바이더 인증과 앱 설정을 관리합니다.",
        .generalSettings: "일반",
        .displaySettings: "화면 표시",
        .webAccessSettings: "웹 접근",
        .dashboardEmptyTitle: "표시할 사용량이 없습니다",
        .dashboardEmptyDescription: "설정에서 계정을 연결하거나 표시 상태를 확인하세요.",
        .dashboardChecking: "사용량을 확인하고 있습니다",
        .openSettings: "설정 열기",
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
        .fileMenu: "파일",
        .close: "닫기",
        .language: "언어",
        .korean: "한국어",
        .english: "English",
        .dashboardPresentation: "UI 방식",
        .popoverPresentation: "기존 팝오버",
        .sideNotchPresentation: "사이드 노치",
        .sideNotchHideDelay: "사이드 노치 숨김 시간",
        .sideNotchHideDelayOption: "%.1f초 후",
        .sideNotchShowDetails: "사용량 상세 보기",
        .providerAuthentication: "인증",
        .dashboardOrder: "순서",
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
            "이 Mac 또는 개인 Tailscale 네트워크에서 대시보드를 엽니다.",
        .openWebDashboard: "대시보드 열기",
        .webDashboardOpenFailed: "웹 대시보드를 열지 못했습니다.",
        .webDashboardDisabled: "비활성화됨",
        .webDashboardStarting: "시작 중",
        .webDashboardReady: "준비됨",
        .webDashboardFailed: "실패",
        .webDashboardEndpointDetails: "포트 %@ · 루프백 전용",
        .webDashboardTailscaleEndpointDetails:
            "Tailscale 전용 HTTPS %@ · 로컬 포트 %@",
        .webDashboardPortInUse:
            "포트 %@이(가) 이미 사용 중입니다. 해당 포트를 사용하는 앱을 종료한 후 다시 시도하세요.",
        .webDashboardPermissionDenied:
            "macOS에서 포트 %@ 접근을 거부했습니다. 보안 설정을 확인한 후 다시 시도하세요.",
        .webDashboardUnavailable:
            "포트 %@에서 로컬 대시보드를 시작하지 못했습니다. 다시 시도하거나 OmoUsage를 재시작하세요.",
        .openQRCode: "QR 코드 열기",
        .shareLink: "링크 공유",
        .webDashboardQRCodeTitle: "웹 대시보드 QR 코드",
        .webDashboardQRCodeDescription:
            "같은 개인 tailnet에 연결된 기기로 QR 코드를 스캔하세요.",
        .webDashboardQRCodeLabel:
            "웹 대시보드 QR 코드",
        .webDashboardLinkCreationFailed:
            "웹 대시보드 링크를 만들지 못했습니다.",
        .appUpdates: "업데이트",
        .appUpdatesDescription:
            "새 버전을 확인하고 다운로드한 뒤 앱을 업데이트합니다.",
        .appUpdateVersion: "현재 버전 %@",
        .checkForAppUpdates: "업데이트 확인",
        .appUpdatesUnavailable: "이 실행 환경에서는 업데이트를 사용할 수 없습니다.",
        .connected: "연결됨",
        .checkFailed: "확인 실패",
        .notConnected: "연결 안 됨",
        .checking: "확인 중",
        .companionRequired: "컴패니언 필요",
        .waitingForCompanionCredentials: "컴패니언 인증 대기 중",
        .waitingForBrowserLogin: "브라우저 로그인을 완료하면 사용량을 자동으로 확인합니다.",
        .waitingForSignIn: "로그인 대기 중",
        .browserLoginFailed: "브라우저 로그인에 실패했습니다. 다시 연결해 주세요.",
        .claudeSignInTimedOut: "Claude 로그인 시간이 초과되었습니다. 다시 연결해 주세요.",
        .claudeSignInCancelled: "Claude 로그인이 취소되었습니다.",
        .claudeSignInFailed: "Claude 로그인에 실패했습니다. 다시 연결해 주세요.",
        .claudeSignInSaveFailed: "Claude 인증을 저장하지 못했습니다. 다시 연결해 주세요.",
        .browserSignInTimedOut: "브라우저 로그인 시간이 초과되었습니다. 다시 연결해 주세요.",
        .browserSignInDenied: "브라우저에서 로그인이 거부되었습니다.",
        .browserUsageUnavailable: "로그인했지만 사용량을 확인하지 못했습니다. 잠시 후 다시 연결해 주세요.",
        .browserCredentialSaveFailed: "인증을 저장하지 못했습니다. 다시 연결해 주세요.",
        .kiroAccountMismatch: "연결하려던 계정과 다른 Kiro 계정으로 로그인했습니다. 해당 계정으로 다시 로그인해 주세요.",
        .kiroAccountAlreadyConnected: "이미 추가된 Kiro 계정입니다. 다른 계정으로 로그인해 주세요.",
        .kiroUnsupportedOrganization: "지원하지 않는 Kiro 조직 계정입니다.",
        .connectionVerificationFailed: "로그인 후 사용량을 확인하지 못했습니다. 새로고침으로 다시 확인해 주세요.",
        .moveUp: "%@ 위로 이동",
        .moveDown: "%@ 아래로 이동",
        .setupHelp: "설정 도움말",
        .startConnection: "연결 시작",
        .disconnect: "연결 해제",
        .reconnectProvider: "다시 연결",
        .codexUsageTier: "Codex 사용량 등급",
        .apiKey: "API 키",
        .keySourceEnvironment: "소스: 환경 변수",
        .keySourceKeychain: "소스: 키체인",
        .keySourceLegacyFile: "소스: 이전 키 파일",
        .retryLegacyKeyCleanup: "이전 파일 정리 다시 시도",
        .legacyKeyCleanupSucceeded: "이전 키 파일을 정리했습니다.",
        .legacyKeyCleanupFailed: "이전 키 파일을 정리하지 못했습니다.",
        .accountAlias: "계정 별칭",
        .addAccount: "계정 추가",
        .accountAliasExample: "예: 개인용, 업무용",
        .additionalAccountLogin: "다른 계정으로 로그인",
        .additionalAccountInstructions:
            "구분할 이름을 입력한 뒤 다른 계정으로 로그인하세요. 기존 계정과 별도로 추가됩니다.",
        .additionalAPIKeyInstructions:
            "구분할 이름과 새 계정의 API 키를 입력하세요.",
        .accountLoginPending: "%@ 계정 로그인 대기 중",
        .removeAccount: "%@ 계정 삭제",
        .addedAccount: "%@ 계정을 추가했습니다.",
        .removedAccount: "%@ 계정을 삭제했습니다.",
        .accountChangeFailed: "API 키 계정을 변경하지 못했습니다.",
        .checkAgainForCompanionCredentials: "다시 확인",
        .companionCredentialMissing:
            "아직 새 인증값이 없습니다. 공식 로그인을 끝낸 뒤 다시 확인을 누르세요.",
        .companionCredentialUnchanged:
            "컴패니언에 이전 계정 인증값이 그대로 있습니다. 다른 계정으로 로그인한 뒤 다시 확인을 누르세요.",
        .companionCredentialUnavailable:
            "현재 컴패니언 인증값을 읽지 못해 계정 추가를 시작하지 않았습니다.",
        .accountAdditionFailed: "계정을 추가하지 못했습니다.",
        .primaryAccount: "주 계정",
        .additionalAccount: "추가 계정",
        .editAccountAlias: "%@ 별칭 편집",
        .accountIdentity: "식별자 %@",
        .accountCodexUsageTier: "%@ Codex 사용량 등급",
        .savedAccountAlias: "별칭을 저장했습니다: %@",
        .accountAliasInvalid:
            "사용할 수 없는 별칭입니다. @, /, \\ 없이 128자 이내의 고유한 이름을 입력하세요.",
        .saveAccountAliasFailed: "계정 별칭을 저장하지 못했습니다.",
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
        .removeKeyTitle: "%@ 키 삭제",
        .refresh: "새로고침",
        .settings: "설정",
        .quit: "종료",
        .moreActions: "더 보기",
        .inProgress: "진행 중",
        .authenticationRequired: "인증 필요",
        .unavailable: "사용할 수 없음",
        .refreshFailed: "새로고침 실패",
        .rateLimitRetryNotice: "잠시 후 다시 확인할게요",
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
        .resetOneDay: "1일 후 리셋",
        .resetOneDayHours: "1일 %d시간 후 리셋",
        .resetDaysHours: "%d일 %d시간 후 리셋",
        .expiryMinutes: "%d분 후 만료",
        .expiryHours: "%d시간 후 만료",
        .expiryHoursMinutes: "%d시간 %d분 후 만료",
        .expiryDays: "%d일 후 만료",
        .expiryOneDay: "1일 후 만료",
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
        .syncedThroughICloud: "iCloud로 동기화됨",
        .macLastChecked: "Mac 마지막 확인 %@",
        .mobileSnapshotOutOfDate: "오래된 데이터",
        .mobileRetainedAfterSyncFailure:
            "iCloud 확인에 실패해 마지막으로 받은 데이터를 그대로 표시합니다.",
        .checkICloud: "iCloud 확인",
        .mobileICloudCheckExplanation:
            "Mac이 iCloud에 올린 최신 데이터만 확인합니다. 이 기기는 프로바이더에 직접 연결하지 않습니다.",
        // settings
        .checkConnectionsAgain: "연결 다시 확인",
        .checkConnectionsAgainDescription:
            "연결된 모든 계정의 인증을 다시 읽고 사용량을 새로고침합니다.",
        .dashboardPresentationDescription:
            "팝오버는 메뉴 막대 아이콘에서 열립니다. 사이드 노치는 화면 오른쪽 가장자리에 얇은 손잡이를 두고, 손잡이에 포인터를 가져가거나 메뉴 막대 아이콘을 클릭하면 사용량을 보여줍니다.",
        .dashboardOrderDescription:
            "행의 손잡이를 드래그하거나 Command-위/아래 화살표 키를 눌러 대시보드에 표시되는 순서를 바꿉니다."
    ]

    private static let english: [AppStringKey: String] = [
        .aiUsage: "AI Usage",
        .settingsTitle: "Settings",
        .settingsSubtitle: "Manage provider authentication and app settings.",
        .generalSettings: "General",
        .displaySettings: "Display",
        .webAccessSettings: "Web Access",
        .dashboardEmptyTitle: "No usage to display",
        .dashboardEmptyDescription: "Connect an account or check its visibility in Settings.",
        .dashboardChecking: "Checking usage",
        .openSettings: "Open Settings",
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
        .fileMenu: "File",
        .close: "Close",
        .language: "Language",
        .korean: "한국어",
        .english: "English",
        .dashboardPresentation: "Interface",
        .popoverPresentation: "Popover",
        .sideNotchPresentation: "Side Notch",
        .sideNotchHideDelay: "Side Notch Hide Delay",
        .sideNotchHideDelayOption: "After %.1f sec",
        .sideNotchShowDetails: "Show usage details",
        .providerAuthentication: "Auth",
        .dashboardOrder: "Order",
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
            "Open the dashboard on this Mac or through your personal Tailscale network.",
        .openWebDashboard: "Open Dashboard",
        .webDashboardOpenFailed: "Could not open the web dashboard.",
        .webDashboardDisabled: "Disabled",
        .webDashboardStarting: "Starting",
        .webDashboardReady: "Ready",
        .webDashboardFailed: "Failed",
        .webDashboardEndpointDetails: "Port %@ · Loopback only",
        .webDashboardTailscaleEndpointDetails:
            "Tailscale-only HTTPS %@ · local port %@",
        .webDashboardPortInUse:
            "Port %@ is already in use. Close the app using it, then retry.",
        .webDashboardPermissionDenied:
            "macOS denied access to port %@. Check security settings, then retry.",
        .webDashboardUnavailable:
            "The local dashboard could not start on port %@. Retry, or restart OmoUsage.",
        .openQRCode: "Open QR Code",
        .shareLink: "Share Link",
        .webDashboardQRCodeTitle: "Web Dashboard QR Code",
        .webDashboardQRCodeDescription:
            "Scan this QR code from a device on your personal tailnet.",
        .webDashboardQRCodeLabel:
            "Web dashboard QR code",
        .webDashboardLinkCreationFailed:
            "Could not create a web dashboard link.",
        .appUpdates: "Updates",
        .appUpdatesDescription:
            "Check for a new version, then download and install the update.",
        .appUpdateVersion: "Current version %@",
        .checkForAppUpdates: "Check for Updates",
        .appUpdatesUnavailable: "Updates are unavailable in this environment.",
        .connected: "Connected",
        .checkFailed: "Check Failed",
        .notConnected: "Not Connected",
        .checking: "Checking",
        .companionRequired: "Companion required",
        .waitingForCompanionCredentials: "Waiting for companion credentials",
        .waitingForBrowserLogin: "Complete browser sign-in to verify usage automatically.",
        .waitingForSignIn: "Waiting for sign-in",
        .browserLoginFailed: "Browser sign-in failed. Please connect again.",
        .claudeSignInTimedOut: "Claude sign-in timed out. Please connect again.",
        .claudeSignInCancelled: "Claude sign-in was cancelled.",
        .claudeSignInFailed: "Claude sign-in failed. Please connect again.",
        .claudeSignInSaveFailed: "Couldn't save the Claude credential. Please connect again.",
        .browserSignInTimedOut: "Browser sign-in timed out. Please connect again.",
        .browserSignInDenied: "Sign-in was declined in the browser.",
        .browserUsageUnavailable: "Signed in, but usage couldn't be verified. Try connecting again later.",
        .browserCredentialSaveFailed: "Couldn't save the credential. Please connect again.",
        .kiroAccountMismatch: "You signed in to a different Kiro account than the one being connected. Sign in with that account.",
        .kiroAccountAlreadyConnected: "That Kiro account is already added. Sign in with a different account.",
        .kiroUnsupportedOrganization: "This Kiro organization account isn't supported.",
        .connectionVerificationFailed: "Couldn't verify usage after sign-in. Use Refresh to try again.",
        .moveUp: "Move %@ up",
        .moveDown: "Move %@ down",
        .setupHelp: "Setup Help",
        .startConnection: "Connect",
        .disconnect: "Disconnect",
        .reconnectProvider: "Reconnect",
        .codexUsageTier: "Codex Usage Tier",
        .apiKey: "API Key",
        .keySourceEnvironment: "Source: Environment",
        .keySourceKeychain: "Source: Keychain",
        .keySourceLegacyFile: "Source: Legacy key file",
        .retryLegacyKeyCleanup: "Retry Legacy File Cleanup",
        .legacyKeyCleanupSucceeded: "Removed the legacy key file.",
        .legacyKeyCleanupFailed: "Could not remove the legacy key file.",
        .accountAlias: "Account Alias",
        .addAccount: "Add Account",
        .accountAliasExample: "e.g. Personal, Work",
        .additionalAccountLogin: "Sign In to Another Account",
        .additionalAccountInstructions:
            "Give this account a name, then sign in to another account. It will be added separately from your existing account.",
        .additionalAPIKeyInstructions:
            "Enter a name and the new account's API key.",
        .accountLoginPending: "Waiting for %@ to sign in",
        .removeAccount: "Remove %@ account",
        .addedAccount: "Added the %@ account.",
        .removedAccount: "Removed the %@ account.",
        .accountChangeFailed: "Could not update API key accounts.",
        .checkAgainForCompanionCredentials: "Check Again",
        .companionCredentialMissing:
            "No new credential yet. Finish the official login, then choose Check Again.",
        .companionCredentialUnchanged:
            "The companion still holds the previous account's credential. Sign in as the other account, then choose Check Again.",
        .companionCredentialUnavailable:
            "Could not read the current companion credential, so the account was not started.",
        .accountAdditionFailed: "Could not add the account.",
        .primaryAccount: "Primary",
        .additionalAccount: "Additional",
        .editAccountAlias: "Edit %@ alias",
        .accountIdentity: "Identifier %@",
        .accountCodexUsageTier: "%@ Codex usage tier",
        .savedAccountAlias: "Saved alias: %@",
        .accountAliasInvalid:
            "This alias can't be used. Enter a unique name up to 128 characters without @, /, or \\.",
        .saveAccountAliasFailed: "Could not save the account alias.",
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
        .removeKeyTitle: "Remove %@ key",
        .refresh: "Refresh",
        .settings: "Settings",
        .quit: "Quit",
        .moreActions: "More",
        .inProgress: "In Progress",
        .authenticationRequired: "Authentication Required",
        .unavailable: "Unavailable",
        .refreshFailed: "Refresh Failed",
        .rateLimitRetryNotice: "Checking again shortly",
        .lastRefreshAttempt: "Last refreshed %@",
        .justNow: "just now",
        .asOfNow: "As of now",
        .asOf: "As of %@",
        .remaining: "%d%% remaining",
        .noResetInfo: "No reset information",
        .resetMinutes: "Resets in %d min",
        .resetHours: "Resets in %d hr",
        .resetHoursMinutes: "Resets in %d hr %d min",
        .resetDays: "Resets in %d days",
        .resetOneDay: "Resets in 1 day",
        .resetOneDayHours: "Resets in 1 day %d hr",
        .resetDaysHours: "Resets in %d days %d hr",
        .expiryMinutes: "Expires in %d min",
        .expiryHours: "Expires in %d hr",
        .expiryHoursMinutes: "Expires in %d hr %d min",
        .expiryDays: "Expires in %d days",
        .expiryOneDay: "Expires in 1 day",
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
        .syncedThroughICloud: "Synced through iCloud",
        .macLastChecked: "Mac last checked %@",
        .mobileSnapshotOutOfDate: "Out of date",
        .mobileRetainedAfterSyncFailure:
            "The iCloud check failed, so the last data received is still shown.",
        .checkICloud: "Check iCloud",
        .mobileICloudCheckExplanation:
            "Checks iCloud for the newest data your Mac published. This device never contacts providers.",
        // settings
        .checkConnectionsAgain: "Check connections again",
        .checkConnectionsAgainDescription:
            "Reads every connected account's credential again and refreshes its usage.",
        .dashboardPresentationDescription:
            "Popover opens from the menu bar icon. Side Notch keeps a thin handle at the right edge of the screen and shows usage when you point at the handle or click the menu bar icon.",
        .dashboardOrderDescription:
            "Drag a row's handle, or press Command-Up Arrow and Command-Down Arrow, to change the order shown in the dashboard."
    ]
}
