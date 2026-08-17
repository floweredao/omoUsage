import Testing
@testable import OmoUsage

@Suite
@MainActor
struct LaunchAtLoginControllerTests {
    @Test
    func enablingRegistersAndRefreshesEnabledState() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerResult = {
            service.status = .enabled
        }
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(service.registerCount == 1)
        #expect(controller.state == .enabled)
        #expect(controller.isEnabled)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func disablingUnregistersAndRefreshesDisabledState() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterResult = {
            service.status = .notRegistered
        }
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(false)

        #expect(service.unregisterCount == 1)
        #expect(controller.state == .notRegistered)
        #expect(!controller.isEnabled)
    }

    @Test
    func registrationErrorRollsBackAndSurfacesMessage() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerResult = {
            throw FakeLaunchAtLoginError.denied
        }
        let controller = LaunchAtLoginController(service: service)

        controller.setEnabled(true)

        #expect(controller.state == .notRegistered)
        #expect(!controller.isEnabled)
        #expect(controller.errorMessage == "로그인 항목을 변경하지 못했습니다.")
    }

    @Test
    func requiresApprovalOffersSystemSettingsAction() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        #expect(controller.isEnabled)
        #expect(controller.showsSystemSettingsButton)
        #expect(controller.statusText == "시스템 설정에서 허용이 필요합니다.")

        controller.openSystemSettings()
        #expect(service.openSettingsCount == 1)
    }

    @Test
    func notFoundExplainsInstallationRequirement() {
        let service = FakeLaunchAtLoginService(status: .notFound)
        let controller = LaunchAtLoginController(service: service)

        #expect(!controller.isEnabled)
        #expect(!controller.showsSystemSettingsButton)
        #expect(
            controller.statusText
                == "앱을 Applications 폴더에 설치한 뒤 다시 시도해 주세요."
        )
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    var registerResult: () throws -> Void = {}
    var unregisterResult: () throws -> Void = {}
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        try registerResult()
    }

    func unregister() throws {
        unregisterCount += 1
        try unregisterResult()
    }

    func openSystemSettings() {
        openSettingsCount += 1
    }
}

private enum FakeLaunchAtLoginError: Error {
    case denied
}
