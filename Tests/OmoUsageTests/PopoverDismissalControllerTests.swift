import AppKit
import Testing
@testable import OmoUsage

@Suite
@MainActor
struct PopoverDismissalControllerTests {
    @Test
    func globalMouseDownDismissesOpenPopover() {
        let monitor = FakePopoverMouseMonitor()
        let controller = PopoverDismissalController(monitor: monitor)
        var dismissCount = 0

        controller.start(
            isLocalClickOutside: { _ in false },
            onDismiss: { dismissCount += 1 }
        )
        monitor.sendGlobalMouseDown()

        #expect(dismissCount == 1)
    }

    @Test
    func localMouseDownDismissesOnlyOutsideWindows() {
        let monitor = FakePopoverMouseMonitor()
        let controller = PopoverDismissalController(monitor: monitor)
        let popoverWindow = NSWindow()
        let outsideWindow = NSWindow()
        var dismissCount = 0

        controller.start(
            isLocalClickOutside: { $0 === outsideWindow },
            onDismiss: { dismissCount += 1 }
        )
        monitor.sendLocalMouseDown(window: popoverWindow)
        #expect(dismissCount == 0)

        monitor.sendLocalMouseDown(window: outsideWindow)
        #expect(dismissCount == 1)
    }

    @Test
    func repeatedStartCreatesOnlyOneMonitorPair() {
        let monitor = FakePopoverMouseMonitor()
        let controller = PopoverDismissalController(monitor: monitor)

        controller.start(
            isLocalClickOutside: { _ in true },
            onDismiss: {}
        )
        controller.start(
            isLocalClickOutside: { _ in true },
            onDismiss: {}
        )

        #expect(monitor.localRegistrationCount == 1)
        #expect(monitor.globalRegistrationCount == 1)
    }

    @Test
    func stopRemovesBothMonitorTokens() {
        let monitor = FakePopoverMouseMonitor()
        let controller = PopoverDismissalController(monitor: monitor)

        controller.start(
            isLocalClickOutside: { _ in true },
            onDismiss: {}
        )
        controller.stop()

        #expect(monitor.removedTokenCount == 2)
        #expect(!controller.isMonitoring)
    }
}

@MainActor
private final class FakePopoverMouseMonitor: PopoverMouseMonitoring {
    private final class Token {}

    private var localHandler: ((NSWindow?) -> Void)?
    private var globalHandler: (() -> Void)?
    private(set) var localRegistrationCount = 0
    private(set) var globalRegistrationCount = 0
    private(set) var removedTokenCount = 0

    func addLocalMouseDownMonitor(
        _ handler: @escaping @MainActor (NSWindow?) -> Void
    ) -> Any? {
        localRegistrationCount += 1
        localHandler = handler
        return Token()
    }

    func addGlobalMouseDownMonitor(
        _ handler: @escaping @MainActor () -> Void
    ) -> Any? {
        globalRegistrationCount += 1
        globalHandler = handler
        return Token()
    }

    func removeMonitor(_ token: Any) {
        removedTokenCount += 1
    }

    func sendLocalMouseDown(window: NSWindow?) {
        localHandler?(window)
    }

    func sendGlobalMouseDown() {
        globalHandler?()
    }
}
