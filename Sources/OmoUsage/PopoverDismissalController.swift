import AppKit

@MainActor
protocol PopoverMouseMonitoring: AnyObject {
    func addLocalMouseDownMonitor(
        _ handler: @escaping @MainActor (NSWindow?) -> Void
    ) -> Any?

    func addGlobalMouseDownMonitor(
        _ handler: @escaping @MainActor () -> Void
    ) -> Any?

    func removeMonitor(_ token: Any)
}

@MainActor
final class AppKitPopoverMouseMonitor: PopoverMouseMonitoring {
    func addLocalMouseDownMonitor(
        _ handler: @escaping @MainActor (NSWindow?) -> Void
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            let window = event.window
            Task { @MainActor in
                handler(window)
            }
            return event
        }
    }

    func addGlobalMouseDownMonitor(
        _ handler: @escaping @MainActor () -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
    }

    func removeMonitor(_ token: Any) {
        NSEvent.removeMonitor(token)
    }
}

@MainActor
final class PopoverDismissalController {
    private let monitor: any PopoverMouseMonitoring
    private var localToken: Any?
    private var globalToken: Any?

    init(monitor: any PopoverMouseMonitoring) {
        self.monitor = monitor
    }

    var isMonitoring: Bool {
        localToken != nil || globalToken != nil
    }

    func start(
        isLocalClickOutside: @escaping @MainActor (NSWindow?) -> Bool,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        guard !isMonitoring else { return }

        localToken = monitor.addLocalMouseDownMonitor { window in
            guard isLocalClickOutside(window) else { return }
            onDismiss()
        }
        globalToken = monitor.addGlobalMouseDownMonitor {
            onDismiss()
        }
    }

    func stop() {
        if let localToken {
            monitor.removeMonitor(localToken)
        }
        if let globalToken {
            monitor.removeMonitor(globalToken)
        }
        localToken = nil
        globalToken = nil
    }
}
