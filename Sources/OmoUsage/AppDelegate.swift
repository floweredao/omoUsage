import AppKit
import SwiftUI

enum SettingsWindowContract {
    static let styleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .resizable
    ]

    @MainActor
    static func apply(to window: NSWindow) {
        window.styleMask = styleMask
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    }
}

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
    private let accountRegistryController: ProviderAccountRegistryController
    private let snapshotSync: UbiquitousUsageSnapshotStore
    private let webDashboardSnapshotStore: WebDashboardSnapshotStore
    private let webDashboardSettingsStore: WebDashboardSettingsStore
    private let webDashboardLanguageStore: WebDashboardLanguageStore
    private let webDashboardCommandBridge: WebDashboardCommandBridge
    private let webDashboardServer: WebDashboardServer
    private let presentationStyleStore: DashboardPresentationStyleStore
    private var presentationStyle: DashboardPresentationStyle
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
    private lazy var sideNotchController = SideNotchPanelController(
        viewModel: viewModel,
        localization: localization,
        onExpansionChange: { [weak self] isExpanded in
            self?.statusItem.button?.highlight(isExpanded)
        },
        onSettings: { [weak self] in
            self?.showSettings()
        },
        onQuit: {
            NSApp.terminate(nil)
        }
    )

    override init() {
        let snapshotSync = UbiquitousUsageSnapshotStore()
        let localization = LocalizationController(
            store: AppLanguageStore(defaults: .standard)
        )
        let webDashboardLanguageStore = WebDashboardLanguageStore(
            defaults: .standard,
            fallback: localization.language
        )
        let webLanguage = webDashboardLanguageStore.load()
        webDashboardLanguageStore.save(webLanguage)
        let orderStore = ProviderDisplayOrderStore(
            defaults: .standard
        )
        let disconnectionStore = ProviderDisconnectionStore(
            defaults: .standard
        )
        let presentationStyleStore = DashboardPresentationStyleStore(
            defaults: .standard
        )
        let presentationStyle = presentationStyleStore.load()
        let providerOrder = orderStore.load()
        let disconnectedProviders = disconnectionStore.load()
        let accountStore = ProviderAccountStore.live(defaults: .standard)
        let registry: ProviderAccountRegistry
        let registryPersistenceEnabled: Bool
        do {
            registry = try accountStore.loadOrMigrate()
            registryPersistenceEnabled = true
        } catch {
            NSLog(
                "OmoUsage account registry unavailable (%@)",
                String(reflecting: type(of: error))
            )
            registry = AppAccountCompositionFactory
                .deterministicLegacyRegistry(
                    providerOrder: providerOrder,
                    disconnectedProviders: disconnectedProviders
                )
            registryPersistenceEnabled = false
        }
        let accountRegistryController = ProviderAccountRegistryController(
            store: accountStore,
            registry: registry,
            persistenceEnabled: registryPersistenceEnabled
        )
        let accountComposition = AppAccountCompositionFactory.make(
            registry: registry
        )
        let webDashboardSnapshotStore = WebDashboardSnapshotStore(
            DashboardSnapshot(
                providers: [],
                refreshedAt: Date()
            )
        )
        let webDashboardSettingsStore = WebDashboardSettingsStore(
            controlState: UsageDashboardControlState(
                providerOrder: providerOrder,
                disconnectedProviders: disconnectedProviders,
                accountProviderOrder:
                    accountComposition.accountProviderOrder,
                disconnectedAccountProviders:
                    accountComposition.disconnected,
                isRefreshing: false
            ),
            language: webLanguage
        )
        let webDashboardCommandBridge = WebDashboardCommandBridge()
        let mutationNonce = UUID().uuidString.replacingOccurrences(
            of: "-",
            with: ""
        )
        let viewModel = UsageDashboardViewModel(
            providers: accountComposition.providers,
            providerOrder: providerOrder,
            persistProviderOrder: orderStore.save,
            accountProviderOrder: accountComposition.accountProviderOrder,
            persistAccountProviderOrder: { order in
                do {
                    try accountRegistryController.saveOrder(order)
                } catch {
                    NSLog(
                        "OmoUsage account order persistence failed (%@)",
                        String(reflecting: type(of: error))
                    )
                }
            },
            disconnectedProviders: disconnectedProviders,
            disconnectedAccountProviders: accountComposition.disconnected,
            persistDisconnectedProviders: disconnectionStore.save,
            persistDisconnectedAccountProviders: { disconnected in
                do {
                    try accountRegistryController.saveDisconnected(
                        disconnected
                    )
                } catch {
                    NSLog(
                        "OmoUsage account disconnection persistence failed (%@)",
                        String(reflecting: type(of: error))
                    )
                }
            },
            publishSnapshot: { snapshot in
                webDashboardSnapshotStore.update(snapshot)
                do {
                    try snapshotSync.publish(snapshot)
                } catch {
                    NSLog(
                        "OmoUsage iCloud snapshot publish failed: %@",
                        String(describing: error)
                    )
                }
            },
            publishControlState: webDashboardSettingsStore.update
        )
        let webDashboardServer = WebDashboardServer(
            listener: NWWebDashboardListener(
                port: WebDashboardPortPolicy.resolve(
                    environment: ProcessInfo.processInfo.environment
                )
            ),
            router: WebDashboardRouter(
                snapshotData: {
                    let language = AppLanguage(
                        rawValue:
                            webDashboardSettingsStore.state().webLanguage
                    ) ?? .english
                    return try UsageSnapshotCodec.encode(
                        webDashboardSnapshotStore.snapshot().localized(
                            using: LocalizationContext(language: language)
                        )
                    )
                },
                settingsData: webDashboardSettingsStore.encoded,
                indexHTML: WebDashboardAssets.indexHTML(
                    mutationNonce: mutationNonce
                ),
                appIconSVG: WebDashboardAssets.appIconSVG,
                mutationNonce: mutationNonce,
                dispatchCommand: webDashboardCommandBridge.send
            )
        )

        self.viewModel = viewModel
        self.localization = localization
        self.accountRegistryController = accountRegistryController
        self.snapshotSync = snapshotSync
        self.webDashboardSnapshotStore = webDashboardSnapshotStore
        self.webDashboardSettingsStore = webDashboardSettingsStore
        self.webDashboardLanguageStore = webDashboardLanguageStore
        self.webDashboardCommandBridge = webDashboardCommandBridge
        self.webDashboardServer = webDashboardServer
        self.presentationStyleStore = presentationStyleStore
        self.presentationStyle = presentationStyle
        super.init()
        webDashboardCommandBridge.install { [weak self] command in
            self?.handleWebDashboardCommand(command)
        }
    }

    func applicationDidFinishLaunching(
        _ notification: Notification
    ) {
        configureStatusItem()
        configureStatusPopover()
        if presentationStyle == .sideNotch {
            DispatchQueue.main.async { [weak self] in
                self?.showSideNotch()
            }
        }

        refreshScheduler.start()
        do {
            try webDashboardServer.start()
        } catch {
            NSLog(
                "OmoUsage web dashboard start failed: %@",
                String(describing: error)
            )
        }

        if
            ProcessInfo.processInfo.environment[
                "OMO_USAGE_OPEN_ON_LAUNCH"
            ] == "1"
        {
            DispatchQueue.main.async { [weak self] in
                self?.showSelectedPresentation()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        webDashboardServer.stop()
        dismissalController.stop()
        refreshScheduler.stop()
        stopStabilizingPopoverWindow()
        sideNotchController.stop()
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
        button.action = #selector(toggleDashboardPresentation)
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
    private func toggleDashboardPresentation() {
        switch presentationStyle {
        case .popover:
            togglePopover()
        case .sideNotch:
            statusPopover.performClose(statusItem.button)
            sideNotchController.toggleExpanded(
                preferredScreen: statusItem.button?.window?.screen
            )
        }
    }

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
        sideNotchController.collapse(animated: false)

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
                presentationStyle: presentationStyle,
                accountRegistryController: accountRegistryController,
                onRegistryChange: { [weak self] in
                    self?.applyAccountRegistryChange()
                },
                onLanguageChange: { [weak self] in
                    self?.applyLocalization()
                },
                onPresentationStyleChange: { [weak self] style in
                    self?.setPresentationStyle(style)
                }
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.title = localization.text(.settingsTitle)
        SettingsWindowContract.apply(to: window)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 620))
        window.center()
        AppAppearancePolicy.followSystem(on: window)
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAccountRegistryChange() {
        let composition = AppAccountCompositionFactory.make(
            registry: accountRegistryController.registry
        )
        viewModel.updateProviders(
            composition.providers,
            accountProviderOrder: composition.accountProviderOrder,
            disconnected: composition.disconnected
        )
        Task { [weak self] in
            await self?.viewModel.refresh()
        }
    }

    private func applyLocalization() {
        let title = localization.text(.aiUsage)
        statusItem?.button?.toolTip = title
        statusItem?.button?.setAccessibilityLabel(title)
        settingsWindow?.title = localization.text(.settingsTitle)
    }

    private func setPresentationStyle(
        _ style: DashboardPresentationStyle
    ) {
        guard presentationStyle != style else { return }

        statusPopover.performClose(statusItem.button)
        sideNotchController.hide()
        presentationStyle = style
        presentationStyleStore.save(style)
        statusItem.button?.highlight(false)

        if style == .sideNotch {
            showSideNotch()
        }
    }

    private func showSelectedPresentation() {
        switch presentationStyle {
        case .popover:
            showPopover()
        case .sideNotch:
            showSideNotch()
        }
    }

    private func showSideNotch() {
        statusPopover.performClose(statusItem.button)
        sideNotchController.show(
            preferredScreen: statusItem.button?.window?.screen
        )
    }

    private func handleWebDashboardCommand(
        _ command: WebDashboardCommand
    ) {
        switch command {
        case .refresh:
            Task { [weak self] in
                await self?.viewModel.refresh()
            }
        case .setProviderOrder(let order):
            viewModel.setProviderOrder(order)
        case .setProviderVisibility(let provider, let isVisible):
            if isVisible {
                viewModel.reconnectProvider(provider)
                Task { [weak self] in
                    await self?.viewModel.refresh()
                }
            } else {
                viewModel.disconnectProvider(provider)
            }
        case .setAccountProviderOrder(let order):
            viewModel.setAccountProviderOrder(order)
        case .setAccountVisibility(let accountProvider, let isVisible):
            if isVisible {
                viewModel.reconnectAccountProvider(accountProvider)
                Task { [weak self] in
                    await self?.viewModel.refresh()
                }
            } else {
                viewModel.disconnectAccountProvider(accountProvider)
            }
        case .setWebLanguage(let language):
            webDashboardLanguageStore.save(language)
            webDashboardSettingsStore.update(webLanguage: language)
        }
    }

    private func stopStabilizingPopoverWindow() {
        guard let window = stabilizedPopoverWindow else { return }
        StatusPopoverWindowStabilizer.stopStabilizing(window)
        stabilizedPopoverWindow = nil
    }
}
