import Observation
import ServiceManagement

enum LaunchAtLoginServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginServiceStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class ServiceManagementLaunchAtLoginService:
    LaunchAtLoginServicing
{
    var status: LaunchAtLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@Observable
@MainActor
final class LaunchAtLoginController {
    private let service: any LaunchAtLoginServicing
    private(set) var state: LaunchAtLoginServiceStatus
    private(set) var errorMessage: String?

    init() {
        let service = ServiceManagementLaunchAtLoginService()
        self.service = service
        state = service.status
    }

    init(service: any LaunchAtLoginServicing) {
        self.service = service
        state = service.status
    }

    var isEnabled: Bool {
        state == .enabled || state == .requiresApproval
    }

    var statusText: String {
        switch state {
        case .notRegistered:
            "로그인할 때 자동으로 실행하지 않습니다."
        case .enabled:
            "로그인할 때 자동으로 실행됩니다."
        case .requiresApproval:
            "시스템 설정에서 허용이 필요합니다."
        case .notFound:
            "앱을 Applications 폴더에 설치한 뒤 다시 시도해 주세요."
        }
    }

    var showsSystemSettingsButton: Bool {
        state == .requiresApproval
    }

    func refresh() {
        state = service.status
    }

    func setEnabled(_ enabled: Bool) {
        let previousState = state
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            state = service.status
        } catch {
            state = previousState
            errorMessage = "로그인 항목을 변경하지 못했습니다."
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
