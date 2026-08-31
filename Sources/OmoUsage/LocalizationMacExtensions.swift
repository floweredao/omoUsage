import OmoUsageCore

extension LocalizationResolving {
    func providerSetupError(
        _ error: ProviderSetupError
    ) -> String {
        switch error {
        case .companionRequired(_, let companions):
            let separator = language == .english ? " or " : " 또는 "
            let targets = companions.joined(separator: separator)
            if language == .english {
                return "Install \(targets) to continue."
            }
            return "\(targets) 설치가 필요합니다."
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
}
