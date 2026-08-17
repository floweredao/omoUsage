import AppKit
import SwiftUI

enum StatusPanelPresentationContract {
    static let usesNativePopover = true
    static let drawsCustomPointer = false
    static let preferredEdge: NSRectEdge = .minY
    static let behavior: NSPopover.Behavior = .transient
}

enum AppAppearancePolicy {
    @MainActor
    static func followSystem(on window: NSWindow) {
        window.appearance = nil
    }
}

@MainActor
enum StatusPopoverWindowStabilizer {
    private static var observations: [
        ObjectIdentifier: StatusPopoverWindowObservation
    ] = [:]

    static func detachFromMovingAnchor(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        let observation: StatusPopoverWindowObservation
        if let existing = observations[identifier] {
            observation = existing
        } else {
            observation = StatusPopoverWindowObservation(window: window)
            observations[identifier] = observation
        }
        observation.stabilize()
    }

    static func stopStabilizing(_ window: NSWindow) {
        observations.removeValue(forKey: ObjectIdentifier(window))?.stop()
    }
}

@MainActor
private final class StatusPopoverWindowObservation: NSObject {
    private weak var window: NSWindow?
    private var stableFrame: NSRect

    init(window: NSWindow) {
        self.window = window
        stableFrame = window.frame
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    func stabilize() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        if window.frame != stableFrame {
            window.setFrame(stableFrame, display: false)
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func windowDidMove() {
        guard let window else { return }
        if window.parent == nil {
            stableFrame.origin = window.frame.origin
        } else {
            stabilize()
        }
    }

    @objc
    private func windowDidResize() {
        guard let window, window.parent == nil else { return }
        stableFrame = window.frame
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let viewModel: UsageDashboardViewModel
    private let localization: LocalizationController
    private let snapshotSync: UbiquitousUsageSnapshotStore
    private var statusItem: NSStatusItem!
    private let statusPopover = NSPopover()
    private let dismissalController = PopoverDismissalController(
        monitor: AppKitPopoverMouseMonitor()
    )
    private lazy var refreshScheduler = UsageRefreshScheduler {
        [weak self] in
        await self?.viewModel.refresh()
    }
    private var settingsWindow: NSWindow?
    private weak var stabilizedPopoverWindow: NSWindow?
    private var popoverHeight = DashboardLayout.panelHeight(for: [])

    override init() {
        let snapshotSync = UbiquitousUsageSnapshotStore()
        self.snapshotSync = snapshotSync
        localization = LocalizationController(
            store: AppLanguageStore(defaults: .standard)
        )
        let orderStore = ProviderDisplayOrderStore(
            defaults: .standard
        )
        let disconnectionStore = ProviderDisconnectionStore(
            defaults: .standard
        )
        viewModel = UsageDashboardViewModel(
            providers: ProviderFactory.current(),
            providerOrder: orderStore.load(),
            persistProviderOrder: orderStore.save,
            disconnectedProviders: disconnectionStore.load(),
            persistDisconnectedProviders: disconnectionStore.save,
            publishSnapshot: { snapshot in
                do {
                    try snapshotSync.publish(snapshot)
                } catch {
                    NSLog(
                        "OmoUsage iCloud snapshot publish failed: %@",
                        String(describing: error)
                    )
                }
            }
        )
        super.init()
    }

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureStatusPopover()

        refreshScheduler.start()

        if
            ProcessInfo.processInfo.environment[
                "OMO_USAGE_OPEN_ON_LAUNCH"
            ] == "1"
        {
            DispatchQueue.main.async { [weak self] in
                self?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dismissalController.stop()
        refreshScheduler.stop()
        stopStabilizingPopoverWindow()
        statusPopover.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func popoverDidClose(_ notification: Notification) {
        dismissalController.stop()
        stopStabilizingPopoverWindow()
        statusItem.button?.highlight(false)
    }

    func popoverDidShow(_ notification: Notification) {
        guard
            let button = statusItem.button,
            let window = statusPopover.contentViewController?.view.window
        else {
            return
        }
        AppAppearancePolicy.followSystem(on: window)
        StatusPopoverWindowStabilizer.detachFromMovingAnchor(window)
        stabilizedPopoverWindow = window
        let statusWindow = button.window
        dismissalController.start(
            isLocalClickOutside: { eventWindow in
                guard let eventWindow else { return true }
                return eventWindow !== window
                    && eventWindow !== statusWindow
            },
            onDismiss: { [weak self] in
                self?.statusPopover.close()
            }
        )
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        guard let button = statusItem.button else { return }
        button.image = AppIconFactory.menuBarIcon()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover)
        applyLocalization()
    }

    private func configureStatusPopover() {
        statusPopover.behavior =
            StatusPanelPresentationContract.behavior
        statusPopover.delegate = self
        statusPopover.contentSize = NSSize(
            width: 320,
            height: popoverHeight
        )
        statusPopover.contentViewController = NSHostingController(
            rootView: DashboardView(
                viewModel: viewModel,
                localization: localization,
                onSettings: { [weak self] in
                    self?.showSettings()
                },
                onQuit: {
                    NSApp.terminate(nil)
                },
                onPanelHeightChange: { [weak self] height in
                    self?.resizePopover(to: height)
                }
            )
        )
    }

    @objc
    private func togglePopover() {
        if statusPopover.isShown {
            statusPopover.performClose(statusItem.button)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popoverHeight = DashboardLayout.panelHeight(
            for: viewModel.snapshot.providers
        )
        statusPopover.contentSize = NSSize(
            width: 320,
            height: popoverHeight
        )
        statusPopover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge:
                StatusPanelPresentationContract.preferredEdge
        )
        button.highlight(true)
        if let window = statusPopover.contentViewController?.view.window {
            AppAppearancePolicy.followSystem(on: window)
        }
    }

    private func resizePopover(to height: CGFloat) {
        guard abs(popoverHeight - height) > 0.5 else { return }
        popoverHeight = height
        statusPopover.contentSize = NSSize(width: 320, height: height)
    }

    private func showSettings() {
        statusPopover.performClose(statusItem.button)

        if let settingsWindow {
            AppAppearancePolicy.followSystem(on: settingsWindow)
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: SettingsView(
                viewModel: viewModel,
                localization: localization,
                onLanguageChange: { [weak self] in
                    self?.applyLocalization()
                }
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.title = localization.text(.settingsTitle)
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 620))
        window.center()
        AppAppearancePolicy.followSystem(on: window)
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyLocalization() {
        let title = localization.text(.aiUsage)
        statusItem?.button?.toolTip = title
        statusItem?.button?.setAccessibilityLabel(title)
        settingsWindow?.title = localization.text(.settingsTitle)
    }

    private func stopStabilizingPopoverWindow() {
        guard let window = stabilizedPopoverWindow else { return }
        StatusPopoverWindowStabilizer.stopStabilizing(window)
        stabilizedPopoverWindow = nil
    }
}
