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
    static let accountSettingsUIKey = "OMO_USAGE_ACCOUNT_SETTINGS_UI_QA"
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
    var claudeBrowserAuthenticationCountURL: URL {
        root.appending(path: "claude-browser-authentication-count")
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

    func maskedIdentity(for identity: AccountProviderID) -> String? {
        guard let snapshot = try? ProviderCredentialSnapshotStore(keychain: keychain)
            .snapshot(for: identity)
        else { return nil }
        return snapshot.maskedIdentity
    }

    func accountSettingsProviders(
        registry: ProviderAccountRegistry,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any UsageProvider]? {
        guard environment[Self.accountSettingsUIKey] == "1" else { return nil }
        return registry.providerReferences.compactMap { identity in
            guard let account = registry.accounts.first(where: { $0.id == identity.accountID })
            else { return nil }
            return FixtureUsageProvider(
                id: identity.providerID,
                accountID: identity.accountID,
                accountLabel: account.label(for: identity.providerID),
                defaults: defaults,
                codexReportedPlan: "pro"
            )
        }
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

    /// Stands in for the in-app Claude browser sign-in: no browser, network,
    /// or real Keychain. Each call is counted inside the fixture root, and the
    /// returned snapshot is saved to the fixture's file Keychain by the
    /// coordinator, so Connect reaches Connected in packaged fixture QA.
    @MainActor
    static func authenticateClaudeInBrowser(
        countURL: URL
    ) throws -> CredentialSnapshot {
        let current = Int(
            (try? String(
                contentsOf: countURL,
                encoding: .utf8
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        ) ?? 0
        try ProviderFileDurability.atomicWrite(
            Data("\(current + 1)\n".utf8),
            to: countURL,
            permissions: 0o600
        )
        return CredentialSnapshot(
            provider: .claude,
            accessToken: "fixture-claude-browser-token",
            refreshToken: "fixture-claude-browser-refresh",
            accountReference: nil,
            planName: "Pro",
            expiresAt: Date().addingTimeInterval(8 * 3_600),
            source: .keychain
        )
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

/// The accessory app has no nib and no other menu, so without a main menu
/// key equivalents such as Cmd+W never reach a window. This contract owns the
/// minimal File -> Close wiring; the action stays gated to the settings
/// window so the transient popover's internal panel can never receive it.
@MainActor
enum ApplicationMenuContract {
    static let closeAction = #selector(
        AppDelegate.closeSettingsWindow(_:)
    )

    static func makeMenu(
        fileTitle: String,
        closeTitle: String,
        closeTarget: AnyObject
    ) -> (fileMenu: NSMenu, closeItem: NSMenuItem) {
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(
            title: fileTitle,
            action: nil,
            keyEquivalent: ""
        )
        let fileMenu = NSMenu(title: fileTitle)
        fileItem.submenu = fileMenu
        let closeItem = NSMenuItem(
            title: closeTitle,
            action: closeAction,
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = NSEvent.ModifierFlags.command
        closeItem.target = closeTarget
        fileMenu.addItem(closeItem)
        mainMenu.addItem(fileItem)
        NSApplication.shared.mainMenu = mainMenu
        return (fileMenu, closeItem)
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
    private let accountDefaults: UserDefaults
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
    private let appUpdateController: AppUpdateController
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
    private var applicationFileMenu: NSMenu?
    private var applicationCloseItem: NSMenuItem?
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
                },
                maskedIdentity: fixture.maskedIdentity
            )
        } ?? ProviderAccountRegistryController(
            store: accountStore,
            loadResult: registryLoadResult,
            maskedIdentity: { CredentialDiscovery.live().maskedIdentity(for: $0, now: Date()) }
        )
        let companionCapture = companionFixture?.captureCredential
            ?? SettingsView.captureCompanionCredential
        let companionLaunch = companionFixture?.launchCompanion
            ?? { ProviderSetup.perform(for: $0) }
#else
        let accountRegistryController = ProviderAccountRegistryController(
            store: accountStore,
            loadResult: registryLoadResult,
            maskedIdentity: { CredentialDiscovery.live().maskedIdentity(for: $0, now: Date()) }
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
                companionFixture?.accountSettingsProviders(registry: registry)
                ?? claudeAuthenticationFixture?.fixtureUsageProviders(
                    registry: registry
                ) ?? ProviderFactory.current(registry: registry, defaults: defaults)
            }
        )
#else
        let accountComposition = AppAccountCompositionFactory.make(
            registry: registryLoadResult.registry,
            providerFactory: { ProviderFactory.current(registry: $0, defaults: defaults) }
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
#if OMO_USAGE_FIXTURES
                guard companionFixture == nil else { return }
#endif
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
                    return try UsageSnapshotCodec.encodeForLocalDashboard(
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
        self.accountDefaults = defaults
        self.companionCapture = companionCapture
        self.companionLaunch = companionLaunch
#if OMO_USAGE_FIXTURES
        self.companionFixture = companionFixture
        self.claudeAuthenticationFixture = claudeAuthenticationFixture
        self.opensSettingsOnLaunch = companionFixture != nil
        self.appUpdateController = AppUpdateController(
            enabled: companionFixture == nil || (
                fixtureEnvironment["OMO_USAGE_APP_UPDATE_QA"] == "1"
                    && Bundle.main.bundleIdentifier?.hasPrefix(
                        "com.omo.usage.qa."
                    ) == true
            )
        )
#else
        self.opensSettingsOnLaunch = false
        self.appUpdateController = AppUpdateController()
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
        installApplicationMenu()
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
        tailscaleDashboardController.startMonitoring(
            wakeNotifications: NSWorkspace.shared.notificationCenter,
            onInitialInspection: { [webDashboardAccessStore] in
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
        )

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
        tailscaleDashboardController.stopMonitoring()
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
        // A companion fixture root confines Claude sign-in to its file
        // Keychain and a fixture grant; nothing opens a browser.
        let claudeSnapshotStore = companionFixture.map {
            ProviderCredentialSnapshotStore(keychain: $0.keychain)
        } ?? CredentialDiscovery.live().snapshotStore
        let authenticateClaude: ClaudeBrowserConnectionCoordinator.Authenticate?
        if let countURL = companionFixture?.claudeBrowserAuthenticationCountURL {
            authenticateClaude = {
                try CompanionAccountFixture.authenticateClaudeInBrowser(countURL: countURL)
            }
        } else {
            authenticateClaude = nil
        }
#else
        let claudeSnapshotStore = CredentialDiscovery.live().snapshotStore
        let authenticateClaude: ClaudeBrowserConnectionCoordinator.Authenticate? = nil
#endif
        let controller = NSHostingController(
            rootView: SettingsView(
                viewModel: viewModel,
                localization: localization,
                presentationStyle: presentationStyle,
                sideNotchHideDelay: sideNotchHideDelay,
                accountRegistryController: accountRegistryController,
                codexPlanDefaults: accountDefaults,
                captureCompanionCredential: companionCapture,
                launchCompanion: companionLaunch,
                claudeSnapshotStore: claudeSnapshotStore,
                authenticateClaude: authenticateClaude,
                authenticateKiro: {
                    try await KiroBrowserAuthenticationClient().authenticate { url in
                        #if OMO_USAGE_FIXTURES
                        if let root = CompanionAccountFixture.resolve(
                            requestKey: CompanionAccountFixture.userInterfaceKey
                        )?.root {
                            try? url.absoluteString.write(
                                to: root.appendingPathComponent("kiro-browser-url.txt"),
                                atomically: true, encoding: .utf8
                            )
                        }
                        #endif
                        return NSWorkspace.shared.open(url)
                    }
                },
                discoverKiro: { target in
                    #if OMO_USAGE_FIXTURES
                    if CompanionAccountFixture.resolve(
                        requestKey: CompanionAccountFixture.userInterfaceKey
                    ) != nil,
                       let mode = ProcessInfo.processInfo.environment["OMO_USAGE_KIRO_AUTH_QA"] {
                        if mode != "existing" { throw CredentialDiscoveryError.notFound(.kiro) }
                        return CredentialSnapshot(
                            provider: .kiro, accessToken: "fixture-existing-kiro",
                            refreshToken: nil,
                            accountReference: "arn:aws:codewhisperer:us-east-1:123456789012:profile/qa",
                            planName: "Kiro Pro", expiresAt: Date().addingTimeInterval(3_600), source: .file
                        )
                    }
                    #endif
                    let discovery = CredentialDiscovery.live()
                    switch target {
                    case .existing(let identity):
                        return CredentialSnapshot(try discovery.kiro(accountID: identity.accountID, now: Date()))
                    case .newAccount:
                        return CredentialSnapshot(try discovery.mutableKiroCredential(now: Date()))
                    }
                },
                validateKiro: { snapshot in
                    #if OMO_USAGE_FIXTURES
                    if let root = CompanionAccountFixture.resolve(
                        requestKey: CompanionAccountFixture.userInterfaceKey
                    )?.root,
                       ProcessInfo.processInfo.environment["OMO_USAGE_KIRO_AUTH_QA"] != nil {
                        try "validated".write(
                            to: root.appendingPathComponent("kiro-validated.txt"),
                            atomically: true, encoding: .utf8
                        )
                        return try await FixtureUsageProvider(id: .kiro).fetch(now: Date())
                    }
                    #endif
                    return try await KiroUsageProvider(discovery: .live(), http: ProviderHTTP()).fetch(
                        credential: snapshot.credential(storage: .accountSnapshot(
                            AccountProviderID(accountID: .legacy, providerID: .kiro)
                        )), now: Date()
                    )
                },
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
                appUpdateController: appUpdateController
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
#if OMO_USAGE_FIXTURES
        if let companionFixture,
           ProcessInfo.processInfo.environment[CompanionAccountFixture.accountSettingsUIKey] == "1" {
            do {
                try ProviderFileDurability.atomicWrite(
                    Data(#"{"version":1}"#.utf8),
                    to: companionFixture.root.appending(path: "account-settings-ready.json"),
                    permissions: 0o600
                )
            } catch {
                DiagnosticStore.shared.record(error: error, category: .fixture)
            }
        }
#endif
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
            providerFactory: { [companionFixture, claudeAuthenticationFixture, accountDefaults] registry in
                companionFixture?.accountSettingsProviders(registry: registry)
                ?? claudeAuthenticationFixture?.fixtureUsageProviders(
                    registry: registry
                ) ?? ProviderFactory.current(registry: registry, defaults: accountDefaults)
            }
        )
#else
        let composition = AppAccountCompositionFactory.make(
            registry: accountRegistryController.registry,
            providerFactory: { [accountDefaults] in
                ProviderFactory.current(registry: $0, defaults: accountDefaults)
            }
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
        applicationFileMenu?.title = localization.text(.fileMenu)
        applicationCloseItem?.title = localization.text(.close)
    }

    private func installApplicationMenu() {
        let menu = ApplicationMenuContract.makeMenu(
            fileTitle: localization.text(.fileMenu),
            closeTitle: localization.text(.close),
            closeTarget: self
        )
        applicationFileMenu = menu.fileMenu
        applicationCloseItem = menu.closeItem
    }

    @objc
    func closeSettingsWindow(_ sender: NSMenuItem) {
        guard let settingsWindow,
              settingsWindow.isKeyWindow
        else { return }
        settingsWindow.performClose(sender)
    }

    @objc
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == ApplicationMenuContract.closeAction
        else { return true }
        guard let settingsWindow else { return false }
        return settingsWindow.isKeyWindow
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
