import AppKit
import Foundation

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
    case unavailable(ProviderID)
    case unableToLaunch(String)
    case unableToOpen(URL)
    case requiredExecutableMissing([String])

    var id: String {
        switch self {
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
                        "또는 사용하는 편집기에서 GitHub Copilot에 로그인하세요."
                    ],
                    "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up/install-copilot-cli"
                )
            )
        case .devin:
            terminal(
                instruction: "devin auth login 실행",
                executable: "devin",
                arguments: ["auth", "login"],
                opensFallback: false,
                help: help(
                    provider,
                    [
                        "연결 시작을 눌러 Devin CLI 인증을 진행하세요.",
                        "OmoUsage는 Devin이 저장한 로컬 인증값을 자동으로 찾습니다."
                    ],
                    "https://docs.devin.ai/cli"
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
        case .opencode:
            terminal(
                instruction: "OpenCode Go 연결 또는 로컬 사용",
                executable: "opencode",
                arguments: [
                    "auth", "login", "--provider", "opencode-go"
                ],
                opensFallback: false,
                help: help(
                    provider,
                    [
                        "연결 시작을 누르면 OpenCode의 공식 인증 흐름을 엽니다.",
                        "OmoUsage는 OpenCode의 auth.json과 로컬 사용 기록을 자동으로 찾습니다.",
                        "OpenCode가 없으면 CLI 설치가 필요하다고 안내합니다."
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
                fallbackURL: fallbackURL
            )
        case .terminalAlternatives(
            let specifications,
            let fallbackURL
        ):
            return performTerminalAlternatives(
                specifications,
                fallbackURL: fallbackURL
            )
        case .application(let specification):
            return performApplication(specification)
        case .applicationOrTerminal(
            let application,
            let specifications,
            let fallbackURL
        ):
            return performApplicationOrTerminal(
                application,
                specifications: specifications,
                fallbackURL: fallbackURL
            )
        case .web(let url):
            if NSWorkspace.shared.open(url) {
                return .success(.openedFallback(url))
            } else {
                return .failure(.unableToOpen(url))
            }
        case .apiKey:
            return .failure(.unavailable(provider))
        }
    }

    static func performTerminal(
        _ specification: TerminalLaunchSpecification,
        fallbackURL: URL?,
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
            let command = ([executablePath] + specification.arguments)
                .map(shellQuote)
                .joined(separator: " ")
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
        return .failure(
            .requiredExecutableMissing(
                specifications.map(\.executable)
            )
        )
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

    private static func performApplication(
        _ specification: ApplicationLaunchSpecification,
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
        if
            let applicationURL = resolveApplication(
                specification.bundleIdentifier
            ),
            openApplication(applicationURL)
        {
            return .success(.launched)
        }
        if openURL(specification.fallbackURL) {
            return .success(
                .openedFallback(specification.fallbackURL)
            )
        }
        return .failure(.unableToOpen(specification.fallbackURL))
    }

    static func performApplicationOrTerminal(
        _ application: ApplicationLaunchSpecification,
        specifications: [TerminalLaunchSpecification],
        fallbackURL: URL?,
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

    private static func shellQuote(_ value: String) -> String {
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
