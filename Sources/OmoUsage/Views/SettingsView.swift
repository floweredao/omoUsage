import OmoUsageCore
import AppKit
import CoreImage
import Observation
import SwiftUI

struct WebDashboardLinkPresentationState {
    struct PresentedItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var presentedItem: PresentedItem?

    mutating func openQRCode(
        _ makeURL: () -> URL?
    ) -> AppStringKey? {
        guard let url = makeURL() else {
            presentedItem = nil
            return AppStringKey.webDashboardLinkCreationFailed
        }
        presentedItem = PresentedItem(url: url)
        return nil
    }

    func shareLink(
        makeURL: () -> URL?,
        present: (URL) -> Bool
    ) -> AppStringKey? {
        guard let url = makeURL(), present(url) else {
            return AppStringKey.webDashboardLinkCreationFailed
        }
        return nil
    }
}

/// Raised when the user declines the Claude Keychain prompt during an
/// account addition, so the addition fails instead of falling back to
/// whatever credential is already cached.
struct ClaudeCredentialAuthorizationDeclined: Error {}

enum ClaudeConnectionAuthorizationDecision: Equatable {
    case refresh
    case launchCompanion
    case stop
}

enum ProviderConnectionMutationPolicy {
    static func allows(
        provider: ProviderID,
        pendingAddition: ProviderID?
    ) -> Bool {
        pendingAddition != provider
    }
}

enum ClaudeConnectionAuthorizationPolicy {
    static func decision(
        for outcome: ClaudeKeychainAuthorizationOutcome
    ) -> ClaudeConnectionAuthorizationDecision {
        switch outcome {
        case .authorized:
            .refresh
        case .notFound:
            .launchCompanion
        case .cancelled:
            .stop
        }
    }
}

struct SettingsView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    let localization: LocalizationController
    @Bindable var accountRegistryController: ProviderAccountRegistryController
    let onRegistryChange: () -> Void
    let onLanguageChange: () -> Void
    let onPresentationStyleChange: (DashboardPresentationStyle) -> Void
    let onSideNotchHideDelayChange: (SideNotchHideDelay) -> Void
    @Bindable var webDashboardStatusStore: WebDashboardStatusStore
    @Bindable var tailscaleDashboardController:
        TailscaleDashboardController
    let onOpenWebDashboard: () -> Bool
    let onCreateWebDashboardURL: () -> URL?
    let onShareWebDashboardURL: (URL, NSView) -> Bool
    let onRetryWebDashboard: () -> Void
    let appUpdateController: AppUpdateController
    private let authorizeClaude: () throws -> ClaudeKeychainAuthorizationOutcome
    private let launchClaudeLogin: (OfficialLoginReceipt) -> Result<
        ProviderSetupOutcome, ProviderSetupError
    >
    private let authenticateDevin: @MainActor () async throws -> CredentialSnapshot
    private let authenticateKiro: @MainActor () async throws -> CredentialSnapshot
    private let discoverKiro: (KiroBrowserConnectionTarget) throws -> CredentialSnapshot
    private let validateKiro: @MainActor (CredentialSnapshot) async throws -> ProviderUsage
    @State private var devinConnection = DevinBrowserConnectionCoordinator()
    @State private var devinLoginTask: Task<Void, Never>?
    @State private var kiroConnection = KiroBrowserConnectionCoordinator()
    @State private var kiroLoginTask: Task<Void, Never>?
    @State private var keyDrafts: [ProviderID: String] = [:]
    @State private var newAccountLabels: [ProviderID: String] = [:]
    @State private var newAccountKeys: [ProviderID: String] = [:]
    @State private var feedback: LocalizedText?
    @State private var setupError: ProviderSetupError?
    @State private var showsRegistryResetConfirmation = false
    @State private var connectionCoordinator =
        ProviderConnectionCoordinator()
    @State private var additionCoordinator:
        ProviderAccountAdditionCoordinator
    @State private var codexReconnectCoordinator:
        CodexLegacyReconnectCoordinator
    private let codexPlanDefaults: UserDefaults
    @State private var codexPlanMultipliers:
        [AccountID: CodexPlanMultiplier] = [:]
    @State private var presentationStyle: DashboardPresentationStyle
    @State private var sideNotchHideDelay: SideNotchHideDelay
    @State private var dashboardLinkPresentation =
        WebDashboardLinkPresentationState()

    init(
        viewModel: UsageDashboardViewModel,
        localization: LocalizationController,
        presentationStyle: DashboardPresentationStyle,
        sideNotchHideDelay: SideNotchHideDelay,
        accountRegistryController: ProviderAccountRegistryController,
        codexPlanDefaults: UserDefaults = .standard,
        captureCompanionCredential: @escaping (ProviderID) throws -> String =
            SettingsView.captureCompanionCredential,
        launchCompanion: @escaping (ProviderID) -> Result<
            ProviderSetupOutcome,
            ProviderSetupError
        > = { ProviderSetup.perform(for: $0) },
        authorizeClaude: @escaping () throws -> ClaudeKeychainAuthorizationOutcome = {
            try ClaudeKeychainAccessSession.shared.authorizeClaude()
        },
        launchClaudeLogin: @escaping (OfficialLoginReceipt) -> Result<
            ProviderSetupOutcome, ProviderSetupError
        > = { ProviderSetup.performClaudeLogin(receipt: $0) },
        authenticateDevin: @escaping @MainActor () async throws -> CredentialSnapshot = {
            try await DevinBrowserAuthenticationClient().authenticate {
                NSWorkspace.shared.open($0)
            }
        },
        authenticateKiro: @escaping @MainActor () async throws -> CredentialSnapshot = {
            try await KiroBrowserAuthenticationClient().authenticate {
                NSWorkspace.shared.open($0)
            }
        },
        discoverKiro: @escaping (KiroBrowserConnectionTarget) throws -> CredentialSnapshot = { target in
            let discovery = CredentialDiscovery.live()
            let credential: DiscoveredCredential
            switch target {
            case .existing(let identity):
                credential = try discovery.kiro(accountID: identity.accountID, now: Date())
            case .newAccount:
                credential = try discovery.mutableKiroCredential(now: Date())
            }
            return CredentialSnapshot(credential)
        },
        validateKiro: @escaping @MainActor (CredentialSnapshot) async throws -> ProviderUsage = { snapshot in
            try await KiroUsageProvider(discovery: .live(), http: ProviderHTTP()).fetch(
                credential: snapshot.credential(storage: .accountSnapshot(
                    AccountProviderID(accountID: .legacy, providerID: .kiro)
                )),
                now: Date()
            )
        },
        onRegistryChange: @escaping () -> Void,
        onLanguageChange: @escaping () -> Void,
        onPresentationStyleChange:
            @escaping (DashboardPresentationStyle) -> Void,
        onSideNotchHideDelayChange:
            @escaping (SideNotchHideDelay) -> Void,
        webDashboardStatusStore: WebDashboardStatusStore,
        tailscaleDashboardController:
            TailscaleDashboardController,
        onOpenWebDashboard: @escaping () -> Bool,
        onCreateWebDashboardURL: @escaping () -> URL?,
        onShareWebDashboardURL: @escaping (URL, NSView) -> Bool,
        onRetryWebDashboard: @escaping () -> Void,
        appUpdateController: AppUpdateController
    ) {
        self.viewModel = viewModel
        self.localization = localization
        self.accountRegistryController = accountRegistryController
        self.codexPlanDefaults = codexPlanDefaults
        self.onRegistryChange = onRegistryChange
        self.onLanguageChange = onLanguageChange
        self.onPresentationStyleChange = onPresentationStyleChange
        self.onSideNotchHideDelayChange =
            onSideNotchHideDelayChange
        self.webDashboardStatusStore = webDashboardStatusStore
        self.tailscaleDashboardController =
            tailscaleDashboardController
        self.onOpenWebDashboard = onOpenWebDashboard
        self.onCreateWebDashboardURL = onCreateWebDashboardURL
        self.onShareWebDashboardURL = onShareWebDashboardURL
        self.onRetryWebDashboard = onRetryWebDashboard
        self.appUpdateController = appUpdateController
        self.authorizeClaude = authorizeClaude
        self.launchClaudeLogin = launchClaudeLogin
        self.authenticateDevin = authenticateDevin
        self.authenticateKiro = authenticateKiro
        self.discoverKiro = discoverKiro
        self.validateKiro = validateKiro
        _presentationStyle = State(initialValue: presentationStyle)
        _sideNotchHideDelay = State(initialValue: sideNotchHideDelay)
        _additionCoordinator = State(
            initialValue: ProviderAccountAdditionCoordinator(
                controller: accountRegistryController,
                captureCredential: captureCompanionCredential,
                launchCompanion: launchCompanion,
                onAccountAdded: onRegistryChange
            )
        )
        _codexReconnectCoordinator = State(
            initialValue: CodexLegacyReconnectCoordinator(
                captureCredential: {
                    try captureCompanionCredential(.codex)
                },
                persistLegacySnapshot: {
                    try accountRegistryController
                        .replaceLegacyCodexCredential($0)
                },
                launchCompanion: { launchCompanion(.codex) },
                reenable: {
                    viewModel.reconnectAccountProvider(
                        AccountProviderID(accountID: .legacy, providerID: .codex)
                    )
                    onRegistryChange()
                }
            )
        )
    }

    /// Production capture for companion additions. Claude keeps its
    /// explicit authorization step: an unauthorized read must fail the
    /// addition rather than silently reuse a cached credential.
    nonisolated static func captureCompanionCredential(
        for provider: ProviderID
    ) throws -> String {
        if provider == .claude {
            switch try ClaudeKeychainAccessSession.shared.authorizeClaude() {
            case .authorized, .notFound:
                break
            case .cancelled:
                throw ClaudeCredentialAuthorizationDeclined()
            }
        }
        return try CredentialDiscovery.live().captureCredential(
            for: provider,
            now: Date()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localization.text(.settingsTitle))
                    .font(.system(size: 19, weight: .bold))
                Text(localization.text(.settingsSubtitle))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    if accountRegistryController.recoveryState != .ready {
                        AccountRegistryRecoveryBanner(
                            state: accountRegistryController.recoveryState,
                            onRestore: restoreRegistryBackup,
                            onReset: {
                                showsRegistryResetConfirmation = true
                            }
                        )
                    }

                    HStack {
                        Text(localization.text(.language))
                            .font(.system(size: 13.5, weight: .semibold))
                        Spacer()
                        Picker(
                            localization.text(.language),
                            selection: Binding(
                                get: { localization.language },
                                set: { language in
                                    localization.select(language)
                                    onLanguageChange()
                                }
                            )
                        ) {
                            Text(localization.text(.korean))
                                .tag(AppLanguage.korean)
                            Text(localization.text(.english))
                                .tag(AppLanguage.english)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(10)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )

                    HStack {
                        Text(localization.text(.dashboardPresentation))
                            .font(.system(size: 13.5, weight: .semibold))
                        Spacer()
                        Picker(
                            localization.text(.dashboardPresentation),
                            selection: Binding(
                                get: { presentationStyle },
                                set: { style in
                                    presentationStyle = style
                                    onPresentationStyleChange(style)
                                }
                            )
                        ) {
                            Text(localization.text(.popoverPresentation))
                                .tag(DashboardPresentationStyle.popover)
                            Text(localization.text(.sideNotchPresentation))
                                .tag(DashboardPresentationStyle.sideNotch)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(10)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )

                    if presentationStyle == .sideNotch {
                        HStack {
                            Text(
                                localization.text(
                                    .sideNotchHideDelay
                                )
                            )
                                .font(
                                    .system(
                                        size: 13.5,
                                        weight: .semibold
                                    )
                                )
                            Spacer()
                            Picker(
                                localization.text(
                                    .sideNotchHideDelay
                                ),
                                selection: Binding(
                                    get: { sideNotchHideDelay },
                                    set: { delay in
                                        sideNotchHideDelay = delay
                                        onSideNotchHideDelayChange(
                                            delay
                                        )
                                    }
                                )
                            ) {
                                ForEach(
                                    SideNotchHideDelay.allCases
                                ) { delay in
                                    Text(
                                        localization.format(
                                            .sideNotchHideDelayOption,
                                            delay.rawValue
                                        )
                                    )
                                        .tag(delay)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 128)
                            .accessibilityLabel(
                                localization.text(
                                    .sideNotchHideDelay
                                )
                            )
                        }
                        .padding(10)
                        .background(
                            Color(
                                nsColor:
                                    .controlBackgroundColor
                            ),
                            in: RoundedRectangle(
                                cornerRadius: 10,
                                style: .continuous
                            )
                        )
                    }

                    WebDashboardSettingsRow(
                        status: webDashboardStatusStore.status,
                        tailscaleController:
                            tailscaleDashboardController,
                        onOpen: {
                            if !onOpenWebDashboard() {
                                feedback = .key(.webDashboardOpenFailed)
                            }
                        },
                        onOpenQRCode: {
                            if let failureKey =
                                dashboardLinkPresentation.openQRCode(
                                    onCreateWebDashboardURL
                                )
                            {
                                feedback = .key(failureKey)
                            }
                        },
                        onShareLink: { anchorView in
                            if let failureKey =
                                dashboardLinkPresentation.shareLink(
                                    makeURL: onCreateWebDashboardURL,
                                    present: {
                                        onShareWebDashboardURL(
                                            $0,
                                            anchorView
                                        )
                                    }
                                )
                            {
                                feedback = .key(failureKey)
                            }
                        },
                        onRetry: onRetryWebDashboard
                    )

                    AppUpdateSettingsRow(controller: appUpdateController)

                    if accountRegistryController.registry != nil {
                        ProviderOrderingView(viewModel: viewModel)
                            .padding(.top, 4)

                        Text(localization.text(.providerAuthentication))
                            .font(.system(size: 14, weight: .bold))
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(.top, 4)

                        ForEach(viewModel.providerOrder, id: \.self) {
                            provider in
                            ProviderSettingsRow(
                                provider: provider,
                                viewModel: viewModel,
                                connectionPresentation:
                                    connectionCoordinator.state(for: provider),
                                connectionControlsDisabled:
                                    connectionControlsDisabled(for: provider),
                                keyDraft: binding(for: provider),
                                keySource: accountRegistryController
                                    .keyStorageSource(for: provider),
                                needsLegacyCleanup: accountRegistryController
                                    .pendingLegacyCleanup.contains {
                                        $0.accountID == .legacy
                                            && $0.providerID == provider
                                    },
                                onCleanupLegacy: retryLegacyKeyCleanup,
                                onSetup: {
                                    connectProvider(provider)
                                },
                                onSave: { saveKey(for: provider) },
                                onRemove: { removeKey(for: provider) },
                                onDisconnect: {
                                    disconnectProvider(provider)
                                },
                                onReconnect: {
                                    reconnectProvider(provider)
                                },
                                onRetry: {
                                    retryProvider(provider)
                                },
                                accounts: ProviderAccountRowPresentation.rows(
                                    from: accountRegistryController
                                        .settingsAccounts(for: provider)
                                ),
                                newAccountLabel: accountLabelBinding(
                                    for: provider
                                ),
                                newAccountKey: accountKeyBinding(
                                    for: provider
                                ),
                                onAddAccount: {
                                    addAccount(for: provider)
                                },
                                onRemoveAccount: removeAccount,
                                onRenameAccount: renameAccount,
                                onAliasOutcome: reportAliasOutcome,
                                additionAvailability:
                                    ProviderAccountAdditionAvailability.resolve(
                                        provider: provider,
                                        viewModel: viewModel,
                                        additionState: additionState(for: provider)
                                    ),
                                onCheckAgain: checkForCompanionCredential,
                                onCancelAddition: cancelAddition,
                                isAwaitingConnectionCredential:
                                    provider == .codex
                                        && codexReconnectCoordinator
                                            .isWaiting,
                                onCheckAgainConnection:
                                    checkForCodexReconnectCredential,
                                onCancelConnection: {
                                    if provider == .kiro { cancelKiroConnection() }
                                    else if provider == .devin { cancelDevinConnection() }
                                    else { cancelCodexReconnect() }
                                },
                                browserConnectionTarget: devinConnection.pending,
                                kiroConnectionTarget: kiroConnection.pending,
                                onBrowserConnect: { startDevinConnection(.existing($0)) },
                                onKiroConnect: { startKiroConnection(.existing($0)) },
                                codexPlanMultiplier:
                                    codexPlanMultiplierBinding(
                                        for: provider
                                    )
                            )
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                if let feedback {
                    Text(localization.resolve(feedback))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-feedback")
                }
                Spacer()
                Button(localization.text(.refresh)) {
                    Task { await viewModel.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isRefreshing)
            }
        }
        .padding(20)
        .frame(
            minWidth: 440,
            idealWidth: 480,
            minHeight: 460,
            idealHeight: 560
        )
        .environment(\.appLocalization, localization.context)
        .sheet(item: $dashboardLinkPresentation.presentedItem) { item in
            WebDashboardQRCodeView(url: item.url)
                .environment(
                    \.appLocalization,
                    localization.context
                )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            let pendingProvider = additionCoordinator.pending?.provider
            apply(
                additionCoordinator.applicationDidBecomeActive(),
                for: pendingProvider
            )
            if codexReconnectCoordinator.isWaiting {
                _ = codexReconnectCoordinator.checkAgain()
            }
            Task {
                await refreshPendingConnectionsAfterActivation()
            }
        }
        .confirmationDialog(
            localization.text(.registryResetTitle),
            isPresented: $showsRegistryResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                localization.text(.resetRegistry),
                role: .destructive,
                action: resetRegistry
            )
            Button(localization.text(.cancel), role: .cancel) {}
        } message: {
            Text(localization.text(.registryResetDescription))
        }
        .alert(item: $setupError) { error in
            Alert(
                title: Text(
                    localization.text(.cannotStartConnection)
                ),
                message: Text(localization.providerSetupError(error)),
                dismissButton: .default(
                    Text(localization.text(.confirm))
                )
            )
        }
        .onDisappear {
            connectionCoordinator.cancelClaudeLogin()
            cancelDevinConnection()
            cancelKiroConnection()
        }
    }

    private func refreshPendingConnectionsAfterActivation() async {
        await connectionCoordinator.applicationDidBecomeActive(
            refresh: { await viewModel.refresh() },
            availability: { (provider: ProviderID) in
                viewModel.accountConnectionStates[
                    AccountProviderID(accountID: .legacy, providerID: provider)
                ]
            }
        )
        if !Task.isCancelled,
           connectionCoordinator.state(for: .claude) == .authenticated
        {
            feedback = nil
        }
    }

    private func restoreRegistryBackup() {
        do {
            try accountRegistryController.restoreBackup()
            feedback = .key(.registryRestoreSucceeded)
            onRegistryChange()
        } catch {
            feedback = .key(.registryRecoveryFailed)
        }
    }

    private func resetRegistry() {
        do {
            try accountRegistryController.resetRegistry()
            feedback = .key(.registryResetSucceeded)
            onRegistryChange()
        } catch {
            feedback = .key(.registryRecoveryFailed)
        }
    }

    private func binding(
        for provider: ProviderID
    ) -> Binding<String> {
        Binding(
            get: { keyDrafts[provider, default: ""] },
            set: { keyDrafts[provider] = $0 }
        )
    }

    private func accountLabelBinding(
        for provider: ProviderID
    ) -> Binding<String> {
        Binding(
            get: { newAccountLabels[provider, default: ""] },
            set: { newAccountLabels[provider] = $0 }
        )
    }

    private func accountKeyBinding(
        for provider: ProviderID
    ) -> Binding<String> {
        Binding(
            get: { newAccountKeys[provider, default: ""] },
            set: { newAccountKeys[provider] = $0 }
        )
    }

    private func connectionControlsDisabled(
        for provider: ProviderID
    ) -> Bool {
        if provider == .devin, devinLoginTask != nil { return true }
        if provider == .kiro, kiroLoginTask != nil { return true }
        return !ProviderConnectionMutationPolicy.allows(
            provider: provider,
            pendingAddition: additionCoordinator.pending?.provider
        )
    }

    private func connectProvider(_ provider: ProviderID) {
        if provider == .kiro {
            startKiroConnection(.existing(AccountProviderID(accountID: .legacy, providerID: .kiro)))
            return
        }
        guard !connectionControlsDisabled(for: provider) else { return }
        ProviderConnectionControl.performConnect(
            provider: provider,
            startConnection: startConnection,
            startGuardedCodexConnection: startGuardedCodexConnection
        )
    }

    private func startConnection(for provider: ProviderID) {
        if provider == .devin {
            startDevinConnection(.existing(
                AccountProviderID(accountID: .legacy, providerID: .devin)
            ))
            return
        }
        let result: Result<ProviderSetupOutcome, ProviderSetupError>
        if provider == .claude {
            result = connectionCoordinator.startClaudeLogin(
                launch: launchClaudeLogin,
                authorize: authorizeClaude,
                refresh: {
                    await viewModel.retryAccountProvider(
                        AccountProviderID(accountID: .legacy, providerID: .claude)
                    )
                },
                availability: {
                    viewModel.accountConnectionStates[
                        AccountProviderID(accountID: .legacy, providerID: .claude)
                    ]
                },
                didComplete: {
                    feedback = connectionCoordinator.state(for: .claude) == .authenticated
                        ? nil : .key(.authenticationRequired)
                }
            )
        } else {
            result = ProviderSetup.perform(for: provider)
            connectionCoordinator.record(result, for: provider)
        }
        switch result {
        case .success(.launched):
            feedback = .key(.waitingForCompanionCredentials)
        case .success(.openedFallback):
            feedback = .key(.companionRequired)
        case .failure(let error):
            if case .companionRequired = error {
                feedback = .key(.companionRequired)
            }
            setupError = error
        }
    }

    private func disconnectProvider(_ provider: ProviderID) {
        guard !connectionControlsDisabled(for: provider) else { return }
        if provider == .claude { connectionCoordinator.cancelClaudeLogin() }
        viewModel.disconnectAccountProvider(
            AccountProviderID(accountID: .legacy, providerID: provider)
        )
        feedback = .formatted(
            .disconnectedProvider,
            "\(provider.displayName), \(accountRegistryController.settingsAccounts(for: provider).first(where: \.isPrimary)?.label ?? AccountLabel.defaultValue)"
        )
    }

    private func retryProvider(_ provider: ProviderID) {
        ProviderConnectionControl.performRetry(
            provider: provider,
            refresh: { provider in
                Task {
                    let primary = AccountProviderID(
                        accountID: .legacy, providerID: provider
                    )
                    await viewModel.retryAccountProvider(primary)
                    if !Task.isCancelled,
                       provider == .claude,
                       viewModel.accountConnectionStates[primary] == .available {
                        feedback = nil
                    }
                }
            }
        )
    }

    private func startGuardedCodexConnection(_ provider: ProviderID) {
        precondition(provider == .codex)
        let outcome = codexReconnectCoordinator.start()
        switch outcome {
        case .waitingForCredential:
            feedback = .key(.waitingForCompanionCredentials)
        case .launchFailed(let error):
            setupError = error
        case .credentialUnavailable:
            feedback = .key(.authenticationRequired)
        default:
            break
        }
    }

    private func reconnectProvider(_ provider: ProviderID) {
        guard !connectionControlsDisabled(for: provider) else { return }
        if provider == .codex || provider == .devin {
            connectProvider(provider)
            return
        }
        ProviderConnectionControl.performReconnect(
            provider: provider,
            reenable: { provider in
                viewModel.reconnectAccountProvider(
                    AccountProviderID(accountID: .legacy, providerID: provider)
                )
            },
            startConnection: startConnection,
            launchOfficialLogin: startConnection
        )
    }

    private func saveKey(for provider: ProviderID) {
        do {
            try accountRegistryController.saveLegacyAPIKey(
                provider: provider,
                key: keyDrafts[provider, default: ""]
            )
            keyDrafts[provider] = ""
            feedback = .formatted(
                .savedKey,
                provider.displayName
            )
            onRegistryChange()
        } catch {
            feedback = .key(.saveKeyFailed)
        }
    }

    private func removeKey(for provider: ProviderID) {
        do {
            try accountRegistryController.removeLegacyAPIKeyReference(
                for: provider
            )
            keyDrafts[provider] = ""
            feedback = .formatted(
                .removedKey,
                provider.displayName
            )
            onRegistryChange()
        } catch {
            feedback = .key(.removeKeyFailed)
        }
    }

    private func retryLegacyKeyCleanup() {
        do {
            try accountRegistryController.retryLegacyKeyCleanup()
            feedback = .key(.legacyKeyCleanupSucceeded)
        } catch {
            feedback = .key(.legacyKeyCleanupFailed)
        }
    }

    private func addAccount(for provider: ProviderID) {
        if provider == .kiro {
            startKiroConnection(.newAccount(newAccountLabels[provider, default: ""]))
            return
        }
        if provider == .devin {
            startDevinConnection(.newAccount(newAccountLabels[provider, default: ""]))
            return
        }
        apply(
            additionCoordinator.addAccount(
                provider: provider,
                label: newAccountLabels[provider, default: ""],
                key: newAccountKeys[provider]
            ),
            for: provider
        )
    }

    private func checkForCompanionCredential() {
        let provider = additionCoordinator.pending?.provider
        apply(additionCoordinator.checkAgain(), for: provider)
    }

    /// Cancelling drops the pending addition but keeps the alias the user
    /// typed, so retrying does not start from an empty field.
    private func cancelAddition() {
        if case .newAccount = devinConnection.pending { cancelDevinConnection() }
        if case .newAccount = kiroConnection.pending { cancelKiroConnection() }
        additionCoordinator.cancel()
        feedback = nil
    }

    private func additionState(
        for provider: ProviderID
    ) -> ProviderAccountAdditionRowState {
        let browserAddition: ProviderID?
        if case .newAccount = devinConnection.pending { browserAddition = .devin }
        else if case .newAccount = kiroConnection.pending { browserAddition = .kiro }
        else { browserAddition = nil }
        return ProviderAccountAdditionRowState.resolve(
            provider: provider,
            pendingAddition: browserAddition ?? additionCoordinator.pending?.provider,
            guardedReconnectProvider: devinLoginTask != nil && browserAddition == nil
                ? .devin : codexReconnectCoordinator.isWaiting
                ? .codex
                : nil
        )
    }

    private func startDevinConnection(_ target: DevinBrowserConnectionTarget) {
        guard devinLoginTask == nil, additionCoordinator.pending == nil else { return }
        if case .newAccount(let label) = target,
           (try? ProviderAccountRegistryController.validatedAccountLabel(label)) == nil {
            feedback = .key(.accountAdditionFailed)
            return
        }
        feedback = .key(.waitingForBrowserLogin)
        devinLoginTask = Task { @MainActor in
            defer { devinLoginTask = nil }
            do {
                let identity = try await devinConnection.connect(
                    target: target,
                    authenticate: authenticateDevin,
                    validate: { snapshot in
                        let identity: AccountProviderID
                        if case .existing(let existing) = target { identity = existing }
                        else { identity = AccountProviderID(accountID: .legacy, providerID: .devin) }
                        return try await DevinUsageProvider(discovery: .live()).fetch(
                            credential: snapshot.credential(storage: .accountSnapshot(identity)),
                            now: Date()
                        )
                    },
                    persist: { target, snapshot in
                        let secret = try snapshot.encodedSecret()
                        switch target {
                        case .existing(let identity):
                            try accountRegistryController.replaceDevinCredential(
                                for: identity, encodedSecret: secret
                            )
                            return identity
                        case .newAccount(let label):
                            return try accountRegistryController.addCapturedCompanionAccount(
                                provider: .devin, label: label, encodedSecret: secret
                            )
                        }
                    }
                )
                onRegistryChange()
                if case .newAccount = target { newAccountLabels[.devin] = "" }
                await viewModel.retryAccountProvider(identity)
                if !Task.isCancelled { feedback = nil }
            } catch is CancellationError {
                feedback = nil
            } catch {
                feedback = .key(.browserLoginFailed)
            }
        }
    }

    private func startKiroConnection(_ target: KiroBrowserConnectionTarget) {
        guard kiroLoginTask == nil else { return }
        kiroLoginTask = Task { @MainActor in
            defer { kiroLoginTask = nil }
            do {
                var expectedProfile: String?
                var excludedProfiles: Set<String> = []
                switch target {
                case .existing(let identity):
                    expectedProfile = try accountRegistryController
                        .storedKiroCredential(for: identity)?.accountReference
                case .newAccount:
                    for row in accountRegistryController.settingsAccounts(for: .kiro) {
                        if let profile = try accountRegistryController
                            .storedKiroCredential(for: row.accountProviderID)?.accountReference {
                            excludedProfiles.insert(profile)
                        }
                    }
                    do {
                        let primary = try discoverKiro(.existing(
                            AccountProviderID(accountID: .legacy, providerID: .kiro)
                        ))
                        if let profile = primary.accountReference { excludedProfiles.insert(profile) }
                    } catch CredentialDiscoveryError.notFound(.kiro) {
                        // No primary credential to exclude.
                    } catch CredentialDiscoveryError.expired(.kiro) {
                        // A captured profile was already excluded above.
                    }
                }
                let identity = try await kiroConnection.connect(
                    target: target,
                    expectedProfile: expectedProfile,
                    excludedProfiles: excludedProfiles,
                    discover: { try discoverKiro(target) },
                    authenticate: authenticateKiro,
                    validate: validateKiro,
                    persist: { destination, snapshot in
                        let secret = try snapshot.encodedSecret()
                        switch destination {
                        case .existing(let identity):
                            try accountRegistryController.importKiroCredential(
                                secret, for: identity, now: Date()
                            )
                            return identity
                        case .newAccount(let label):
                            return try accountRegistryController.addCapturedCompanionAccount(
                                provider: .kiro, label: label, encodedSecret: secret
                            )
                        }
                    }
                )
                onRegistryChange()
                await viewModel.retryAccountProvider(identity)
                if !Task.isCancelled { feedback = nil }
                if case .newAccount = target { newAccountLabels[.kiro] = "" }
            } catch is CancellationError {
                feedback = nil
            } catch {
                feedback = .key(.authenticationRequired)
            }
        }
    }

    private func cancelKiroConnection() {
        kiroLoginTask?.cancel()
    }

    private func cancelDevinConnection() {
        devinLoginTask?.cancel()
        feedback = nil
    }

    /// Re-samples the companion credential without leaving the waiting
    /// state: an unchanged, missing, or unwritable credential keeps the
    /// legacy Codex account pinned and the provider disconnected.
    private func checkForCodexReconnectCredential() {
        switch codexReconnectCoordinator.checkAgain() {
        case .credentialUnchanged:
            feedback = .key(.companionCredentialUnchanged)
        case .credentialMissing:
            feedback = .key(.companionCredentialMissing)
        case .credentialUnavailable:
            feedback = .key(.companionCredentialUnavailable)
        case .launchFailed(let error):
            setupError = error
        case .reconnected:
            feedback = nil
        case .waitingForCredential, .ignored:
            break
        }
    }

    /// Cancelling stops the guarded reconnect only: the provider stays
    /// disconnected and nothing is persisted or re-enabled.
    private func cancelCodexReconnect() {
        codexReconnectCoordinator.cancel()
        feedback = nil
    }

    private func apply(
        _ outcome: ProviderAccountAdditionOutcome,
        for provider: ProviderID?
    ) {
        switch outcome {
        case .addedAccount(let label):
            if let provider {
                newAccountLabels[provider] = ""
                newAccountKeys[provider] = ""
            }
            feedback = .formatted(.addedAccount, label)
        case .waitingForCompanion, .additionInProgress:
            feedback = .key(.waitingForCompanionCredentials)
        case .credentialUnchanged:
            feedback = .key(.companionCredentialUnchanged)
        case .credentialMissing:
            feedback = .key(.companionCredentialMissing)
        case .credentialUnavailable:
            feedback = .key(.companionCredentialUnavailable)
        case .invalidLabel, .failed:
            feedback = .key(.accountAdditionFailed)
        case .openedOfficialGuide:
            feedback = .formatted(
                .openedOfficialAuthentication,
                provider?.displayName ?? ""
            )
        case .launchFailed(let error):
            if case .companionRequired = error {
                feedback = .key(.companionRequired)
            }
            setupError = error
        case .ignored:
            break
        }
    }

    private func codexPlanMultiplierBinding(
        for provider: ProviderID
    ) -> ((AccountProviderID) -> Binding<CodexPlanMultiplier>)? {
        guard provider == .codex else { return nil }
        return { identity in codexTierBinding(for: identity) }
    }

    /// Each Codex account keeps its own usage tier. The store is read on
    /// every fetch, so saving only needs a refresh, not a provider rebuild.
    private func codexTierBinding(
        for identity: AccountProviderID
    ) -> Binding<CodexPlanMultiplier> {
        let store = CodexPlanMultiplierStore(
            defaults: codexPlanDefaults,
            accountID: identity.accountID
        )
        return Binding(
            get: {
                codexPlanMultipliers[identity.accountID] ?? store.load()
            },
            set: { multiplier in
                store.save(multiplier)
                codexPlanMultipliers[identity.accountID] = multiplier
                Task { await viewModel.refresh() }
            }
        )
    }

    private func renameAccount(
        _ identity: AccountProviderID,
        label: String
    ) throws {
        try accountRegistryController.renameAccount(identity, label: label)
        onRegistryChange()
    }

    private func reportAliasOutcome(_ outcome: AccountAliasEdit.Outcome) {
        switch outcome {
        case .saved(let label):
            feedback = .formatted(.savedAccountAlias, label)
        case .rejected(.invalidLabel):
            feedback = .key(.accountAliasInvalid)
        case .rejected(.failed):
            feedback = .key(.saveAccountAliasFailed)
        }
    }

    private func removeAccount(_ identity: AccountProviderID) {
        let label = accountRegistryController.accounts.first {
            $0.id == identity
        }?.label ?? AccountLabel.defaultValue
        do {
            try accountRegistryController.removeAccount(identity)
            feedback = .formatted(.removedAccount, label)
            onRegistryChange()
        } catch {
            feedback = .key(.accountChangeFailed)
        }
    }
}

private struct AccountRegistryRecoveryBanner: View {
    let state: ProviderAccountRecoveryState
    let onRestore: () -> Void
    let onReset: () -> Void
    @Environment(\.appLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                localization.text(
                    state.isRecoveredFromBackup
                        ? .registryRecoveredTitle
                        : .registryBlockedTitle
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(.orange)

            Text(
                localization.text(
                    state.isRecoveredFromBackup
                        ? .registryRecoveredDescription
                        : .registryBlockedDescription
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            HStack {
                if state.isRecoveredFromBackup {
                    Button(
                        localization.text(.restoreRegistryBackup),
                        action: onRestore
                    )
                    .buttonStyle(.borderedProminent)
                }
                Button(
                    localization.text(.resetRegistry),
                    role: .destructive,
                    action: onReset
                )
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.orange.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityIdentifier("account-registry-recovery")
    }
}

enum ProviderAccountAdditionRowState: Equatable, Sendable {
    case idle
    case waiting
    case blockedByOtherAddition

    /// A guarded reconnect owns the same companion login an addition would
    /// start, so that provider's Add Account stays disabled until the
    /// reconnect completes or is cancelled. Providers that only need an API
    /// key never share that login and stay usable.
    static func resolve(
        provider: ProviderID,
        pendingAddition: ProviderID?,
        guardedReconnectProvider: ProviderID?
    ) -> ProviderAccountAdditionRowState {
        guard let pendingAddition else {
            return guardedReconnectProvider == provider
                ? .blockedByOtherAddition
                : .idle
        }
        if pendingAddition == provider { return .waiting }
        return ProviderSetup.descriptor(for: provider)?.acceptsAPIKey == true
            ? .idle
            : .blockedByOtherAddition
    }
}

/// Whether a provider row offers Add Account at all. Another account can
/// only be added beside a connected primary account, so the affordance is
/// absent, not merely disabled, until the primary is connected. A
/// companion login that is already pending keeps its own Check Again and
/// Cancel controls reachable no matter what happens to the primary account
/// meanwhile.
enum ProviderAccountAdditionAvailability: Equatable, Sendable {
    case hidden
    case offered
    case blocked
    case pending

    @MainActor
    static func resolve(
        provider: ProviderID,
        viewModel: UsageDashboardViewModel,
        additionState: ProviderAccountAdditionRowState
    ) -> ProviderAccountAdditionAvailability {
        let primary = AccountProviderID(accountID: .legacy, providerID: provider)
        return resolve(
            additionState: additionState,
            primaryAvailability: viewModel.accountConnectionStates[primary],
            isPrimaryDisconnected: viewModel.isDisconnected(primary)
        )
    }

    static func resolve(
        additionState: ProviderAccountAdditionRowState,
        primaryAvailability: ProviderAvailability?,
        isPrimaryDisconnected: Bool
    ) -> ProviderAccountAdditionAvailability {
        if additionState == .waiting { return .pending }
        guard primaryAvailability == .available, !isPrimaryDisconnected else {
            return .hidden
        }
        return additionState == .idle ? .offered : .blocked
    }
}

enum ProviderAccountRole: String, Equatable, Sendable {
    case primary
    case additional

    var stringKey: AppStringKey {
        switch self {
        case .primary: .primaryAccount
        case .additional: .additionalAccount
        }
    }
}

/// One settings row per account-provider identity. The primary account is
/// always the first row, so a provider with a single account still names
/// it as the primary one instead of showing an unlabelled header.
struct ProviderAccountRowPresentation: Identifiable, Equatable, Sendable {
    var id: AccountProviderID { identity }
    let identity: AccountProviderID
    let role: ProviderAccountRole
    let label: String
    let maskedIdentity: String?
    let source: ProviderKeyStorageSource?

    var canRemove: Bool { role == .additional }
    var showsCodexTier: Bool { identity.providerID == .codex }

    static func rows(
        from accounts: [ProviderAccountSettingsMetadata]
    ) -> [ProviderAccountRowPresentation] {
        let rows = accounts.map { account in
            ProviderAccountRowPresentation(
                identity: account.accountProviderID,
                role: account.isPrimary ? .primary : .additional,
                label: account.label,
                maskedIdentity: account.maskedIdentity,
                source: account.source
            )
        }
        return rows.filter { $0.role == .primary }
            + rows.filter { $0.role == .additional }
    }
}

enum AccountSettingsControl: Equatable, Sendable {
    case row
    case role(ProviderAccountRole)
    case name
    case identity
    case editAlias
    case aliasField
    case saveAlias
    case cancelAlias
    case removeAccount
    case codexTier
}

/// Accessibility identifiers are keyed by provider and account ID, never by
/// the alias, so QA drivers and assistive technology keep one stable target
/// across alias edits.
enum AccountSettingsAccessibility {
    static func identifier(
        _ control: AccountSettingsControl,
        for identity: AccountProviderID
    ) -> String {
        let account = identity.accountID.rawValue
        let provider = identity.providerID.rawValue
        return switch control {
        case .row: "account-row-\(provider)-\(account)"
        case .role(let role):
            "account-role-\(role.rawValue)-\(provider)-\(account)"
        case .name: "account-name-\(provider)-\(account)"
        case .identity: "account-identity-\(provider)-\(account)"
        case .editAlias: "edit-alias-\(provider)-\(account)"
        case .aliasField: "alias-field-\(provider)-\(account)"
        case .saveAlias: "save-alias-\(provider)-\(account)"
        case .cancelAlias: "cancel-alias-\(provider)-\(account)"
        case .removeAccount: "remove-account-\(provider)-\(account)"
        case .codexTier: "codex-tier-\(account)"
        }
    }

    /// The masked identity is the only identity text ever spoken. A missing
    /// identity contributes nothing rather than a placeholder address.
    static func accessibleName(
        roleText: String,
        label: String,
        maskedIdentity: String?
    ) -> String {
        [roleText, label, maskedIdentity]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Draft state for renaming one account. The alias already saved is never
/// replaced until the registry accepts the new label, so a rejected edit
/// keeps both the draft and the saved alias.
struct AccountAliasEdit: Equatable, Sendable {
    enum Rejection: Equatable, Sendable {
        case invalidLabel
        case failed
    }

    enum Outcome: Equatable, Sendable {
        case saved(String)
        case rejected(Rejection)
    }

    let identity: AccountProviderID
    let savedLabel: String
    var draft: String

    init(identity: AccountProviderID, savedLabel: String) {
        self.identity = identity
        self.savedLabel = savedLabel
        draft = savedLabel
    }

    var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool {
        !trimmedDraft.isEmpty && trimmedDraft != savedLabel
    }

    @MainActor
    func commit(rename: (String) throws -> Void) -> Outcome {
        guard canSave else { return .rejected(.invalidLabel) }
        let label: String
        do {
            label = try ProviderAccountRegistryController
                .validatedAccountLabel(trimmedDraft)
        } catch {
            return .rejected(.invalidLabel)
        }
        do {
            try rename(label)
        } catch ProviderAccountRegistryControllerError.invalidLabel {
            return .rejected(.invalidLabel)
        } catch {
            return .rejected(.failed)
        }
        return .saved(label)
    }
}

private struct ProviderAccountsSection<
    ConnectionControls: View, PrimaryCredentials: View
>: View {
    let provider: ProviderID
    let rows: [ProviderAccountRowPresentation]
    let additionAvailability: ProviderAccountAdditionAvailability
    @Binding var label: String
    @Binding var key: String
    let onAdd: () -> Void
    let onRemove: (AccountProviderID) -> Void
    let onRename: (AccountProviderID, String) throws -> Void
    let onAliasOutcome: (AccountAliasEdit.Outcome) -> Void
    let codexPlanMultiplier:
        ((AccountProviderID) -> Binding<CodexPlanMultiplier>)?
    let onCheckAgain: () -> Void
    let onCancelAddition: () -> Void
    @ViewBuilder let connectionControls:
        (ProviderAccountRowPresentation) -> ConnectionControls
    @ViewBuilder let primaryCredentials: () -> PrimaryCredentials
    @State private var isAddingAccount = false
    @State private var aliasEdit: AccountAliasEdit?
    @FocusState private var isAliasFocused: Bool
    @FocusState private var focusedAliasEdit: AccountProviderID?
    @Environment(\.appLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                accountRow(row)
            }

            if additionAvailability == .pending {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        localization.format(.accountLoginPending, label),
                        systemImage: "person.crop.circle.badge.clock"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "account-waiting-\(provider.rawValue)"
                    )
                    Text(localization.text(provider == .devin || provider == .kiro
                        ? .waitingForBrowserLogin : .companionCredentialMissing))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(
                            localization.text(.cancel),
                            action: onCancelAddition
                        )
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(
                            "cancel-addition-\(provider.rawValue)"
                        )
                        if provider != .devin && provider != .kiro { Button(
                            localization.text(
                                .checkAgainForCompanionCredentials
                            ),
                            action: onCheckAgain
                        )
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(
                            "check-again-\(provider.rawValue)"
                        )
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            } else if additionAvailability == .hidden {
                EmptyView()
            } else if isAddingAccount {
                VStack(alignment: .leading, spacing: 12) {
                    Text(localization.text(
                        acceptsAPIKey
                            ? .additionalAPIKeyInstructions
                            : .additionalAccountInstructions
                    ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(localization.text(.accountAlias))
                            .font(.system(size: 11.5, weight: .medium))
                        TextField(
                            localization.text(.accountAliasExample),
                            text: $label
                        )
                        .textFieldStyle(.roundedBorder)
                        .focused($isAliasFocused)
                        .accessibilityLabel(localization.text(.accountAlias))
                        .accessibilityIdentifier(
                            "account-alias-\(provider.rawValue)"
                        )
                    }
                    if acceptsAPIKey {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localization.text(.apiKey))
                                .font(.system(size: 11.5, weight: .medium))
                            SecureField(localization.text(.apiKey), text: $key)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(localization.text(.apiKey))
                                .accessibilityIdentifier(
                                    "account-key-\(provider.rawValue)"
                                )
                        }
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(localization.text(.cancel)) {
                            isAddingAccount = false
                            key = ""
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(
                            "close-add-account-\(provider.rawValue)"
                        )
                        Button(
                            localization.text(
                                acceptsAPIKey
                                    ? .addAccount
                                    : .additionalAccountLogin
                            ),
                            action: onAdd
                        )
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAdd)
                        .accessibilityIdentifier(
                            "add-account-\(provider.rawValue)"
                        )
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    isAddingAccount = true
                    isAliasFocused = true
                } label: {
                    Label(localization.text(.addAccount), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.vertical, 4)
                .disabled(additionAvailability != .offered)
                .accessibilityIdentifier(
                    "begin-add-account-\(provider.rawValue)"
                )
            }
        }
        .onChange(of: rows.count) { oldCount, newCount in
            if newCount > oldCount {
                isAddingAccount = false
            }
        }
        .onChange(of: rows.map(\.id)) { _, identities in
            if let aliasEdit, !identities.contains(aliasEdit.identity) {
                self.aliasEdit = nil
            }
        }
        .onChange(of: additionAvailability) { _, availability in
            if availability == .hidden {
                isAddingAccount = false
            }
        }
    }

    /// One explicit row per account. The primary row never repeats the
    /// header's connection controls: it names the account, shows the masked
    /// identity when one is known, and hosts the account-scoped Codex tier.
    @ViewBuilder
    private func accountRow(
        _ row: ProviderAccountRowPresentation
    ) -> some View {
        let roleText = localization.text(row.role.stringKey)
        VStack(alignment: .leading, spacing: 8) {
            if let edit = aliasEdit, edit.identity == row.identity {
                HStack(spacing: 8) {
                    roleBadge(row, roleText: roleText)
                    TextField(
                        localization.text(.accountAliasExample),
                        text: Binding(
                            get: { aliasEdit?.draft ?? "" },
                            set: { aliasEdit?.draft = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedAliasEdit, equals: row.identity)
                    .onSubmit(saveAlias)
                    .accessibilityLabel(localization.text(.accountAlias))
                    .accessibilityIdentifier(
                        AccountSettingsAccessibility.identifier(
                            .aliasField,
                            for: row.identity
                        )
                    )
                    Button(localization.text(.cancel)) {
                        aliasEdit = nil
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(
                        AccountSettingsAccessibility.identifier(
                            .cancelAlias,
                            for: row.identity
                        )
                    )
                    Button(localization.text(.save), action: saveAlias)
                        .buttonStyle(.borderedProminent)
                        .disabled(!edit.canSave)
                        .accessibilityIdentifier(
                            AccountSettingsAccessibility.identifier(
                                .saveAlias,
                                for: row.identity
                            )
                        )
                }
                .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    roleBadge(row, roleText: roleText)
                    Text(row.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityLabel(row.label)
                        .accessibilityIdentifier(
                            AccountSettingsAccessibility.identifier(
                                .name,
                                for: row.identity
                            )
                        )
                    if let maskedIdentity = row.maskedIdentity {
                        Text(maskedIdentity)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityLabel(
                                localization.format(
                                    .accountIdentity,
                                    maskedIdentity
                                )
                            )
                            .accessibilityIdentifier(
                                AccountSettingsAccessibility.identifier(
                                    .identity,
                                    for: row.identity
                                )
                            )
                    }
                    Spacer(minLength: 8)
                    Button {
                        aliasEdit = AccountAliasEdit(
                            identity: row.identity,
                            savedLabel: row.label
                        )
                        focusedAliasEdit = row.identity
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .disabled(aliasEdit != nil)
                    .help(localization.format(.editAccountAlias, row.label))
                    .accessibilityLabel(
                        localization.format(.editAccountAlias, row.label)
                    )
                    .accessibilityIdentifier(
                        AccountSettingsAccessibility.identifier(
                            .editAlias,
                            for: row.identity
                        )
                    )
                    if row.canRemove {
                        Button {
                            onRemove(row.identity)
                        } label: {
                            Text(localization.text(.delete))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .accessibilityLabel(
                            localization.format(.removeAccount, row.label)
                        )
                        .accessibilityIdentifier(
                            AccountSettingsAccessibility.identifier(
                                .removeAccount,
                                for: row.identity
                            )
                        )
                    }
                }
            }
            connectionControls(row)
            if row.role == .primary {
                primaryCredentials()
            }
            if row.canRemove, let source = row.source {
                Text(localization.text(source.stringKey))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if row.showsCodexTier,
               let tier = codexPlanMultiplier?(row.identity)
            {
                HStack {
                    Text(localization.text(.codexUsageTier))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Picker(
                        localization.format(.accountCodexUsageTier, row.label),
                        selection: tier
                    ) {
                        ForEach(CodexPlanMultiplier.allCases) {
                            Text(localization.providerText($0.title))
                                .tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 108)
                    .accessibilityLabel(
                        localization.format(.accountCodexUsageTier, row.label)
                    )
                    .accessibilityIdentifier(
                        AccountSettingsAccessibility.identifier(
                            .codexTier,
                            for: row.identity
                        )
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AccountSettingsAccessibility.accessibleName(
                roleText: roleText,
                label: row.label,
                maskedIdentity: row.maskedIdentity
            )
        )
        .accessibilityIdentifier(
            AccountSettingsAccessibility.identifier(.row, for: row.identity)
        )
    }

    private func roleBadge(
        _ row: ProviderAccountRowPresentation,
        roleText: String
    ) -> some View {
        Text(roleText)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        Color(nsColor: .separatorColor),
                        lineWidth: 0.5
                    )
            }
            .fixedSize()
            .accessibilityIdentifier(
                AccountSettingsAccessibility.identifier(
                    .role(row.role),
                    for: row.identity
                )
            )
    }

    /// Explicit save: the draft is validated, then handed to the registry;
    /// only an accepted label closes the editor.
    private func saveAlias() {
        guard let edit = aliasEdit, edit.canSave else { return }
        let outcome = edit.commit { try onRename(edit.identity, $0) }
        onAliasOutcome(outcome)
        if case .saved = outcome {
            aliasEdit = nil
        }
    }

    private var acceptsAPIKey: Bool {
        ProviderSetup.descriptor(for: provider)?.acceptsAPIKey == true
    }

    private var canAdd: Bool {
        additionAvailability == .offered
            && !label.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
            && (
                !acceptsAPIKey
                    || !key.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            )
    }
}

@Observable
@MainActor
final class WebDashboardQRCodeLoader {
    enum Phase: Equatable {
        case loading
        case ready(Data)
    }

    private(set) var phase: Phase = .loading
    @ObservationIgnored
    private let generator: @Sendable (URL) async -> Data?

    init(_ generator: @escaping @Sendable (URL) async -> Data?) {
        self.generator = generator
    }

    init() {
        generator = { url in
            await Task.detached(priority: .userInitiated) {
                Self.makeQRCodePNGData(for: url)
            }.value
        }
    }

    func load(url: URL) async {
        phase = .loading
        let data = await generator(url)
        guard !Task.isCancelled, let data else { return }
        phase = .ready(data)
    }

    nonisolated private static func makeQRCodePNGData(
        for url: URL
    ) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }
        filter.setValue(
            Data(url.absoluteString.utf8),
            forKey: "inputMessage"
        )
        filter.setValue("Q", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let quietZone = TailscaleQRCodeVisualTokens.quietZoneModules
        let canvas = CGRect(
            x: 0,
            y: 0,
            width: output.extent.width + quietZone * 2,
            height: output.extent.height + quietZone * 2
        )
        let translated = output.transformed(
            by: CGAffineTransform(
                translationX: quietZone,
                y: quietZone
            )
        )
        let background = CIImage(
            color: CIColor(red: 1, green: 1, blue: 1)
        ).cropped(to: canvas)
        let padded = translated.composited(over: background)
        let scale = TailscaleQRCodeVisualTokens.moduleScale
        let scaled = padded.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        return CIContext().pngRepresentation(
            of: scaled,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }
}

private struct WebDashboardQRCodeView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLocalization) private var localization
    @State private var qrCodeLoader = WebDashboardQRCodeLoader()

    var body: some View {
        VStack(spacing: 14) {
            Text(
                localization.text(
                    AppStringKey.webDashboardQRCodeTitle
                )
            )
                .font(.system(size: 18, weight: .bold))

            switch qrCodeLoader.phase {
            case .loading:
                ProgressView(localization.text(.inProgress))
                    .frame(width: 184, height: 184)
            case .ready(let data):
                if let qrCode = NSImage(data: data) {
                    Image(nsImage: qrCode)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(width: 184, height: 184)
                        .accessibilityLabel(
                            localization.text(.webDashboardQRCodeLabel)
                        )

                    Text(
                        localization.text(
                            .webDashboardQRCodeDescription
                        )
                    )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(url.absoluteString)
                        .font(.system(size: 10.5, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(localization.text(.confirm)) {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else {
                    ProgressView(localization.text(.inProgress))
                        .frame(width: 184, height: 184)
                }
            }
        }
        .padding(20)
        .frame(width: 320)
        .task(id: url) {
            await qrCodeLoader.load(url: url)
        }
    }
}

enum TailscaleQRCodeVisualTokens {
    static let quietZoneModules: CGFloat = 4
    static let moduleScale: CGFloat = 8
}

private struct WebDashboardShareAnchor: NSViewRepresentable {
    let resolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            resolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            resolve(nsView)
        }
    }
}

private struct WebDashboardSettingsRow: View {
    let status: WebDashboardStatus
    @Bindable var tailscaleController: TailscaleDashboardController
    let onOpen: () -> Void
    let onOpenQRCode: () -> Void
    let onShareLink: (NSView) -> Void
    let onRetry: () -> Void
    @Environment(\.appLocalization) private var localization
    @State private var shareAnchorView: NSView?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(localization.text(.webDashboard))
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(statusLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                    Text(localization.text(.webDashboardDescription))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status.url.absoluteString)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(endpointDetails)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "Tailscale · \(tailscaleStatusLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(tailscaleStatusColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure = status.failure {
                        Text(failureMessage(failure))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Button(buttonTitle, action: buttonAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(status.state == .starting)
                        .accessibilityIdentifier(
                            "open-web-dashboard"
                        )

                    if let tailscaleButtonTitle {
                        Button(
                            tailscaleButtonTitle,
                            action: tailscaleButtonAction
                        )
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isTailscaleBusy)
                        .accessibilityLabel(tailscaleButtonTitle)
                        .accessibilityIdentifier(
                            "toggle-tailscale-dashboard-access"
                        )
                    }
                }
            }

            if status.state == .ready,
               isTailscaleReady
            {
                HStack(spacing: 6) {
                    Spacer()
                    Button(
                        localization.text(.openQRCode),
                        action: onOpenQRCode
                    )
                    .accessibilityIdentifier(
                        "open-dashboard-qr-code"
                    )

                    Button(
                        localization.text(.shareLink),
                        action: {
                            guard let shareAnchorView else { return }
                            onShareLink(shareAnchorView)
                        }
                    )
                    .accessibilityIdentifier(
                        "share-dashboard-link"
                    )
                    .background {
                        WebDashboardShareAnchor { view in
                            if shareAnchorView !== view {
                                shareAnchorView = view
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
        }
    }

    private var statusLabel: String {
        switch status.state {
        case .disabled:
            localization.text(.webDashboardDisabled)
        case .starting:
            localization.text(.webDashboardStarting)
        case .ready:
            localization.text(.webDashboardReady)
        case .failed:
            localization.text(.webDashboardFailed)
        }
    }

    private var statusIcon: String {
        switch status.state {
        case .disabled: "globe"
        case .starting: "hourglass"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch status.state {
        case .disabled, .starting: .secondary
        case .ready: .green
        case .failed: .orange
        }
    }

    private var tailscaleStatusLabel: String {
        switch tailscaleController.state {
        case .checking:
            localization.text(.checking)
        case .unavailable:
            localization.text(.unavailable)
        case .signedOut:
            localization.text(.notConnected)
        case .available:
            localization.text(.webDashboardReady)
        case .enabling, .disabling:
            localization.text(.inProgress)
        case .ready:
            localization.text(.connected)
        case .failed:
            localization.text(.checkFailed)
        }
    }

    private var tailscaleStatusColor: Color {
        switch tailscaleController.state {
        case .ready: .green
        case .failed: .orange
        case .checking, .unavailable, .signedOut, .available,
             .enabling, .disabling:
            .secondary
        }
    }

    private var tailscaleButtonTitle: String? {
        let action: String
        switch tailscaleController.state {
        case .available:
            action = localization.text(.startConnection)
        case .ready:
            return nil
        case .checking, .enabling, .disabling:
            action = localization.text(.inProgress)
        case .unavailable, .signedOut, .failed:
            action = localization.text(.retry)
        }
        return "Tailscale · \(action)"
    }

    private var tailscaleButtonAction: () -> Void {
        switch tailscaleController.state {
        case .available:
            { Task { await tailscaleController.enable() } }
        case .ready:
            {}
        case .unavailable, .signedOut, .failed:
            { Task { await tailscaleController.refresh() } }
        case .checking, .enabling, .disabling:
            {}
        }
    }

    private var isTailscaleBusy: Bool {
        switch tailscaleController.state {
        case .checking, .enabling, .disabling:
            true
        case .unavailable, .signedOut, .available, .ready, .failed:
            false
        }
    }

    private var isTailscaleReady: Bool {
        if case .ready = tailscaleController.state {
            return true
        }
        return false
    }

    private var buttonTitle: String {
        switch status.state {
        case .ready:
            localization.text(.openWebDashboard)
        case .starting:
            localization.text(.webDashboardStarting)
        case .disabled, .failed:
            localization.text(.retry)
        }
    }

    private var buttonAction: () -> Void {
        status.state == .ready ? onOpen : onRetry
    }

    private var endpointDetails: String {
        if status.url.scheme == "https" {
            return localization.format(
                .webDashboardTailscaleEndpointDetails,
                String(status.url.port ?? 443),
                String(status.port)
            )
        }
        return localization.format(
            .webDashboardEndpointDetails,
            String(status.port)
        )
    }

    private func failureMessage(
        _ failure: WebDashboardListenerFailure
    ) -> String {
        switch failure {
        case .portInUse(let port):
            localization.format(.webDashboardPortInUse, String(port))
        case .permissionDenied(let port):
            localization.format(
                .webDashboardPermissionDenied,
                String(port)
            )
        case .unavailable(let port):
            localization.format(.webDashboardUnavailable, String(port))
        }
    }
}

private struct AppUpdateSettingsRow: View {
    let controller: AppUpdateController
    @Environment(\.appLocalization) private var localization

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(localization.text(.appUpdates))
                    .font(.system(size: 13.5, weight: .semibold))
                if let version = controller.installedVersion {
                    Text(localization.format(.appUpdateVersion, version))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Text(localization.text(
                    controller.isAvailable
                        ? .appUpdatesDescription
                        : .appUpdatesUnavailable
                ))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(
                localization.text(.checkForAppUpdates),
                action: controller.checkForUpdates
            )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!controller.canCheckForUpdates)
                .accessibilityIdentifier("check-for-app-updates")
        }
        .padding(10)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    Color(nsColor: .separatorColor),
                    lineWidth: 0.5
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-update-settings")
    }
}

enum SettingsRowVisualTokens {
    static let usesSemanticSystemColors = true

    static let background = Color(nsColor: .controlBackgroundColor)

    static let border = Color(nsColor: .separatorColor)
}

enum ProviderConnectionControl: Equatable, Hashable {
    case connect
    case disconnect
    case reconnect
    case retry
    case checkAgainConnection
    case cancelConnection

    @MainActor
    static func performRetry(
        provider: ProviderID,
        refresh: (ProviderID) -> Void
    ) {
        refresh(provider)
    }

    @MainActor
    static func performConnect(
        provider: ProviderID,
        startConnection: (ProviderID) -> Void,
        startGuardedCodexConnection: (ProviderID) -> Void
    ) {
        if provider == .codex {
            startGuardedCodexConnection(provider)
        } else {
            startConnection(provider)
        }
    }

    @MainActor
    static func performReconnect(
        provider: ProviderID,
        reenable: (ProviderID) -> Void,
        startConnection: (ProviderID) -> Void,
        launchOfficialLogin: (ProviderID) -> Void
    ) {
        reenable(provider)
        if provider == .claude {
            launchOfficialLogin(provider)
        } else {
            startConnection(provider)
        }
    }

    /// A guarded companion login stays on screen until the credential
    /// actually changes, so the waiting card keeps its own Check Again and
    /// Cancel controls instead of the control that started it.
    static func resolve(
        availability: ProviderAvailability?,
        isDisconnected: Bool,
        isAwaitingCredential: Bool = false
    ) -> [ProviderConnectionControl] {
        if isAwaitingCredential {
            return [.checkAgainConnection, .cancelConnection]
        }
        if isDisconnected {
            return [.reconnect]
        }
        switch availability {
        case nil, .authenticationRequired:
            return [.connect]
        case .failed, .schemaChanged:
            return [.retry, .disconnect]
        case .available, .unavailable:
            return [.disconnect]
        }
    }
}

private struct ProviderSettingsRow: View {
    let provider: ProviderID
    let viewModel: UsageDashboardViewModel
    let connectionPresentation: ProviderConnectionPresentationState?
    let connectionControlsDisabled: Bool
    @Binding var keyDraft: String
    let keySource: ProviderKeyStorageSource?
    let needsLegacyCleanup: Bool
    let onCleanupLegacy: () -> Void
    let onSetup: () -> Void
    let onSave: () -> Void
    let onRemove: () -> Void
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onRetry: () -> Void
    let accounts: [ProviderAccountRowPresentation]
    @Binding var newAccountLabel: String
    @Binding var newAccountKey: String
    let onAddAccount: () -> Void
    let onRemoveAccount: (AccountProviderID) -> Void
    let onRenameAccount: (AccountProviderID, String) throws -> Void
    let onAliasOutcome: (AccountAliasEdit.Outcome) -> Void
    let additionAvailability: ProviderAccountAdditionAvailability
    let onCheckAgain: () -> Void
    let onCancelAddition: () -> Void
    let isAwaitingConnectionCredential: Bool
    let onCheckAgainConnection: () -> Void
    let onCancelConnection: () -> Void
    let browserConnectionTarget: DevinBrowserConnectionTarget?
    let kiroConnectionTarget: KiroBrowserConnectionTarget?
    let onBrowserConnect: (AccountProviderID) -> Void
    let onKiroConnect: (AccountProviderID) -> Void
    let codexPlanMultiplier:
        ((AccountProviderID) -> Binding<CodexPlanMultiplier>)?

    @State private var isHelpPresented = false
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider)
                    .frame(width: 24, height: 24)
                Text(provider.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                Button {
                    isHelpPresented = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help(localization.text(.setupHelp))
                .accessibilityLabel(
                    localization.text(.setupHelp)
                )
                .popover(isPresented: $isHelpPresented, arrowEdge: .trailing) {
                    ProviderHelpPopover(
                        provider: provider,
                        help: descriptor.help
                    )
                }
            }

            Text(
                localization.providerText(
                    descriptor.instruction
                )
            )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ProviderAccountsSection(
                provider: provider,
                rows: accounts,
                additionAvailability: additionAvailability,
                label: $newAccountLabel,
                key: $newAccountKey,
                onAdd: onAddAccount,
                onRemove: onRemoveAccount,
                onRename: onRenameAccount,
                onAliasOutcome: onAliasOutcome,
                codexPlanMultiplier: codexPlanMultiplier,
                onCheckAgain: onCheckAgain,
                onCancelAddition: onCancelAddition,
                connectionControls: accountConnectionControls,
                primaryCredentials: { primaryCredentialControls }
            )
        }
        .padding(10)
        .background(
            SettingsRowVisualTokens.background,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsRowVisualTokens.border, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func accountConnectionControls(
        _ row: ProviderAccountRowPresentation
    ) -> some View {
        let primary = row.role == .primary
        let availability = viewModel.accountConnectionStates[row.identity]
        let disconnected = viewModel.isDisconnected(row.identity)
        let waiting = provider == .kiro
            ? kiroConnectionTarget == .existing(row.identity)
            : provider == .devin
            ? browserConnectionTarget == .existing(row.identity)
            : primary && isAwaitingConnectionCredential
        let suffix = "\(provider.rawValue)-\(row.identity.accountID.rawValue)"
        HStack(spacing: 8) {
            ConnectionBadge(
                availability: disconnected ? .authenticationRequired : availability,
                presentation: waiting ? .waitingForCredential : primary ? connectionPresentation : nil,
                waitingForBrowser: provider == .kiro
            )
            .accessibilityIdentifier("account-connection-status-\(suffix)")
            Spacer(minLength: 8)
            ForEach(
                ProviderConnectionControl.resolve(
                    availability: availability,
                    isDisconnected: disconnected,
                    isAwaitingCredential: waiting
                ),
                id: \.self
            ) { control in
                switch control {
                case .connect:
                    if provider == .kiro {
                        Button(localization.text(.startConnection)) { onKiroConnect(row.identity) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("account-connect-\(suffix)")
                    } else if provider == .devin {
                        Button(localization.text(.startConnection)) { onBrowserConnect(row.identity) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("account-connect-\(suffix)")
                    } else if !primary {
                        Button(localization.text(.refresh)) {
                            Task { await viewModel.retryAccountProvider(row.identity) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("account-retry-connection-\(suffix)")
                    } else if !descriptor.acceptsAPIKey {
                        Button(localization.text(.startConnection), action: onSetup)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("account-connect-\(suffix)")
                    }
                case .disconnect:
                    Button(localization.text(.disconnect)) {
                        if primary { onDisconnect() }
                        else { viewModel.disconnectAccountProvider(row.identity) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .accessibilityIdentifier("account-disconnect-\(suffix)")
                case .reconnect:
                    Button(localization.text(.reconnectProvider)) {
                        if provider == .kiro { onKiroConnect(row.identity) }
                        else if provider == .devin { onBrowserConnect(row.identity) }
                        else if primary && !descriptor.acceptsAPIKey { onReconnect() }
                        else {
                            viewModel.reconnectAccountProvider(row.identity)
                            Task { await viewModel.retryAccountProvider(row.identity) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("account-reconnect-\(suffix)")
                case .retry:
                    Button(localization.text(.refresh)) {
                        if primary { onRetry() }
                        else {
                            Task { await viewModel.retryAccountProvider(row.identity) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("account-retry-connection-\(suffix)")
                case .checkAgainConnection:
                    if provider != .devin && provider != .kiro { Button(
                        localization.text(.checkAgainForCompanionCredentials),
                        action: onCheckAgainConnection
                    )
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("account-check-again-connection-\(suffix)")
                    }
                case .cancelConnection:
                    Button(localization.text(.cancel), action: onCancelConnection)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("account-cancel-connection-\(suffix)")
                }
            }
            .controlSize(.small)
            .disabled(connectionControlsDisabled && !waiting)
        }
        if waiting {
            Text(localization.text(provider == .devin || provider == .kiro
                ? .waitingForBrowserLogin : .waitingForCompanionCredentials))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("connection-waiting-\(provider.rawValue)")
        }
    }

    @ViewBuilder
    private var primaryCredentialControls: some View {
        if descriptor.acceptsAPIKey {
            if let keySource {
                HStack(spacing: 8) {
                    Text(localization.text(keySource.stringKey))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    if needsLegacyCleanup {
                        Button(
                            localization.text(.retryLegacyKeyCleanup),
                            action: onCleanupLegacy
                        )
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                }
            }
            HStack(spacing: 8) {
                SecureField(localization.text(.apiKey), text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                Button(localization.text(.save), action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                Button(localization.text(.delete), action: onRemove)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }

    private var descriptor: ProviderSetupDescriptor {
        ProviderSetup.descriptor(for: provider)!
    }

}

private extension ProviderKeyStorageSource {
    var stringKey: AppStringKey {
        switch self {
        case .environment: .keySourceEnvironment
        case .keychain: .keySourceKeychain
        case .legacyFile: .keySourceLegacyFile
        }
    }
}

private struct ProviderHelpPopover: View {
    let provider: ProviderID
    let help: ProviderHelpContent
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider)
                    .frame(width: 28, height: 28)
                Text(
                    localization.format(
                        .providerConnectionMethod,
                        provider.displayName
                    )
                )
                    .font(.system(size: 15, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(
                    Array(help.instructions.enumerated()),
                    id: \.offset
                ) { index, instruction in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                        Text(
                            localization.providerText(instruction)
                        )
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                }
            }

            Divider()

            Link(destination: help.officialURL) {
                Label(
                    localization.text(.openOfficialGuide),
                    systemImage: "arrow.up.right.square"
                )
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

private struct ConnectionBadge: View {
    let availability: ProviderAvailability?
    let presentation: ProviderConnectionPresentationState?
    var waitingForBrowser = false
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(label)
    }

    private var label: String {
        switch presentation {
        case .companionRequired:
            localization.text(.companionRequired)
        case .waitingForCredential:
            waitingForBrowser
                ? localization.providerText("로그인 대기 중")
                : localization.text(.waitingForCompanionCredentials)
        case .authenticated, .failed, nil:
            switch availability {
            case .available: localization.text(.connected)
            case .failed, .schemaChanged:
                localization.text(.checkFailed)
            case .authenticationRequired, .unavailable:
                localization.text(.notConnected)
            case nil: localization.text(.checking)
            }
        }
    }

    private var color: Color {
        switch presentation {
        case .companionRequired, .waitingForCredential:
            .secondary
        case .authenticated, .failed, nil:
            switch availability {
            case .available: .green
            case .failed, .schemaChanged: .orange
            case .authenticationRequired, .unavailable: .secondary
            case nil: .secondary.opacity(0.6)
            }
        }
    }
}
