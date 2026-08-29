import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    let localization: LocalizationController
    let onLanguageChange: () -> Void
    let onPresentationStyleChange: (DashboardPresentationStyle) -> Void
    let onSideNotchHideDelayChange: (SideNotchHideDelay) -> Void
    @State private var keyDrafts: [ProviderID: String] = [:]
    @State private var feedback: LocalizedText?
    @State private var setupError: ProviderSetupError?
    @State private var launchAtLogin = LaunchAtLoginController()
    @State private var codexPlanMultiplier = CodexPlanMultiplierStore(
        defaults: .standard
    ).load()
    @State private var presentationStyle: DashboardPresentationStyle
    @State private var sideNotchHideDelay: SideNotchHideDelay

    init(
        viewModel: UsageDashboardViewModel,
        localization: LocalizationController,
        presentationStyle: DashboardPresentationStyle,
        sideNotchHideDelay: SideNotchHideDelay,
        onLanguageChange: @escaping () -> Void,
        onPresentationStyleChange:
            @escaping (DashboardPresentationStyle) -> Void,
        onSideNotchHideDelayChange:
            @escaping (SideNotchHideDelay) -> Void
    ) {
        self.viewModel = viewModel
        self.localization = localization
        self.onLanguageChange = onLanguageChange
        self.onPresentationStyleChange = onPresentationStyleChange
        self.onSideNotchHideDelayChange =
            onSideNotchHideDelayChange
        _presentationStyle = State(initialValue: presentationStyle)
        _sideNotchHideDelay = State(initialValue: sideNotchHideDelay)
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
                        .frame(width: 180)
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
                        .frame(width: 240)
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

                    LaunchAtLoginSettingsRow(
                        controller: launchAtLogin
                    )

                    Text(localization.text(.providerAuthentication))
                        .font(.system(size: 14, weight: .bold))
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                        .padding(.top, 4)

                    ForEach(
                        Array(viewModel.providerOrder.enumerated()),
                        id: \.element
                    ) {
                        index,
                        provider in
                        ProviderSettingsRow(
                            provider: provider,
                            availability: viewModel.connectionStates[
                                provider
                            ],
                            keyDraft: binding(for: provider),
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
                                Task { await viewModel.refresh() }
                            },
                            canMoveUp: index > 0,
                            canMoveDown:
                                index < viewModel.providerOrder.count - 1,
                            codexPlanMultiplier:
                                provider == .codex
                                    ? $codexPlanMultiplier
                                    : nil,
                            onMoveUp: {
                                viewModel.moveProvider(provider, by: -1)
                            },
                            onMoveDown: {
                                viewModel.moveProvider(provider, by: 1)
                            }
                        )
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                if let feedback {
                    Text(localization.resolve(feedback))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(localization.text(.reconnect)) {
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
        .onAppear {
            launchAtLogin.refresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            launchAtLogin.refresh()
            Task { await viewModel.refresh() }
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

    private func binding(
        for provider: ProviderID
    ) -> Binding<String> {
        Binding(
            get: { keyDrafts[provider, default: ""] },
            set: { keyDrafts[provider] = $0 }
        )
    }

    private func startConnection(for provider: ProviderID) {
        switch ProviderSetup.perform(for: provider) {
        case .success(.launched):
            feedback = .formatted(
                .openedConnection,
                provider.displayName
            )
        case .success(.openedFallback):
            feedback = .formatted(
                .openedOfficialAuthentication,
                provider.displayName
            )
        case .failure(let error):
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
            startConnection: startConnection,
            refresh: viewModel.refresh
        )
        feedback = .formatted(
            .reconnectedProvider,
            provider.displayName
        )
    }

    private func saveKey(for provider: ProviderID) {
        guard let store = ProviderAPIKeyStore.live(for: provider) else {
            return
        }
        do {
            try store.save(keyDrafts[provider, default: ""])
            keyDrafts[provider] = ""
            feedback = .formatted(
                .savedKey,
                provider.displayName
            )
            Task { await viewModel.refresh() }
        } catch {
            feedback = .key(.saveKeyFailed)
        }
    }

    private func removeKey(for provider: ProviderID) {
        guard let store = ProviderAPIKeyStore.live(for: provider) else {
            return
        }
        do {
            try store.remove()
            keyDrafts[provider] = ""
            feedback = .formatted(
                .removedKey,
                provider.displayName
            )
            Task { await viewModel.refresh() }
        } catch {
            feedback = .key(.removeKeyFailed)
        }
    }
}

private struct LaunchAtLoginSettingsRow: View {
    @Bindable var controller: LaunchAtLoginController
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "power.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localization.text(.launchAtLogin))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(localization.launchStatus(controller.state))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle(
                    localization.text(.launchAtLogin),
                    isOn: Binding(
                        get: { controller.isEnabled },
                        set: { controller.setEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(
                    localization.text(.launchAtLogin)
                )
            }

            if controller.errorMessage != nil {
                Text(localization.text(.launchChangeFailed))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.red)
            }

            if controller.showsSystemSettingsButton {
                Button(
                    localization.text(.openLoginItems),
                    action: controller.openSystemSettings
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
    @discardableResult
    static func performReconnect(
        provider: ProviderID,
        reenable: @escaping (ProviderID) -> Void,
        startConnection: @escaping (ProviderID) -> Void,
        refresh: @escaping () async -> Void
    ) -> Task<Void, Never> {
        reenable(provider)
        startConnection(provider)
        return Task {
            await refresh()
        }
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
        case .failed:
            return [.retry, .disconnect]
        case .available, .unavailable:
            return [.disconnect]
        }
    }
}

private struct ProviderSettingsRow: View {
    let provider: ProviderID
    let availability: ProviderAvailability?
    @Binding var keyDraft: String
    let onSetup: () -> Void
    let onSave: () -> Void
    let onRemove: () -> Void
    let isDisconnected: Bool
    let onDisconnect: () -> Void
    let onReconnect: () -> Void
    let onRetry: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool
    let codexPlanMultiplier: Binding<CodexPlanMultiplier>?
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

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
                ConnectionBadge(availability: availability)
                HStack(spacing: 2) {
                    moveButton(
                        symbol: "chevron.up",
                        label: localization.format(
                            .moveUp,
                            provider.displayName
                        ),
                        isEnabled: canMoveUp,
                        action: onMoveUp
                    )
                    moveButton(
                        symbol: "chevron.down",
                        label: localization.format(
                            .moveDown,
                            provider.displayName
                        ),
                        isEnabled: canMoveDown,
                        action: onMoveDown
                    )
                }
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

    private func moveButton(
        symbol: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .help(label)
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
        switch availability {
        case .available: localization.text(.connected)
        case .failed: localization.text(.checkFailed)
        case .authenticationRequired, .unavailable:
            localization.text(.notConnected)
        case nil: localization.text(.checking)
        }
    }

    private var color: Color {
        switch availability {
        case .available: .green
        case .failed: .orange
        case .authenticationRequired, .unavailable: .secondary
        case nil: .secondary.opacity(0.6)
        }
    }
}
