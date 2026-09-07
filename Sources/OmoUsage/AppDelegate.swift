import OmoUsageCore
import AppKit
import Security
import SwiftUI

#if OMO_USAGE_FIXTURES
/// Isolated registry, Keychain, credential source, and companion launch
/// used by companion-account QA. Every path lives under a caller-supplied
/// temporary root, so QA can never read or write the real account
/// registry, the real Keychain, or start a real companion login.
struct CompanionAccountFixture {
    static let rootPrefix = "/tmp/omousage-companion-qa-"
    static let headlessKey = "OMO_USAGE_COMPANION_ACCOUNT_QA"
    static let userInterfaceKey = "OMO_USAGE_COMPANION_ACCOUNT_UI_QA"
    static let claudeAuthenticationUIKey = "OMO_USAGE_CLAUDE_AUTH_UI_QA"
    static let rootKey = "OMO_USAGE_COMPANION_ACCOUNT_QA_ROOT"

    let root: URL
    let defaults: UserDefaults
    let keychain: any ProviderKeychain

    static func resolve(
        requestKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CompanionAccountFixture? {
        guard
            environment[requestKey] == "1",
            let path = environment[rootKey],
            path.hasPrefix(rootPrefix),
            !path.contains("..")
        else {
            return nil
        }
        let root = URL(filePath: path, directoryHint: .isDirectory)
        guard
            let defaults = UserDefaults(
                suiteName: suiteName(forRootPath: path)
            )
        else {
            return nil
        }
        return CompanionAccountFixture(
            root: root,
            defaults: defaults,
            keychain: CompanionAccountFixtureKeychain(
                directory: root.appending(
                    path: "keychain",
                    directoryHint: .isDirectory
                )
            )
        )
    }

    static func suiteName(forRootPath path: String) -> String {
        "CompanionAccountQA-\(URL(filePath: path).lastPathComponent)"
    }

    var registryURL: URL { root.appending(path: "accounts.json") }
    var launchLogURL: URL { root.appending(path: "launch-log.txt") }
    var accountRegistryRefreshCountURL: URL {
        root.appending(path: "account-registry-refresh-count")
    }
    var claudeAuthorizationCountURL: URL {
        root.appending(path: "claude-authorization-count")
    }
    var claudeLoginCommandURL: URL {
        root.appending(path: "claude-login.command")
    }

    func credentialURL(for provider: ProviderID) -> URL {
        root.appending(path: "credential-\(provider.rawValue).token")
    }

    func accountStore() -> ProviderAccountStore {
        ProviderAccountStore(
            registryURL: registryURL,
            defaults: defaults,
            // Include an API-key row so native account-form QA covers
            // both authentication styles without reading a real key.
            legacyAPIKeyPresence: { $0 == .openrouter }
        )
    }

    func keyStore(
        _ provider: ProviderID,
        _ accountID: AccountID
    ) -> ProviderAPIKeyStore? {
        ProviderAPIKeyStore.live(
            for: provider,
            accountID: accountID,
            home: root.appending(path: "home", directoryHint: .isDirectory),
            environment: [:],
            keychain: keychain
        )
    }

    /// Mirrors the live capture contract: the token file stands in for
    /// whichever credential the companion tool currently holds.
    func captureCredential(for provider: ProviderID) throws -> String {
        guard
            let data = try? Data(contentsOf: credentialURL(for: provider)),
            let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            throw CredentialDiscoveryError.notFound(provider)
        }
        return try CredentialSnapshot(
            provider: provider,
            accessToken: token,
            refreshToken: nil,
            accountReference: token,
            planName: "QA Plan",
            expiresAt: nil,
            source: .file
        ).encodedSecret()
    }

    /// Records only refreshes initiated after the registry changes, and
    /// only after that refresh has completed. The count stays inside the
    /// caller-confined fixture root and contains no account or secret data.
    func recordAccountRegistryRefreshCompletion() throws {
        let current = Int(
            (try? String(
                contentsOf: accountRegistryRefreshCountURL,
                encoding: .utf8
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        ) ?? 0
        try ProviderFileDurability.atomicWrite(
            Data("\(current + 1)\n".utf8),
            to: accountRegistryRefreshCountURL,
            permissions: 0o600
        )
    }

    func launchCompanion(
        _ provider: ProviderID
    ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
        let line = "launched:\(provider.rawValue)\n"
        if let handle = try? FileHandle(forWritingTo: launchLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: launchLogURL, options: .atomic)
        }
        return .success(.launched)
    }

    /// This narrower fixture is available only after the companion fixture
    /// root has passed its isolation checks. It shares the fixture's file
    /// Keychain but never opens the user's Keychain or a real login command.
    func claudeAuthenticationUIFixture(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeAuthenticationUIFixture? {
        guard environment[Self.claudeAuthenticationUIKey] == "1" else {
            return nil
        }
        return ClaudeAuthenticationUIFixture(fixture: self)
    }

    final class ClaudeAuthenticationUIFixture: @unchecked Sendable {
        private let fixture: CompanionAccountFixture
        private let session: ClaudeKeychainAccessSession

        init(fixture: CompanionAccountFixture) {
            self.fixture = fixture
            session = ClaudeKeychainAccessSession(
                providerKeychain: fixture.keychain
            )
        }

        func authorizeClaude() throws -> ClaudeKeychainAuthorizationOutcome {
            try recordAuthorization()
            return try session.authorizeClaude(
                api: CompanionClaudeCredentialFileSecurityItemAPI(
                    credentialURL: fixture.credentialURL(for: .claude)
                )
            )
        }

        func launchClaudeLogin(
            receipt: OfficialLoginReceipt
        ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
            do {
                try ProviderFileDurability.atomicWrite(
                    Data("#!/bin/zsh\n\(receipt.wrapping(":"))\n".utf8),
                    to: fixture.claudeLoginCommandURL,
                    permissions: 0o700
                )
                return .success(.launched)
            } catch {
                return .failure(.unableToLaunch("claude"))
            }
        }

        func fixtureUsageProviders(
            registry: ProviderAccountRegistry
        ) -> [any UsageProvider] {
            let references = Set(registry.providerReferences)
            return ProviderID.allCases.flatMap { provider in
                registry.accounts.compactMap { account in
                    let identity = AccountProviderID(
                        accountID: account.id,
                        providerID: provider
                    )
                    guard references.contains(identity) else { return nil }
                    return FixtureUsageProvider(
                        id: provider,
                        accountID: account.id,
                        accountLabel: account.label,
                        claudeCredentialDiscovery: provider == .claude
                            ? credentialDiscovery()
                            : nil
                    )
                }
            }
        }

        private func credentialDiscovery() -> CredentialDiscovery {
            CredentialDiscovery(
                paths: CredentialPaths(
                    claude: fixture.root.appending(
                        components: "home", ".claude", ".credentials.json"
                    ),
                    codex: fixture.root.appending(
                        components: "home", ".codex", "auth.json"
                    )
                ),
                environment: [:],
                keychain: SecurityKeychainReader(
                    api: CompanionClaudeCredentialFileSecurityItemAPI(
                        credentialURL: fixture.credentialURL(for: .claude)
                    ),
                    claudeSession: session
                ),
                providerKeychain: fixture.keychain,
                homeDirectory: fixture.root.appending(
                    path: "home",
                    directoryHint: .isDirectory
                ),
                commandPaths: []
            )
        }

        private func recordAuthorization() throws {
            let current = Int(
                (try? String(
                    contentsOf: fixture.claudeAuthorizationCountURL,
                    encoding: .utf8
                ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            ) ?? 0
            try ProviderFileDurability.atomicWrite(
                Data("\(current + 1)\n".utf8),
                to: fixture.claudeAuthorizationCountURL,
                permissions: 0o600
            )
        }
    }
}

/// The fixture credential file is the only authorization source for the
/// narrow Claude UI QA path. Its SecurityItemAPI shape lets the real session
/// copy that credential into its app-owned file Keychain mirror.
private struct CompanionClaudeCredentialFileSecurityItemAPI: SecurityItemAPI {
    let credentialURL: URL

    func copyMatching(_ query: [String: Any]) -> SecurityItemCopyResult {
        guard
            let service = query[kSecAttrService as String] as? String,
            CredentialDiscovery.claudeKeychainServices.contains(service),
            let data = try? Data(contentsOf: credentialURL),
            !data.isEmpty
        else {
            return SecurityItemCopyResult(
                status: errSecItemNotFound,
                value: nil
            )
        }
        return SecurityItemCopyResult(status: errSecSuccess, value: data)
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        errSecUnimplemented
    }
}

final class CompanionAccountFixtureKeychain: ProviderKeychain,
    @unchecked Sendable
{
    let directory: URL

    init(directory: URL) { self.directory = directory }

    func value(service: String, account: String) throws -> String? {
        let url = itemURL(service: service, account: account)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return String(data: try Data(contentsOf: url), encoding: .utf8)
    }

    func set(_ value: String, service: String, account: String) throws {
        try ProviderFileDurability.preparePrivateDirectory(directory)
        try ProviderFileDurability.atomicWrite(
            Data(value.utf8),
            to: itemURL(service: service, account: account),
            permissions: 0o600
        )
    }

    func remove(service: String, account: String) throws {
        try ProviderFileDurability.removeIfPresent(
            itemURL(service: service, account: account)
        )
    }

    var storedItemCount: Int {
        (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ))?.count ?? 0
    }

    private func itemURL(service: String, account: String) -> URL {
        let name = "\(service)|\(account)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return directory.appending(path: name)
    }
}
#endif

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
        window.standardWindowButton(.zoomButton)?.isHidden = true
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
    private let companionCapture: (ProviderID) throws -> String
    private let companionLaunch: (ProviderID) -> Result<
        ProviderSetupOutcome,
        ProviderSetupError
    >
#if OMO_USAGE_FIXTURES
    private let companionFixture: CompanionAccountFixture?
    private let claudeAuthenticationFixture:
        CompanionAccountFixture.ClaudeAuthenticationUIFixture?
#endif
    private let opensSettingsOnLaunch: Bool
    private let snapshotSync: UbiquitousUsageSnapshotStore
    private let webDashboardSnapshotStore: WebDashboardSnapshotStore
    private let webDashboardSettingsStore: WebDashboardSettingsStore
    private let webDashboardLanguageStore: WebDashboardLanguageStore
    private let webDashboardCommandBridge: WebDashboardCommandBridge
    private let webDashboardAccessStore: WebDashboardAccessStore
    private let webDashboardStatusStore: WebDashboardStatusStore
    private let webDashboardServer: WebDashboardServer
    private let tailscaleDashboardController: TailscaleDashboardController
    private let presentationStyleStore: DashboardPresentationStyleStore
    private var presentationStyle: DashboardPresentationStyle
    private let sideNotchHideDelayStore: SideNotchHideDelayStore
    private var sideNotchHideDelay: SideNotchHideDelay
    private var statusItem: NSStatusItem!
    private let statusPopover = NSPopover()
    private let dismissalController = PopoverDismissalController(
        monitor: AppKitPopoverMouseMonitor()
    )
    private var sharingServicePicker: NSSharingServicePicker?
    private lazy var refreshScheduler = UsageRefreshScheduler {
        [weak self] in
        await self?.viewModel.refresh()
    }
    private var settingsWindow: NSWindow?
    private weak var stabilizedPopoverWindow: NSWindow?
    private var hasFinishedLaunching = false
    private var hasPendingSecondaryActivation = false
    private var popoverHeight = DashboardLayout.panelHeight(for: [])
    private lazy var sideNotchController = SideNotchPanelController(
        viewModel: viewModel,
        localization: localization,
        autoHideDelay: sideNotchHideDelay.rawValue,
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
#if OMO_USAGE_FIXTURES
        let fixtureEnvironment = ProcessInfo.processInfo.environment
        let companionFixture = CompanionAccountFixture.resolve(
            requestKey: CompanionAccountFixture.userInterfaceKey,
            environment: fixtureEnvironment
        )
        let claudeAuthenticationFixture = companionFixture?
            .claudeAuthenticationUIFixture(environment: fixtureEnvironment)
        let defaults = companionFixture?.defaults ?? .standard
#else
        let defaults = UserDefaults.standard
#endif
        let snapshotSync = UbiquitousUsageSnapshotStore()
        let localization = LocalizationController(
            store: AppLanguageStore(defaults: defaults)
        )
        let webDashboardLanguageStore = WebDashboardLanguageStore(
            defaults: defaults,
            fallback: localization.language
        )
        let webLanguage = webDashboardLanguageStore.load()
        webDashboardLanguageStore.save(webLanguage)
        let orderStore = ProviderDisplayOrderStore(
            defaults: defaults
        )
        let disconnectionStore = ProviderDisconnectionStore(
            defaults: defaults
        )
        let presentationStyleStore = DashboardPresentationStyleStore(
            defaults: defaults
        )
        let presentationStyle = presentationStyleStore.load()
        let sideNotchHideDelayStore = SideNotchHideDelayStore(
            defaults: defaults
        )
        let sideNotchHideDelay = sideNotchHideDelayStore.load()
        let providerOrder = orderStore.load()
        let disconnectedProviders = disconnectionStore.load()
#if OMO_USAGE_FIXTURES
        let accountStore = companionFixture?.accountStore()
            ?? ProviderAccountStore.live(defaults: defaults)
#else
        let accountStore = ProviderAccountStore.live(defaults: defaults)
#endif
        let registryLoadResult = ProviderMutationCoordinator(
            store: accountStore
        ).loadOrRecover()
        switch registryLoadResult.state {
        case .ready:
            break
        case .recoveredFromBackup:
            DiagnosticStore.shared.record(
                DiagnosticEvent(
                    status: .recovered,
                    category: .accountRegistry
                )
            )
        case .blocked:
            DiagnosticStore.shared.record(
                DiagnosticEvent(
                    status: .blocked,
                    category: .accountRegistry
                )
            )
        }
#if OMO_USAGE_FIXTURES
        let accountRegistryController = companionFixture.map { fixture in
            ProviderAccountRegistryController(
                store: accountStore,
                loadResult: registryLoadResult,
                keyStore: fixture.keyStore,
                credentialSnapshotStore: {
                    ProviderCredentialSnapshotStore(
                        keychain: fixture.keychain
                    )
                }
            )
        } ?? ProviderAccountRegistryController(
            store: accountStore,
            loadResult: registryLoadResult
        )
        let companionCapture = companionFixture?.captureCredential
            ?? SettingsView.captureCompanionCredential
        let companionLaunch = companionFixture?.launchCompanion
            ?? { ProviderSetup.perform(for: $0) }
#else
        let accountRegistryController = ProviderAccountRegistryController(
            store: accountStore,
            loadResult: registryLoadResult
        )
        let companionCapture = SettingsView.captureCompanionCredential
        let companionLaunch: (ProviderID) -> Result<
            ProviderSetupOutcome,
            ProviderSetupError
        > = { ProviderSetup.perform(for: $0) }
#endif
#if OMO_USAGE_FIXTURES
        let accountComposition = AppAccountCompositionFactory.make(
            registry: registryLoadResult.registry,
            providerFactory: { registry in
                claudeAuthenticationFixture?.fixtureUsageProviders(
                    registry: registry
                ) ?? ProviderFactory.current(registry: registry)
            }
        )
#else
        let accountComposition = AppAccountCompositionFactory.make(
            registry: registryLoadResult.registry
        )
#endif
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
        let environment = ProcessInfo.processInfo.environment
        let webDashboardPort = WebDashboardPortPolicy.resolve(
            environment: environment
        )
        let webDashboardAccessStore = WebDashboardAccessStore(
            mode: WebDashboardAccessMode.resolve(
                environment: environment,
                port: webDashboardPort
            )
        )
        let webDashboardStatusStore = WebDashboardStatusStore(
            port: webDashboardPort
        )
        webDashboardStatusStore.publishAccessMode(
            webDashboardAccessStore.mode
        )
        let tailscaleDashboardController = TailscaleDashboardController(
            service: TailscaleDashboardServiceFactory.current(
                environment: environment
            ),
            dashboardPort: webDashboardPort,
            accessStore: webDashboardAccessStore,
            statusStore: webDashboardStatusStore
        )
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
                    DiagnosticStore.shared.record(
                        error: error,
                        category: .accountOrderPersistence
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
                    DiagnosticStore.shared.record(
                        error: error,
                        category: .accountVisibilityPersistence
                    )
                }
            },
            publishSnapshot: { snapshot in
                webDashboardSnapshotStore.update(snapshot)
                do {
                    try snapshotSync.publish(snapshot)
                } catch {
                    DiagnosticStore.shared.record(
                        error: error,
                        category: .snapshotPublish
                    )
                }
            },
            publishControlState: webDashboardSettingsStore.update
        )
        let webDashboardServer = WebDashboardServer(
            listener: NWWebDashboardListener(port: webDashboardPort),
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
            ),
            accessStore: webDashboardAccessStore,
            statusStore: webDashboardStatusStore
        )

        self.viewModel = viewModel
        self.localization = localization
        self.accountRegistryController = accountRegistryController
        self.companionCapture = companionCapture
        self.companionLaunch = companionLaunch
#if OMO_USAGE_FIXTURES
        self.companionFixture = companionFixture
        self.claudeAuthenticationFixture = claudeAuthenticationFixture
        self.opensSettingsOnLaunch = companionFixture != nil
#else
        self.opensSettingsOnLaunch = false
#endif
        self.snapshotSync = snapshotSync
        self.webDashboardSnapshotStore = webDashboardSnapshotStore
        self.webDashboardSettingsStore = webDashboardSettingsStore
        self.webDashboardLanguageStore = webDashboardLanguageStore
        self.webDashboardCommandBridge = webDashboardCommandBridge
        self.webDashboardAccessStore = webDashboardAccessStore
        self.webDashboardStatusStore = webDashboardStatusStore
        self.webDashboardServer = webDashboardServer
        self.tailscaleDashboardController =
            tailscaleDashboardController
        self.presentationStyleStore = presentationStyleStore
        self.presentationStyle = presentationStyle
        self.sideNotchHideDelayStore = sideNotchHideDelayStore
        self.sideNotchHideDelay = sideNotchHideDelay
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
            DiagnosticStore.shared.record(
                error: error,
                category: .webServer
            )
        }
        Task {
            await tailscaleDashboardController.refresh()
            do {
                try FixtureWebDashboardURLExporter.exportIfRequested(
                    accessStore: webDashboardAccessStore
                )
            } catch {
                DiagnosticStore.shared.record(
                    error: error,
                    category: .webServer
                )
            }
        }

        hasFinishedLaunching = true
        if opensSettingsOnLaunch {
            DispatchQueue.main.async { [weak self] in
                self?.showSettings()
            }
        }
        if
            hasPendingSecondaryActivation
                || ProcessInfo.processInfo.environment[
                    "OMO_USAGE_OPEN_ON_LAUNCH"
                ] == "1"
        {
            hasPendingSecondaryActivation = false
            DispatchQueue.main.async { [weak self] in
                self?.showSelectedPresentation()
            }
        }
    }

    func activateFromSecondaryLaunch() {
        guard hasFinishedLaunching else {
            hasPendingSecondaryActivation = true
            return
        }
        showSelectedPresentation()
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
            sideNotchController.toggleRevealed(
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

#if OMO_USAGE_FIXTURES
        let fixture = claudeAuthenticationFixture
        let authorizeClaude: () throws -> ClaudeKeychainAuthorizationOutcome = {
            guard let fixture else {
                return try ClaudeKeychainAccessSession.shared.authorizeClaude()
            }
            return try fixture.authorizeClaude()
        }
        let launchClaudeLogin: (OfficialLoginReceipt) -> Result<
            ProviderSetupOutcome, ProviderSetupError
        > = { receipt in
            guard let fixture else {
                return ProviderSetup.performClaudeLogin(receipt: receipt)
            }
            return fixture.launchClaudeLogin(receipt: receipt)
        }
#else
        let authorizeClaude: () throws -> ClaudeKeychainAuthorizationOutcome = {
            try ClaudeKeychainAccessSession.shared.authorizeClaude()
        }
        let launchClaudeLogin: (OfficialLoginReceipt) -> Result<
            ProviderSetupOutcome, ProviderSetupError
        > = { ProviderSetup.performClaudeLogin(receipt: $0) }
#endif
        let controller = NSHostingController(
            rootView: SettingsView(
                viewModel: viewModel,
                localization: localization,
                presentationStyle: presentationStyle,
                sideNotchHideDelay: sideNotchHideDelay,
                accountRegistryController: accountRegistryController,
                captureCompanionCredential: companionCapture,
                launchCompanion: companionLaunch,
                authorizeClaude: authorizeClaude,
                launchClaudeLogin: launchClaudeLogin,
                onRegistryChange: { [weak self] in
                    self?.applyAccountRegistryChange()
                },
                onLanguageChange: { [weak self] in
                    self?.applyLocalization()
                },
                onPresentationStyleChange: { [weak self] style in
                    self?.setPresentationStyle(style)
                },
                onSideNotchHideDelayChange: { [weak self] delay in
                    self?.setSideNotchHideDelay(delay)
                },
                webDashboardStatusStore: webDashboardStatusStore,
                tailscaleDashboardController:
                    tailscaleDashboardController,
                onOpenWebDashboard: { [weak self] in
                    guard let self else { return false }
                    return NSWorkspace.shared.open(
                        self.webDashboardAccessStore.dashboardURL
                    )
                },
                onCreateWebDashboardURL: { [weak self] in
                    guard let self else { return nil }
                    return self.webDashboardAccessStore.dashboardURL
                },
                onShareWebDashboardURL: {
                    [weak self] url,
                    anchorView in
                    self?.presentSharingPicker(
                        for: url,
                        relativeTo: anchorView
                    ) == true
                },
                onRetryWebDashboard: { [weak self] in
                    guard let self else { return }
                    do {
                        try self.webDashboardServer.retry()
                    } catch {
                        DiagnosticStore.shared.record(
                            error: error,
                            category: .webServer
                        )
                    }
                },
                onExportDiagnostics: {
                    let action = DiagnosticExportAction(
                        store: .shared,
                        chooseDestination: {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "OmoUsage-diagnostics.json"
                            panel.canCreateDirectories = true
                            return panel.runModal() == .OK ? panel.url : nil
                        }
                    )
                    switch action.perform() {
                    case .success(.some):
                        return .exported
                    case .success(.none):
                        return .cancelled
                    case .failure:
                        return .failed
                    }
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

    private func presentSharingPicker(
        for url: URL,
        relativeTo anchorView: NSView
    ) -> Bool {
        guard anchorView.window === settingsWindow else {
            return false
        }
        let picker = NSSharingServicePicker(items: [url])
        sharingServicePicker = picker
        picker.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .maxX
        )
        return true
    }

    private func applyAccountRegistryChange() {
#if OMO_USAGE_FIXTURES
        let composition = AppAccountCompositionFactory.make(
            registry: accountRegistryController.registry,
            providerFactory: { [claudeAuthenticationFixture] registry in
                claudeAuthenticationFixture?.fixtureUsageProviders(
                    registry: registry
                ) ?? ProviderFactory.current(registry: registry)
            }
        )
#else
        let composition = AppAccountCompositionFactory.make(
            registry: accountRegistryController.registry
        )
#endif
        viewModel.updateProviders(
            composition.providers,
            accountProviderOrder: composition.accountProviderOrder,
            disconnected: composition.disconnected
        )
        Task { [weak self] in
            guard let self else { return }
            await viewModel.refresh()
#if OMO_USAGE_FIXTURES
            do {
                try companionFixture?.recordAccountRegistryRefreshCompletion()
            } catch {
                DiagnosticStore.shared.record(
                    error: error,
                    category: .fixture
                )
            }
#endif
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

    private func setSideNotchHideDelay(
        _ delay: SideNotchHideDelay
    ) {
        guard sideNotchHideDelay != delay else { return }
        sideNotchHideDelay = delay
        sideNotchHideDelayStore.save(delay)
        sideNotchController.setAutoHideDelay(delay.rawValue)
    }

    private func showSelectedPresentation() {
        switch presentationStyle {
        case .popover:
            if !statusPopover.isShown {
                showPopover()
            }
        case .sideNotch:
            showSideNotch()
            sideNotchController.toggleRevealed(
                preferredScreen: statusItem.button?.window?.screen
            )
        }
        NSApp.activate(ignoringOtherApps: true)
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
