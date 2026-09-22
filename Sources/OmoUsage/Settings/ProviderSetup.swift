import OmoUsageCore
import AppKit
import CryptoKit
import Foundation
import Observation

struct ProviderHelpContent: Equatable, Sendable {
    let title: String
    let instructions: [String]
    let officialURL: URL
}

struct TerminalLaunchSpecification: Equatable, Sendable {
    let executable: String
    let arguments: [String]
}

struct ApplicationLaunchSpecification: Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
    let fallbackURL: URL
}

enum ProviderSetupAction: Equatable, Sendable {
    case terminal(
        TerminalLaunchSpecification,
        fallbackURL: URL?
    )
    case terminalAlternatives(
        [TerminalLaunchSpecification],
        fallbackURL: URL?
    )
    case application(ApplicationLaunchSpecification)
    case applicationOrTerminal(
        ApplicationLaunchSpecification,
        [TerminalLaunchSpecification],
        fallbackURL: URL?
    )
    case web(URL)
    case apiKey
    case browserOAuth
}

struct ProviderSetupDescriptor: Equatable, Sendable {
    let instruction: String
    let action: ProviderSetupAction
    let help: ProviderHelpContent

    var acceptsAPIKey: Bool {
        action == .apiKey
    }
}

enum ProviderSetupOutcome: Equatable, Sendable {
    case launched
    case openedFallback(URL)
}

enum ProviderSetupError: LocalizedError, Identifiable, Equatable {
    case companionRequired(ProviderID, [String])
    case unavailable(ProviderID)
    case unableToLaunch(String)
    case unableToOpen(URL)
    case requiredExecutableMissing([String])

    var id: String {
        switch self {
        case .companionRequired(let provider, let companions):
            "companion-\(provider.rawValue)-\(companions.joined(separator: ","))"
        case .unavailable(let provider):
            "unavailable-\(provider.rawValue)"
        case .unableToLaunch(let target):
            "launch-\(target)"
        case .unableToOpen(let url):
            "open-\(url.absoluteString)"
        case .requiredExecutableMissing(let executables):
            "missing-\(executables.joined(separator: ","))"
        }
    }

    var errorDescription: String? {
        switch self {
        case .companionRequired(_, let companions):
            "\(companions.joined(separator: " 또는 ")) 설치가 필요합니다."
        case .unavailable(let provider):
            "\(provider.displayName) 연결 방법을 찾지 못했습니다."
        case .unableToLaunch(let target):
            "\(target)을(를) 열지 못했습니다."
        case .unableToOpen:
            "공식 인증 페이지를 열지 못했습니다."
        case .requiredExecutableMissing(let executables):
            "\(executables.joined(separator: " 또는 ")) 설치가 필요합니다."
        }
    }
}

enum ProviderConnectionPresentationState: Equatable, Sendable {
    case companionRequired
    case waitingForCredential
    case authenticated
    case failed
}

@Observable
@MainActor
final class ProviderConnectionCoordinator {
    private(set) var states: [
        AccountProviderID: ProviderConnectionPresentationState
    ] = [:]
    private var awaitingActivation: Set<AccountProviderID> = []
    private var isCheckingCompletion = false
    @ObservationIgnored private var claudeReceipt: OfficialLoginReceipt?
    private var claudeAttempt: UUID?

    /// Installs the completion observer before handing the command to Terminal.
    /// Neither foreground activation nor a still-valid old credential completes login.
    func startClaudeLogin(
        launch: (OfficialLoginReceipt) -> Result<ProviderSetupOutcome, ProviderSetupError> = {
            ProviderSetup.performClaudeLogin(receipt: $0)
        },
        authorize: @escaping () throws -> ClaudeKeychainAuthorizationOutcome = {
            try ClaudeKeychainAccessSession.shared.authorizeClaude()
        },
        refresh: @escaping () async -> Void,
        availability: @escaping () -> ProviderAvailability?,
        didComplete: @escaping () -> Void = {}
    ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
        cancelClaudeLogin()
        let attempt = UUID()
        claudeAttempt = attempt
        let receipt: OfficialLoginReceipt
        do {
            receipt = try OfficialLoginReceipt { [weak self] succeeded in
                guard let self,
                      self.claudeAttempt == attempt,
                      self.claudeReceipt != nil else { return }
                self.claudeReceipt = nil
                var authorized = false
                if succeeded {
                    do {
                        if case .authorized = try authorize() { authorized = true }
                    } catch {
                        self.record(.failure(.unableToLaunch("claude")), for: .claude)
                    }
                }
                if authorized { await refresh() }
                guard self.claudeAttempt == attempt else { return }
                self.claudeAttempt = nil
                self.states[AccountProviderID(accountID: .legacy, providerID: .claude)] =
                    authorized && availability() == .available ? .authenticated : .failed
                didComplete()
            }
        } catch {
            let result: Result<ProviderSetupOutcome, ProviderSetupError> =
                .failure(.unableToLaunch("claude"))
            claudeAttempt = nil
            record(result, for: .claude)
            return result
        }
        claudeReceipt = receipt
        let result = launch(receipt)
        record(result, for: .claude)
        if result != .success(.launched) {
            claudeReceipt?.cancel()
            claudeReceipt = nil
            claudeAttempt = nil
        }
        return result
    }

    func cancelClaudeLogin() {
        claudeReceipt?.cancel()
        claudeReceipt = nil
        claudeAttempt = nil
        states.removeValue(forKey: AccountProviderID(accountID: .legacy, providerID: .claude))
    }

    func record(
        _ result: Result<ProviderSetupOutcome, ProviderSetupError>,
        for accountProvider: AccountProviderID
    ) {
        switch result {
        case .success(.launched):
            states[accountProvider] = .waitingForCredential
            if accountProvider.providerID != .claude {
                awaitingActivation.insert(accountProvider)
            }
        case .success(.openedFallback):
            states[accountProvider] = .failed
            awaitingActivation.remove(accountProvider)
        case .failure(.companionRequired):
            states[accountProvider] = .companionRequired
            awaitingActivation.remove(accountProvider)
        case .failure:
            states[accountProvider] = .failed
            awaitingActivation.remove(accountProvider)
        }
    }

    func record(
        _ result: Result<ProviderSetupOutcome, ProviderSetupError>,
        for provider: ProviderID
    ) {
        record(
            result,
            for: AccountProviderID(
                accountID: .legacy,
                providerID: provider
            )
        )
    }

    func applicationDidBecomeActive(
        refresh: () async -> Void,
        availability: (AccountProviderID) -> ProviderAvailability?
    ) async {
        guard !isCheckingCompletion else { return }
        let accounts = awaitingActivation
        guard !accounts.isEmpty else { return }
        isCheckingCompletion = true
        defer { isCheckingCompletion = false }
        await refresh()
        for accountProvider in accounts {
            switch availability(accountProvider) {
            case .available:
                states[accountProvider] = .authenticated
                awaitingActivation.remove(accountProvider)
            case .failed, .schemaChanged:
                states[accountProvider] = .failed
                awaitingActivation.remove(accountProvider)
            case .authenticationRequired, .unavailable, nil:
                states[accountProvider] = .waitingForCredential
            }
        }
    }

    func applicationDidBecomeActive(
        refresh: () async -> Void,
        availability: (ProviderID) -> ProviderAvailability?
    ) async {
        await applicationDidBecomeActive(
            refresh: refresh,
            availability: { accountProvider in
                availability(accountProvider.providerID)
            }
        )
    }

    func state(
        for accountProvider: AccountProviderID
    ) -> ProviderConnectionPresentationState? {
        states[accountProvider]
    }

    func state(
        for provider: ProviderID
    ) -> ProviderConnectionPresentationState? {
        state(
            for: AccountProviderID(
                accountID: .legacy,
                providerID: provider
            )
        )
    }
}

/// A private, pre-created receipt watched before Terminal starts. Only the
/// wrapped command's exit status can produce a completion; no credential or
/// activation polling is involved. The receipt contains no authentication data.
final class OfficialLoginReceipt: @unchecked Sendable {
    let url: URL
    private let directory: URL
    private let source: DispatchSourceFileSystemObject
    @MainActor private var finished = false

    @MainActor
    init(completion: @escaping @MainActor (Bool) async -> Void) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsage-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        url = directory.appending(path: "completion")
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_EVTONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw ProviderSetupError.unableToLaunch("claude")
        }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                let value = try? String(contentsOf: self.url, encoding: .utf8)
                guard value == "success\n" || value == "failed\n" || value == nil else { return }
                self.cancel()
                await completion(value == "success\n")
            }
        }
        source.activate()
    }

    /// An inner shell is necessary because Terminal's .command wrapper uses exec.
    /// EXIT also covers interrupted/failed commands; only exit zero emits success.
    func wrapping(_ command: String) -> String {
        let report = """
        result=$?; trap - EXIT; if [ "$result" -eq 0 ]; then printf "success\\n"; else printf "failed\\n"; fi > \(ProviderSetup.shellQuote(url.path))
        """
        let script = """
        trap \(ProviderSetup.shellQuote(report)) EXIT
        trap 'exit 1' HUP INT TERM
        \(command)
        """
        return "/bin/zsh -f -c \(ProviderSetup.shellQuote(script))"
    }

    @MainActor
    func cancel() {
        guard !finished else { return }
        finished = true
        source.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        source.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

enum ProviderAccountAdditionOutcome: Equatable, Sendable {
    case addedAccount(String)
    case waitingForCompanion
    case credentialUnchanged
    case credentialMissing
    case credentialUnavailable
    case invalidLabel
    case openedOfficialGuide(URL)
    case launchFailed(ProviderSetupError)
    case additionInProgress
    case ignored
    case failed
}

/// Owns adding a second account for a companion provider. The companion
/// tool holds exactly one credential at a time, so an account may only be
/// created after official authentication replaced the credential that was
/// there before: persisting the pre-login credential would copy the
/// already-connected account under a new alias.
@Observable
@MainActor
final class ProviderAccountAdditionCoordinator {
    struct PendingCompanionAddition: Equatable, Sendable {
        let provider: ProviderID
        let label: String
        /// Opaque digest of the companion identity (Codex) or credential
        /// when addition started, or `nil` when it held none. Never a secret.
        let credentialFingerprint: String?
    }

    private(set) var pending: PendingCompanionAddition?

    @ObservationIgnored
    private let controller: ProviderAccountRegistryController
    @ObservationIgnored
    private let captureCredential: (ProviderID) throws -> String
    @ObservationIgnored
    private let launchCompanion:
        (ProviderID) -> Result<ProviderSetupOutcome, ProviderSetupError>
    @ObservationIgnored
    private let onAccountAdded: () -> Void

    init(
        controller: ProviderAccountRegistryController,
        captureCredential: @escaping (ProviderID) throws -> String = {
            try CredentialDiscovery.live().captureCredential(
                for: $0,
                now: Date()
            )
        },
        launchCompanion: @escaping (ProviderID) -> Result<
            ProviderSetupOutcome,
            ProviderSetupError
        > = { ProviderSetup.perform(for: $0) },
        onAccountAdded: @escaping () -> Void
    ) {
        self.controller = controller
        self.captureCredential = captureCredential
        self.launchCompanion = launchCompanion
        self.onAccountAdded = onAccountAdded
    }

    var isWaitingForCompanion: Bool { pending != nil }

    func isWaiting(for provider: ProviderID) -> Bool {
        pending?.provider == provider
    }

    @discardableResult
    func addAccount(
        provider: ProviderID,
        label rawLabel: String,
        key: String?
    ) -> ProviderAccountAdditionOutcome {
        guard
            let label = try? ProviderAccountRegistryController
                .validatedAccountLabel(rawLabel)
        else {
            return .invalidLabel
        }
        guard
            ProviderSetup.descriptor(for: provider)?.acceptsAPIKey == false
        else {
            return addAPIKeyAccount(
                provider: provider,
                label: label,
                key: key
            )
        }
        guard pending == nil else { return .additionInProgress }

        let baseline: String?
        do {
            let encodedSecret = try captureCredential(provider)
            if provider == .codex {
                try controller.preserveLegacyCodexCredentialIfAbsent(
                    encodedSecret
                )
            } else if provider == .kiro {
                try controller.preserveLegacyKiroCredentialIfAbsent(encodedSecret)
            }
            baseline = Self.additionFingerprint(encodedSecret, provider: provider)
        } catch CredentialDiscoveryError.notFound {
            // No credential to displace yet: the first one that appears
            // belongs to the account the user is about to authenticate.
            baseline = nil
        } catch {
            return .credentialUnavailable
        }

        switch launchCompanion(provider) {
        case .success(.launched):
            pending = PendingCompanionAddition(
                provider: provider,
                label: label,
                credentialFingerprint: baseline
            )
            return .waitingForCompanion
        case .success(.openedFallback(let url)):
            return .openedOfficialGuide(url)
        case .failure(let error):
            return .launchFailed(error)
        }
    }

    @discardableResult
    func checkAgain() -> ProviderAccountAdditionOutcome {
        guard let pending else { return .ignored }
        let secret: String
        do {
            secret = try captureCredential(pending.provider)
        } catch {
            return .credentialMissing
        }
        guard Self.additionFingerprint(secret, provider: pending.provider)
            != pending.credentialFingerprint else {
            return .credentialUnchanged
        }
        guard
            (try? CredentialSnapshot(
                encodedSecret: secret,
                provider: pending.provider
            )) != nil
        else {
            return .credentialMissing
        }
        do {
            _ = try controller.addCapturedCompanionAccount(
                provider: pending.provider,
                label: pending.label,
                encodedSecret: secret
            )
        } catch {
            // The addition stays pending so the user can retry without
            // re-authenticating the companion.
            return .failed
        }
        self.pending = nil
        onAccountAdded()
        return .addedAccount(pending.label)
    }

    @discardableResult
    func applicationDidBecomeActive() -> ProviderAccountAdditionOutcome {
        // Claude capture is an explicit Keychain import. Its existing Add
        // Account flow uses Check Again rather than prompting on activation.
        guard pending?.provider != .claude else { return .ignored }
        return checkAgain()
    }

    func cancel() {
        pending = nil
    }

    private func addAPIKeyAccount(
        provider: ProviderID,
        label: String,
        key: String?
    ) -> ProviderAccountAdditionOutcome {
        do {
            _ = try controller.addAPIKeyAccount(
                provider: provider,
                label: label,
                key: key
            )
        } catch ProviderAccountRegistryControllerError.invalidLabel {
            return .invalidLabel
        } catch {
            return .failed
        }
        onAccountAdded()
        return .addedAccount(label)
    }

    private static func additionFingerprint(_ secret: String, provider: ProviderID) -> String {
        if provider == .codex || provider == .kiro,
           let snapshot = try? CredentialSnapshot(encodedSecret: secret, provider: provider),
           let identity = snapshot.accountReference, !identity.isEmpty {
            return fingerprint(identity)
        }
        return fingerprint(secret)
    }

    fileprivate static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum CodexLegacyReconnectOutcome: Equatable, Sendable {
    case waitingForCredential
    case credentialUnchanged
    case credentialMissing
    case credentialUnavailable
    case reconnected
    case launchFailed(ProviderSetupError)
    case ignored
}

/// Keeps a disconnected legacy Codex account pinned until the official
/// companion login has actually changed. The mutable companion credential
/// is sampled directly; only a changed, valid snapshot may replace the pin.
@Observable
@MainActor
final class CodexLegacyReconnectCoordinator {
    private(set) var baselineFingerprint: String?
    private(set) var isWaiting = false

    @ObservationIgnored
    private let captureCredential: () throws -> String
    @ObservationIgnored
    private let persistLegacySnapshot: (String) throws -> Void
    @ObservationIgnored
    private let launchCompanion: () -> Result<
        ProviderSetupOutcome,
        ProviderSetupError
    >
    @ObservationIgnored
    private let reenable: () -> Void

    init(
        captureCredential: @escaping () throws -> String,
        persistLegacySnapshot: @escaping (String) throws -> Void,
        launchCompanion: @escaping () -> Result<
            ProviderSetupOutcome,
            ProviderSetupError
        >,
        reenable: @escaping () -> Void
    ) {
        self.captureCredential = captureCredential
        self.persistLegacySnapshot = persistLegacySnapshot
        self.launchCompanion = launchCompanion
        self.reenable = reenable
    }

    @discardableResult
    func start() -> CodexLegacyReconnectOutcome {
        let baseline: String?
        do {
            baseline = ProviderAccountAdditionCoordinator.fingerprint(
                try captureCredential()
            )
        } catch CredentialDiscoveryError.notFound {
            baseline = nil
        } catch {
            return .credentialUnavailable
        }
        switch launchCompanion() {
        case .success(.launched):
            baselineFingerprint = baseline
            isWaiting = true
            return .waitingForCredential
        case .success(.openedFallback(let url)):
            return .launchFailed(.unableToOpen(url))
        case .failure(let error):
            return .launchFailed(error)
        }
    }

    @discardableResult
    func checkAgain() -> CodexLegacyReconnectOutcome {
        guard isWaiting else { return .ignored }
        let secret: String
        do {
            secret = try captureCredential()
        } catch {
            return .credentialMissing
        }
        guard
            ProviderAccountAdditionCoordinator.fingerprint(secret)
                != baselineFingerprint
        else {
            return .credentialUnchanged
        }
        guard
            (try? CredentialSnapshot(
                encodedSecret: secret,
                provider: .codex
            )) != nil
        else {
            return .credentialMissing
        }
        do {
            try persistLegacySnapshot(secret)
        } catch {
            return .credentialUnavailable
        }
        baselineFingerprint = nil
        isWaiting = false
        reenable()
        return .reconnected
    }

    func cancel() {
        baselineFingerprint = nil
        isWaiting = false
    }
}

enum ProviderSetup {
    static func descriptor(
        for provider: ProviderID
    ) -> ProviderSetupDescriptor? {
        switch provider {
        case .claude:
            terminal(
                instruction: "Claude Code OAuth 로그인",
                executable: "claude",
                arguments: ["auth", "login"],
                opensFallback: false,
                help: help(
                    provider,
                    [
                        "Claude Code OAuth 로그인을 완료하세요.",
                        "Claude Desktop 로그인만으로는 실시간 리셋 시각을 읽을 수 없습니다.",
                        "인증이 끝나면 OmoUsage가 구독 사용량을 바로 새로고칩니다."
                    ],
                    "https://claude.ai/code"
                )
            )
        case .codex:
            terminal(
                instruction: "codex 실행 후 ChatGPT로 로그인",
                executable: "codex",
                arguments: ["login"],
                opensFallback: false,
                help: help(
                    provider,
                    [
                        "Codex CLI를 실행해 ChatGPT 계정으로 로그인하세요.",
                        "OmoUsage는 Codex가 저장한 로컬 인증값을 자동으로 찾습니다."
                    ],
                    "https://chatgpt.com/codex"
                )
            )
        case .cursor:
            application(
                instruction: "Cursor 앱의 Account에서 로그인",
                name: "Cursor",
                bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                help: help(
                    provider,
                    [
                        "Cursor 앱의 Account에서 로그인하거나 agent login을 실행하세요.",
                        "OmoUsage는 Cursor의 로컬 데이터베이스에서 인증값을 찾습니다."
                    ],
                    "https://cursor.com/login"
                )
            )
        case .antigravity:
            applicationOrTerminal(
                instruction: "Antigravity 앱 또는 agy CLI에서 로그인",
                name: "Antigravity",
                bundleIdentifier: "com.google.antigravity",
                specifications: [
                    TerminalLaunchSpecification(
                        executable: "agy",
                        arguments: []
                    )
                ],
                opensFallback: false,
                help: help(
                    provider,
                    [
                        "Antigravity 앱 또는 agy CLI에서 Google 계정으로 로그인하세요.",
                        "OmoUsage는 Antigravity가 Keychain에 저장한 인증값을 읽습니다."
                    ],
                    "https://antigravity.google/docs/cli/install"
                )
            )
        case .copilot:
            terminalAlternatives(
                instruction: "Copilot CLI 또는 GitHub CLI에서 로그인",
                specifications: [
                    TerminalLaunchSpecification(
                        executable: "copilot",
                        arguments: ["login"]
                    ),
                    TerminalLaunchSpecification(
                        executable: "gh",
                        arguments: ["auth", "login"]
                    )
                ],
                opensFallback: false,
                help: help(
                    provider,
                    [
                        "Copilot CLI가 있으면 브라우저 OAuth 로그인을 엽니다.",
                        "없으면 설치된 GitHub CLI 인증을 엽니다.",
                        "일반 GitHub OAuth 로그인만으로는 Copilot quota 접근이 확인되지 않으며 OmoUsage가 endpoint에서 확인합니다."
                    ],
                    "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up/install-copilot-cli"
                )
            )
        case .devin:
            ProviderSetupDescriptor(
                instruction: "브라우저에서 Devin 로그인",
                action: .browserOAuth,
                help: help(
                    provider,
                    [
                        "연결 시작을 눌러 브라우저에서 Devin에 로그인하세요.",
                        "CLI 설치 없이 사용량을 확인하고 인증값을 이 Mac의 Keychain에 저장합니다."
                    ],
                    "https://app.devin.ai/settings/plans"
                )
            )
        case .grok:
            terminal(
                instruction: "grok login 실행",
                executable: "grok",
                arguments: ["login"],
                opensFallback: false,
                help: help(
                    provider,
                    [
                        "연결 시작을 눌러 Grok CLI 인증을 진행하세요.",
                        "OmoUsage는 Grok의 로컬 auth.json을 자동으로 찾습니다."
                    ],
                    "https://docs.x.ai/build/cli/reference"
                )
            )
        case .kiro:
            ProviderSetupDescriptor(
                instruction: "Kiro 계정 연결",
                action: .browserOAuth,
                help: help(
                    provider,
                    [
                        "기존 Kiro 인증을 사용하며, 인증이 없으면 브라우저에서 로그인합니다.",
                        "연결한 계정의 인증은 이 Mac의 키체인에 안전하게 저장합니다."
                    ],
                    "https://kiro.dev/docs/cli/"
                )
            )
        case .opencode:
            apiKey(
                instruction: "OpenCode Go API 키 입력",
                help: help(
                    provider,
                    [
                        "OpenCode Go에서 API 키를 생성하세요.",
                        "생성한 키를 API 키 입력란에 붙여 넣고 저장을 누르세요.",
                        "OmoUsage는 저장된 키를 공식 auth.json과 로컬 사용 기록보다 먼저 사용합니다."
                    ],
                    "https://opencode.ai/docs/cli/#auth"
                )
            )
        case .openrouter:
            apiKey(
                instruction: "OpenRouter API 키 입력",
                help: help(
                    provider,
                    [
                        "OpenRouter의 Keys 페이지에서 API 키를 생성하세요.",
                        "생성한 키를 API 키 입력란에 붙여 넣고 저장을 누르세요."
                    ],
                    "https://openrouter.ai/keys"
                )
            )
        case .zai:
            apiKey(
                instruction: "Z.ai API 키 입력",
                help: help(
                    provider,
                    [
                        "개인 플랜은 Z.ai API 키 관리 페이지에서 키를 생성하세요.",
                        "팀 플랜은 https://z.ai/manage-apikey/coding-plan/team/my-plan 에서 전용 키를 생성하세요.",
                        "생성한 키를 API 키 입력란에 붙여 넣고 저장을 누르세요."
                    ],
                    "https://z.ai/manage-apikey/apikey-list"
                )
            )
        }
    }

    @MainActor
    static func perform(
        for provider: ProviderID
    ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
        guard let descriptor = descriptor(for: provider) else {
            return .failure(.unavailable(provider))
        }

        switch descriptor.action {
        case .terminal(let specification, let fallbackURL):
            return performTerminal(
                specification,
                fallbackURL: fallbackURL,
                companionProvider: provider
            )
        case .terminalAlternatives(
            let specifications,
            let fallbackURL
        ):
            return performTerminalAlternatives(
                specifications,
                fallbackURL: fallbackURL,
                companionProvider: provider
            )
        case .application(let specification):
            return performApplication(
                specification,
                companionProvider: provider
            )
        case .applicationOrTerminal(
            let application,
            let specifications,
            let fallbackURL
        ):
            return performApplicationOrTerminal(
                application,
                specifications: specifications,
                fallbackURL: fallbackURL,
                companionProvider: provider
            )
        case .web(let url):
            if NSWorkspace.shared.open(url) {
                return .success(.openedFallback(url))
            } else {
                return .failure(.unableToOpen(url))
            }
        case .apiKey:
            return .failure(.unavailable(provider))
        case .browserOAuth:
            // Browser authentication is asynchronous and owned by Settings.
            return .failure(.unavailable(provider))
        }
    }

    @MainActor
    static func performClaudeLogin(
        receipt: OfficialLoginReceipt,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        launchTerminal: (String) -> Bool = launchTerminalCommand
    ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
        performTerminal(
            TerminalLaunchSpecification(executable: "claude", arguments: ["auth", "login"]),
            fallbackURL: nil,
            companionProvider: .claude,
            environment: environment,
            homeDirectory: homeDirectory,
            isExecutable: isExecutable,
            launchTerminal: { launchTerminal(receipt.wrapping($0)) }
        )
    }

    static func performTerminal(
        _ specification: TerminalLaunchSpecification,
        fallbackURL: URL?,
        companionProvider: ProviderID? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        launchTerminal: (String) -> Bool = launchTerminalCommand,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
        performTerminalAlternatives(
            [specification],
            fallbackURL: fallbackURL,
            companionProvider: companionProvider,
            environment: environment,
            homeDirectory: homeDirectory,
            isExecutable: isExecutable,
            launchTerminal: launchTerminal,
            openURL: openURL
        )
    }

    static func performTerminalAlternatives(
        _ specifications: [TerminalLaunchSpecification],
        fallbackURL: URL?,
        companionProvider: ProviderID? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        launchTerminal: (String) -> Bool = launchTerminalCommand,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
        var failedExecutable: String?
        for specification in specifications {
            guard let executablePath = resolvedExecutablePath(
                specification.executable,
                environment: environment,
                homeDirectory: homeDirectory,
                isExecutable: isExecutable
            ) else {
                continue
            }
            failedExecutable = specification.executable
            var command = ([executablePath] + specification.arguments)
                .map(shellQuote)
                .joined(separator: " ")
            if companionProvider == .claude {
                let directory = CredentialDiscovery.claudeLoginDirectory(
                    home: homeDirectory
                ).path.precomposedStringWithCanonicalMapping
                command = "CLAUDE_CONFIG_DIR=\(shellQuote(directory)) \(command)"
            }
            if launchTerminal(command) {
                return .success(.launched)
            }
        }

        if let fallbackURL {
            if openURL(fallbackURL) {
                return .success(.openedFallback(fallbackURL))
            }
            if let failedExecutable {
                return .failure(.unableToLaunch(failedExecutable))
            }
            return .failure(.unableToOpen(fallbackURL))
        }
        if let failedExecutable {
            return .failure(.unableToLaunch(failedExecutable))
        }
        let companions = specifications.map(\.executable)
        if let companionProvider {
            return .failure(
                .companionRequired(companionProvider, companions)
            )
        }
        return .failure(.requiredExecutableMissing(companions))
    }

    static func resolvedExecutablePath(
        _ executable: String,
        environment: [String: String],
        homeDirectory: URL,
        isExecutable: (String) -> Bool
    ) -> String? {
        if
            executable == "claude",
            let bundled = bundledClaudeExecutable(
                homeDirectory: homeDirectory,
                isExecutable: isExecutable
            )
        {
            return bundled
        }
        if
            executable == "codex",
            let bundled = bundledCodexExecutable(
                homeDirectory: homeDirectory,
                isExecutable: isExecutable
            )
        {
            return bundled
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        var directories = environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .filter { directory in
                let resolved = URL(
                    filePath: directory,
                    directoryHint: .isDirectory
                )
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
                return
                    resolved != temporaryDirectory
                    && !resolved.hasPrefix("\(temporaryDirectory)/")
            }
        directories.append(
            contentsOf: [
                homeDirectory.appending(
                    path: ".opencode/bin"
                ).path,
                homeDirectory.appending(path: ".local/bin").path,
                homeDirectory.appending(path: ".bun/bin").path,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin"
            ]
        )

        var seen: Set<String> = []
        for directory in directories where seen.insert(directory).inserted {
            let candidate = URL(
                filePath: directory,
                directoryHint: .isDirectory
            )
            .appending(path: executable)
            .path
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func bundledCodexExecutable(
        homeDirectory: URL,
        isExecutable: (String) -> Bool
    ) -> String? {
        let relativePath = "ChatGPT.app/Contents/Resources/codex"
        let candidates = [
            homeDirectory.appending(
                components: "Applications",
                relativePath
            ),
            URL(filePath: "/Applications", directoryHint: .isDirectory)
                .appending(path: relativePath)
        ]
        return candidates
            .map(\.path)
            .first(where: isExecutable)
    }

    private static func bundledClaudeExecutable(
        homeDirectory: URL,
        isExecutable: (String) -> Bool
    ) -> String? {
        let versionsDirectory = homeDirectory.appending(
            components: "Library",
            "Application Support",
            "Claude",
            "claude-code"
        )
        guard
            let versions = try? FileManager.default.contentsOfDirectory(
                at: versionsDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return nil
        }
        for version in versions.sorted(by: {
            $0.lastPathComponent.compare(
                $1.lastPathComponent,
                options: .numeric
            ) == .orderedDescending
        }) {
            let candidate = version.appending(
                components: "claude.app",
                "Contents",
                "MacOS",
                "claude"
            ).path
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func terminalCommandFile(
        command: String,
        at url: URL
    ) -> String {
        """
        #!/bin/zsh
        rm -f -- \(shellQuote(url.path))
        exec \(command)

        """
    }

    static func performApplication(
        _ specification: ApplicationLaunchSpecification,
        companionProvider: ProviderID,
        resolveApplication: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: $0
            )
        },
        openApplication: (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        },
        openURL: (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        }
    ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
        guard
            let applicationURL = resolveApplication(
                specification.bundleIdentifier
            )
        else {
            return .failure(
                .companionRequired(
                    companionProvider,
                    [specification.name]
                )
            )
        }
        guard openApplication(applicationURL) else {
            return .failure(.unableToLaunch(specification.name))
        }
        return .success(.launched)
    }

    static func performApplicationOrTerminal(
        _ application: ApplicationLaunchSpecification,
        specifications: [TerminalLaunchSpecification],
        fallbackURL: URL?,
        companionProvider: ProviderID? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        },
        resolveApplication: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: $0
            )
        },
        openApplication: (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        },
        launchTerminal: (String) -> Bool = {
            launchTerminalCommand($0)
        },
        openURL: (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        }
    ) -> Result<ProviderSetupOutcome, ProviderSetupError> {
        if
            let applicationURL = resolveApplication(
                application.bundleIdentifier
            ),
            openApplication(applicationURL)
        {
            return .success(.launched)
        }
        return performTerminalAlternatives(
            specifications,
            fallbackURL: fallbackURL,
            companionProvider: companionProvider,
            environment: environment,
            homeDirectory: homeDirectory,
            isExecutable: isExecutable,
            launchTerminal: launchTerminal,
            openURL: openURL
        )
    }

    private static func launchTerminalCommand(
        _ command: String
    ) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appending(
                path: "OmoUsage-\(UUID().uuidString).command"
            )
        do {
            try terminalCommandFile(command: command, at: url)
                .write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            if NSWorkspace.shared.open(url) {
                return true
            }
            try? FileManager.default.removeItem(at: url)
            return false
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    fileprivate static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func terminal(
        instruction: String,
        executable: String,
        arguments: [String],
        opensFallback: Bool = true,
        help: ProviderHelpContent
    ) -> ProviderSetupDescriptor {
        ProviderSetupDescriptor(
            instruction: instruction,
            action: .terminal(
                TerminalLaunchSpecification(
                    executable: executable,
                    arguments: arguments
                ),
                fallbackURL: opensFallback ? help.officialURL : nil
            ),
            help: help
        )
    }

    private static func terminalAlternatives(
        instruction: String,
        specifications: [TerminalLaunchSpecification],
        opensFallback: Bool = true,
        help: ProviderHelpContent
    ) -> ProviderSetupDescriptor {
        ProviderSetupDescriptor(
            instruction: instruction,
            action: .terminalAlternatives(
                specifications,
                fallbackURL: opensFallback ? help.officialURL : nil
            ),
            help: help
        )
    }

    private static func application(
        instruction: String,
        name: String,
        bundleIdentifier: String,
        help: ProviderHelpContent
    ) -> ProviderSetupDescriptor {
        ProviderSetupDescriptor(
            instruction: instruction,
            action: .application(
                ApplicationLaunchSpecification(
                    name: name,
                    bundleIdentifier: bundleIdentifier,
                    fallbackURL: help.officialURL
                )
            ),
            help: help
        )
    }

    private static func applicationOrTerminal(
        instruction: String,
        name: String,
        bundleIdentifier: String,
        specifications: [TerminalLaunchSpecification],
        opensFallback: Bool = true,
        help: ProviderHelpContent
    ) -> ProviderSetupDescriptor {
        let application = ApplicationLaunchSpecification(
            name: name,
            bundleIdentifier: bundleIdentifier,
            fallbackURL: help.officialURL
        )
        return ProviderSetupDescriptor(
            instruction: instruction,
            action: .applicationOrTerminal(
                application,
                specifications,
                fallbackURL: opensFallback ? help.officialURL : nil
            ),
            help: help
        )
    }

    private static func apiKey(
        instruction: String,
        help: ProviderHelpContent
    ) -> ProviderSetupDescriptor {
        ProviderSetupDescriptor(
            instruction: instruction,
            action: .apiKey,
            help: help
        )
    }

    private static func help(
        _ provider: ProviderID,
        _ instructions: [String],
        _ officialURL: String
    ) -> ProviderHelpContent {
        ProviderHelpContent(
            title: "\(provider.displayName) 연결 방법",
            instructions: instructions,
            officialURL: URL(string: officialURL)!
        )
    }
}
