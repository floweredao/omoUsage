import OmoUsageCore
import AppKit
import CoreImage
import Observation
import SwiftUI

struct PhonePairingPresentationState {
    struct PresentedItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var presentedItem: PresentedItem?

    mutating func pairButtonAtomicallyCreatesPresentedItem(
        _ makeURL: () -> URL?
    ) -> AppStringKey? {
        guard let url = makeURL() else {
            presentedItem = nil
            return .phonePairingFailed
        }
        presentedItem = PresentedItem(url: url)
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
    let onCreatePhonePairingURL: () -> URL?
    let onRetryWebDashboard: () -> Void
    let onExportDiagnostics: () -> DiagnosticExportOutcome
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
    @State private var codexPlanMultiplier = CodexPlanMultiplierStore(
        defaults: .standard
    ).load()
    @State private var presentationStyle: DashboardPresentationStyle
    @State private var sideNotchHideDelay: SideNotchHideDelay
    @State private var phonePairingPresentation =
        PhonePairingPresentationState()

    init(
        viewModel: UsageDashboardViewModel,
        localization: LocalizationController,
        presentationStyle: DashboardPresentationStyle,
        sideNotchHideDelay: SideNotchHideDelay,
        accountRegistryController: ProviderAccountRegistryController,
        captureCompanionCredential: @escaping (ProviderID) throws -> String =
            SettingsView.captureCompanionCredential,
        launchCompanion: @escaping (ProviderID) -> Result<
            ProviderSetupOutcome,
            ProviderSetupError
        > = { ProviderSetup.perform(for: $0) },
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
        onCreatePhonePairingURL: @escaping () -> URL?,
        onRetryWebDashboard: @escaping () -> Void,
        onExportDiagnostics: @escaping () -> DiagnosticExportOutcome
    ) {
        self.viewModel = viewModel
        self.localization = localization
        self.accountRegistryController = accountRegistryController
        self.onRegistryChange = onRegistryChange
        self.onLanguageChange = onLanguageChange
        self.onPresentationStyleChange = onPresentationStyleChange
        self.onSideNotchHideDelayChange =
            onSideNotchHideDelayChange
        self.webDashboardStatusStore = webDashboardStatusStore
        self.tailscaleDashboardController =
            tailscaleDashboardController
        self.onOpenWebDashboard = onOpenWebDashboard
        self.onCreatePhonePairingURL = onCreatePhonePairingURL
        self.onRetryWebDashboard = onRetryWebDashboard
        self.onExportDiagnostics = onExportDiagnostics
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

            ScrollView {
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
                        onOpen: {
                            if !onOpenWebDashboard() {
                                feedback = .key(.webDashboardOpenFailed)
                            }
                        },
                        onRetry: onRetryWebDashboard
                    )

                    TailscalePhoneAccessRow(
                        controller: tailscaleDashboardController,
                        onPair: {
                            if let failureKey =
                                phonePairingPresentation
                                .pairButtonAtomicallyCreatesPresentedItem(
                                    onCreatePhonePairingURL
                                ) {
                                feedback = .key(failureKey)
                            }
                        }
                    )

                    DiagnosticsSettingsRow {
                        switch onExportDiagnostics() {
                        case .exported:
                            feedback = .key(.diagnosticsExportSucceeded)
                        case .cancelled:
                            break
                        case .failed:
                            feedback = .key(.diagnosticsExportFailed)
                        }
                    }

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
                                availability: viewModel.connectionStates[
                                    provider
                                ],
                                connectionPresentation:
                                    connectionCoordinator.state(for: provider),
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
                                    startConnection(for: provider)
                                },
                                onSave: { saveKey(for: provider) },
                                onRemove: { removeKey(for: provider) },
                                isDisconnected:
                                    viewModel.isDisconnected(provider),
                                onDisconnect: {
                                    disconnectProvider(provider)
                                },
                                onReconnect: {
                                    reconnectProvider(provider)
                                },
                                onRetry: {
                                    Task {
                                        await viewModel.retryProvider(provider)
                                    }
                                },
                                accounts: accountRegistryController.accounts
                                    .filter { $0.provider == provider },
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
                                additionState: additionState(
                                    for: provider
                                ),
                                onCheckAgain: checkForCompanionCredential,
                                onCancelAddition: cancelAddition,
                                codexPlanMultiplier:
                                    provider == .codex
                                        ? $codexPlanMultiplier
                                        : nil
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
        .sheet(item: $phonePairingPresentation.presentedItem) { item in
            TailscalePhonePairingView(url: item.url)
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
            Task {
                await connectionCoordinator.applicationDidBecomeActive(
                    refresh: viewModel.refresh,
                    availability: { provider in
                        viewModel.connectionStates[provider]
                    }
                )
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
        .onChange(of: codexPlanMultiplier) {
            _, multiplier in
            CodexPlanMultiplierStore(defaults: .standard)
                .save(multiplier)
            Task { await viewModel.refresh() }
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

    private func startConnection(for provider: ProviderID) {
        if provider == .claude {
            let outcome: ClaudeKeychainAuthorizationOutcome
            do {
                outcome = try ClaudeKeychainAccessSession.shared
                    .authorizeClaude()
            } catch {
                feedback = .key(.refreshFailed)
                return
            }
            switch ClaudeConnectionAuthorizationPolicy.decision(
                for: outcome
            ) {
            case .refresh:
                feedback = .key(.waitingForCompanionCredentials)
                Task {
                    await ClaudeKeychainAccessSession.shared
                        .withInteractionAllowed {
                            await viewModel.refresh()
                        }
                }
                return
            case .stop:
                feedback = .key(.authenticationRequired)
                return
            case .launchCompanion:
                break
            }
        }
        let result = ProviderSetup.perform(for: provider)
        connectionCoordinator.record(result, for: provider)
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
        viewModel.disconnectProvider(provider)
        feedback = .formatted(
            .disconnectedProvider,
            provider.displayName
        )
    }

    private func reconnectProvider(_ provider: ProviderID) {
        ProviderConnectionControl.performReconnect(
            provider: provider,
            reenable: viewModel.reconnectProvider,
            startConnection: startConnection
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
        additionCoordinator.cancel()
        feedback = nil
    }

    private func additionState(
        for provider: ProviderID
    ) -> ProviderAccountAdditionRowState {
        guard let pending = additionCoordinator.pending else {
            return .idle
        }
        if pending.provider == provider { return .waiting }
        return ProviderSetup.descriptor(for: provider)?.acceptsAPIKey == true
            ? .idle
            : .blockedByOtherAddition
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
}

private struct ProviderAccountsSection: View {
    let provider: ProviderID
    let accounts: [ProviderAccountMetadata]
    @Binding var label: String
    @Binding var key: String
    let onAdd: () -> Void
    let onRemove: (AccountProviderID) -> Void
    let additionState: ProviderAccountAdditionRowState
    let onCheckAgain: () -> Void
    let onCancelAddition: () -> Void
    @Environment(\.appLocalization) private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(accounts) { account in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.label)
                            .font(.system(size: 13.5, weight: .semibold))
                            .accessibilityIdentifier(
                                "account-\(provider.rawValue)-\(account.label)"
                            )
                        if let source = account.source {
                            Text(localization.text(source.stringKey))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Button {
                        onRemove(account.id)
                    } label: {
                        Text(localization.text(.delete))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .accessibilityLabel(
                        localization.format(.removeAccount, account.label)
                    )
                }
            }

            HStack(spacing: 8) {
                TextField(
                    localization.text(.accountAlias),
                    text: $label
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(localization.text(.accountAlias))
                .accessibilityIdentifier(
                    "account-alias-\(provider.rawValue)"
                )
                .disabled(additionState == .waiting)

                if acceptsAPIKey {
                    SecureField(
                        localization.text(.apiKey),
                        text: $key
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(localization.text(.apiKey))
                    .accessibilityIdentifier(
                        "account-key-\(provider.rawValue)"
                    )
                }

                if additionState == .waiting {
                    Button(
                        localization.text(
                            .checkAgainForCompanionCredentials
                        ),
                        action: onCheckAgain
                    )
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "check-again-\(provider.rawValue)"
                    )

                    Button(
                        localization.text(.cancel),
                        action: onCancelAddition
                    )
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        "cancel-addition-\(provider.rawValue)"
                    )
                } else {
                    Button(localization.text(.addAccount), action: onAdd)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canAdd)
                        .accessibilityIdentifier(
                            "add-account-\(provider.rawValue)"
                        )
                }
            }

            if additionState == .waiting {
                Text(
                    localization.text(.waitingForCompanionCredentials)
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "account-waiting-\(provider.rawValue)"
                )
            }
        }
    }

    private var acceptsAPIKey: Bool {
        ProviderSetup.descriptor(for: provider)?.acceptsAPIKey == true
    }

    private var canAdd: Bool {
        additionState == .idle
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

private struct TailscalePhoneAccessRow: View {
    @Bindable var controller: TailscaleDashboardController
    let onPair: () -> Void
    @Environment(\.appLocalization) private var localization

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(localization.text(.phoneAccess))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(statusLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                Text(localization.text(.phoneAccessDescription))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .ready(let host) = controller.state {
                    Text(verbatim:
                        "https://\(host):\(TailscaleCLIService.httpsPort)"
                    )
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Button(primaryButtonTitle, action: primaryAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)

                if case .ready = controller.state {
                    Button(localization.text(.disablePhoneAccess)) {
                        Task { await controller.disable() }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
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
        switch controller.state {
        case .checking:
            localization.text(.phoneAccessChecking)
        case .unavailable:
            localization.text(.phoneAccessUnavailable)
        case .signedOut:
            localization.text(.phoneAccessSignedOut)
        case .available:
            localization.text(.phoneAccessAvailable)
        case .enabling, .disabling:
            localization.text(.inProgress)
        case .ready:
            localization.text(.phoneAccessReady)
        case .failed:
            localization.text(.phoneAccessFailed)
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .ready: .green
        case .failed: .orange
        case .checking, .unavailable, .signedOut, .available,
             .enabling, .disabling:
            .secondary
        }
    }

    private var primaryButtonTitle: String {
        switch controller.state {
        case .available:
            localization.text(.enablePhoneAccess)
        case .ready:
            localization.text(.pairPhone)
        case .checking, .enabling, .disabling:
            localization.text(.inProgress)
        case .unavailable, .signedOut, .failed:
            localization.text(.retry)
        }
    }

    private var primaryAction: () -> Void {
        switch controller.state {
        case .available:
            { Task { await controller.enable() } }
        case .ready:
            onPair
        case .unavailable, .signedOut, .failed:
            { Task { await controller.refresh() } }
        case .checking, .enabling, .disabling:
            {}
        }
    }

    private var isBusy: Bool {
        switch controller.state {
        case .checking, .enabling, .disabling:
            true
        case .unavailable, .signedOut, .available, .ready, .failed:
            false
        }
    }
}

@Observable
@MainActor
final class PhonePairingQRCodeLoader {
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

private struct TailscalePhonePairingView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLocalization) private var localization
    @State private var qrCodeLoader = PhonePairingQRCodeLoader()

    var body: some View {
        VStack(spacing: 14) {
            Text(localization.text(.phonePairingTitle))
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
                            localization.text(.phonePairingQRCodeLabel)
                        )

                    Text(localization.text(.phonePairingDescription))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(url.absoluteString)
                        .font(.system(size: 10.5, design: .monospaced))
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

private struct WebDashboardSettingsRow: View {
    let status: WebDashboardStatus
    let onOpen: () -> Void
    let onRetry: () -> Void
    @Environment(\.appLocalization) private var localization

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(localization.text(.webDashboard))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(statusLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                Text(status.url.absoluteString)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                Text(endpointDetails)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let failure = status.failure {
                    Text(failureMessage(failure))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button(buttonTitle, action: buttonAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(status.state == .starting)
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
                status.url.port ?? 443,
                Int(status.port)
            )
        }
        return localization.format(
            .webDashboardEndpointDetails,
            Int(status.port)
        )
    }

    private func failureMessage(
        _ failure: WebDashboardListenerFailure
    ) -> String {
        switch failure {
        case .portInUse(let port):
            localization.format(.webDashboardPortInUse, Int(port))
        case .permissionDenied(let port):
            localization.format(.webDashboardPermissionDenied, Int(port))
        case .unavailable(let port):
            localization.format(.webDashboardUnavailable, Int(port))
        }
    }
}

enum DiagnosticExportOutcome {
    case exported
    case cancelled
    case failed
}

private struct DiagnosticsSettingsRow: View {
    let onExport: () -> Void
    @Environment(\.appLocalization) private var localization

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(localization.text(.diagnostics))
                    .font(.system(size: 13.5, weight: .semibold))
                Text(localization.text(.diagnosticsDescription))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(
                localization.text(.exportDiagnostics),
                action: onExport
            )
                .buttonStyle(.bordered)
                .controlSize(.small)
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
}

enum SettingsRowVisualTokens {
    static let usesSemanticSystemColors = true

    static func background(isHovered: Bool) -> Color {
        Color(
            nsColor: isHovered
                ? .unemphasizedSelectedContentBackgroundColor
                : .controlBackgroundColor
        )
    }

    static let border = Color(nsColor: .separatorColor)
}

enum ProviderConnectionControl: Equatable, Hashable {
    case connect
    case disconnect
    case reconnect
    case retry

    @MainActor
    static func performReconnect(
        provider: ProviderID,
        reenable: (ProviderID) -> Void,
        startConnection: (ProviderID) -> Void
    ) {
        reenable(provider)
        startConnection(provider)
    }

    static func resolve(
        availability: ProviderAvailability?,
        isDisconnected: Bool
    ) -> [ProviderConnectionControl] {
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
    let availability: ProviderAvailability?
    let connectionPresentation: ProviderConnectionPresentationState?
    @Binding var keyDraft: String
    let keySource: ProviderKeyStorageSource?
    let needsLegacyCleanup: Bool
    let onCleanupLegacy: () -> Void
    let onSetup: () -> Void
    let onSave: () -> Void
    let onRemove: () -> Void
    let isDisconnected: Bool
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onRetry: () -> Void
    let accounts: [ProviderAccountMetadata]
    @Binding var newAccountLabel: String
    @Binding var newAccountKey: String
    let onAddAccount: () -> Void
    let onRemoveAccount: (AccountProviderID) -> Void
    let additionState: ProviderAccountAdditionRowState
    let onCheckAgain: () -> Void
    let onCancelAddition: () -> Void
    let codexPlanMultiplier: Binding<CodexPlanMultiplier>?

    @State private var isHovered = false
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
                ConnectionBadge(
                    availability: availability,
                    presentation: connectionPresentation
                )
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

            HStack(alignment: .center, spacing: 10) {
                Text(
                    localization.providerText(
                        descriptor.instruction
                    )
                )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !descriptor.acceptsAPIKey {
                    ForEach(
                        ProviderConnectionControl.resolve(
                            availability: availability,
                            isDisconnected: isDisconnected
                        ),
                        id: \.self
                    ) { control in
                        switch control {
                        case .connect:
                            Button(
                                localization.text(.startConnection),
                                action: onSetup
                            )
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        case .disconnect:
                            Button(
                                localization.text(.disconnect),
                                action: onDisconnect
                            )
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.red)
                        case .reconnect:
                            Button(
                                localization.text(.reconnectProvider),
                                action: onReconnect
                            )
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        case .retry:
                            Button(
                                localization.text(.refresh),
                                action: onRetry
                            )
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                }
            }

            if let codexPlanMultiplier {
                HStack {
                    Text(localization.text(.codexUsageTier))
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Picker(
                        localization.text(.codexUsageTier),
                        selection: codexPlanMultiplier
                    ) {
                        ForEach(CodexPlanMultiplier.allCases) {
                            Text(
                                localization.providerText($0.title)
                            )
                            .tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 108)
                }
            }

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
                    SecureField(
                        localization.text(.apiKey),
                        text: $keyDraft
                    )
                        .textFieldStyle(.roundedBorder)
                    Button(localization.text(.save), action: onSave)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(
                            keyDraft.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                        )
                    Button(localization.text(.delete), action: onRemove)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Divider()

            ProviderAccountsSection(
                provider: provider,
                accounts: accounts,
                label: $newAccountLabel,
                key: $newAccountKey,
                onAdd: onAddAccount,
                onRemove: onRemoveAccount,
                additionState: additionState,
                onCheckAgain: onCheckAgain,
                onCancelAddition: onCancelAddition
            )
        }
        .padding(10)
        .background(
            SettingsRowVisualTokens.background(isHovered: isHovered),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsRowVisualTokens.border, lineWidth: 0.5)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
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
    }

    private var label: String {
        switch presentation {
        case .companionRequired:
            localization.text(.companionRequired)
        case .waitingForCredential:
            localization.text(.waitingForCompanionCredentials)
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
