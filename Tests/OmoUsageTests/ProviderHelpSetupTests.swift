import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct ProviderHelpSetupTests {
    @Test
    func everyProviderHasNativeHelpWithOnlyOfficialLinks() throws {
        for provider in ProviderID.allCases {
            let descriptor = try #require(
                ProviderSetup.descriptor(for: provider)
            )
            #expect(!descriptor.help.title.isEmpty)
            #expect(!descriptor.help.instructions.isEmpty)
            #expect(
                descriptor.help.instructions.allSatisfy { !$0.isEmpty }
            )

            let url = descriptor.help.officialURL.absoluteString.lowercased()
            #expect(!url.contains("openusage"))
            #expect(!url.contains("robinebers"))
        }
    }

    @Test
    func companionProvidersExposeDirectConnectionActions() throws {
        #expect(
            try descriptor(.claude).action
                == .terminal(
                    TerminalLaunchSpecification(
                        executable: "claude",
                        arguments: ["auth", "login"]
                    ),
                    fallbackURL: nil
                )
        )
        #expect(
            try descriptor(.codex).action
                == .terminal(
                    TerminalLaunchSpecification(
                        executable: "codex",
                        arguments: ["login"]
                    ),
                    fallbackURL: nil
                )
        )
        #expect(
            try descriptor(.cursor).action
                == .application(
                    ApplicationLaunchSpecification(
                        name: "Cursor",
                        bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                        fallbackURL: URL(
                            string: "https://cursor.com/login"
                        )!
                    )
                )
        )
        #expect(
            try descriptor(.antigravity).action
                == .applicationOrTerminal(
                    ApplicationLaunchSpecification(
                        name: "Antigravity",
                        bundleIdentifier: "com.google.antigravity",
                        fallbackURL: URL(
                            string:
                                "https://antigravity.google/docs/cli/install"
                        )!
                    ),
                    [
                        TerminalLaunchSpecification(
                            executable: "agy",
                            arguments: []
                        )
                    ],
                    fallbackURL: nil
                )
        )
        #expect(
            try descriptor(.copilot).action
                == .terminalAlternatives(
                    [
                        TerminalLaunchSpecification(
                            executable: "copilot",
                            arguments: ["login"]
                        ),
                        TerminalLaunchSpecification(
                            executable: "gh",
                            arguments: ["auth", "login"]
                        )
                    ],
                    fallbackURL: nil
                )
        )
        #expect(
            try descriptor(.devin).action
                == .terminal(
                    TerminalLaunchSpecification(
                        executable: "devin",
                        arguments: ["auth", "login"]
                    ),
                    fallbackURL: nil
                )
        )
        #expect(
            try descriptor(.grok).action
                == .terminal(
                    TerminalLaunchSpecification(
                        executable: "grok",
                        arguments: ["login"]
                    ),
                    fallbackURL: nil
                )
        )
        #expect(
            try descriptor(.opencode).action == .apiKey
        )
        #expect(try descriptor(.openrouter).action == .apiKey)
        #expect(
            try descriptor(.openrouter).help.officialURL
                == URL(string: "https://openrouter.ai/keys")!
        )
        #expect(try descriptor(.zai).action == .apiKey)
    }

    @Test
    func missingClaudeCLIReportsInstallationRequirementWithoutOpeningWeb() throws {
        guard
            case .terminal(let specification, let fallbackURL) =
                try descriptor(.claude).action
        else {
            Issue.record("Claude must use a terminal authentication action")
            return
        }
        var launchedCommands: [String] = []
        var openedURLs: [URL] = []

        let result = ProviderSetup.performTerminal(
            specification,
            fallbackURL: fallbackURL,
            environment: ["PATH": ""],
            homeDirectory: URL(filePath: "/Users/test"),
            isExecutable: { _ in false },
            launchTerminal: {
                launchedCommands.append($0)
                return true
            },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(
            result
                == .failure(
                    .requiredExecutableMissing(["claude"])
                )
        )
        #expect(launchedCommands.isEmpty)
        #expect(openedURLs.isEmpty)
    }

    @Test
    func resolvesBundledClaudeDesktopExecutable() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageClaudeCLI-\(UUID().uuidString)")
        let executable = home.appending(
            components: "Library",
            "Application Support",
            "Claude",
            "claude-code",
            "2.1.229",
            "claude.app",
            "Contents",
            "MacOS",
            "claude"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        defer {
            try? FileManager.default.removeItem(at: home)
        }
        let expectedPath = executable.resolvingSymlinksInPath().path

        let resolved = ProviderSetup.resolvedExecutablePath(
            "claude",
            environment: ["PATH": ""],
            homeDirectory: home,
            isExecutable: {
                URL(filePath: $0).resolvingSymlinksInPath().path
                    == expectedPath
            }
        )

        #expect(
            resolved.map {
                URL(filePath: $0).resolvingSymlinksInPath().path
            } == expectedPath
        )
    }

    @Test
    func temporarySessionShimIsNotTreatedAsInstalledClaude() {
        let shimDirectory = FileManager.default.temporaryDirectory
            .appending(
                components: "cmux-cli-shims",
                UUID().uuidString
            )
        let shim = shimDirectory.appending(path: "claude").path

        let resolved = ProviderSetup.resolvedExecutablePath(
            "claude",
            environment: ["PATH": shimDirectory.path],
            homeDirectory: URL(filePath: "/Users/test"),
            isExecutable: { $0 == shim }
        )

        #expect(resolved == nil)
    }

    @Test
    func installedChatGPTBundleLaunchesCodexOAuthWithoutDownloadPage() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageCodexCLI-\(UUID().uuidString)")
        let executable = home.appending(
            components: "Applications",
            "ChatGPT.app",
            "Contents",
            "Resources",
            "codex"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: executable)
        defer {
            try? FileManager.default.removeItem(at: home)
        }
        var launchedCommands: [String] = []
        var openedURLs: [URL] = []

        let result = ProviderSetup.performTerminal(
            TerminalLaunchSpecification(
                executable: "codex",
                arguments: ["login"]
            ),
            fallbackURL: URL(string: "https://chatgpt.com/codex")!,
            environment: ["PATH": ""],
            homeDirectory: home,
            isExecutable: { $0 == executable.path },
            launchTerminal: {
                launchedCommands.append($0)
                return true
            },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(result == .success(.launched))
        #expect(launchedCommands == ["'\(executable.path)' 'login'"])
        #expect(openedURLs.isEmpty)
    }

    @Test
    func missingExecutableOpensDirectAuthenticationWithoutDocs() {
        let fallbackURL = URL(string: "https://opencode.ai/auth")!
        var launchedCommands: [String] = []
        var openedURLs: [URL] = []

        let result = ProviderSetup.performTerminal(
            TerminalLaunchSpecification(
                executable: "opencode",
                arguments: ["auth", "login"]
            ),
            fallbackURL: fallbackURL,
            environment: ["PATH": "/missing/bin"],
            isExecutable: { _ in false },
            launchTerminal: {
                launchedCommands.append($0)
                return true
            },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(result == .success(.openedFallback(fallbackURL)))
        #expect(launchedCommands.isEmpty)
        #expect(openedURLs == [fallbackURL])
    }

    @Test
    func missingExecutableDoesNotReportDocumentationAsAuthentication() {
        var openedURLs: [URL] = []

        let result = ProviderSetup.performTerminal(
            TerminalLaunchSpecification(
                executable: "opencode",
                arguments: [
                    "auth", "login", "--provider", "opencode-go"
                ]
            ),
            fallbackURL: nil,
            environment: ["PATH": ""],
            isExecutable: { _ in false },
            launchTerminal: { _ in false },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(
            result
                == .failure(
                    .requiredExecutableMissing(["opencode"])
                )
        )
        #expect(openedURLs.isEmpty)
    }

    @Test
    func installedExecutableLaunchesOfficialLoginCommand() {
        var launchedCommands: [String] = []
        var openedURLs: [URL] = []

        let result = ProviderSetup.performTerminal(
            TerminalLaunchSpecification(
                executable: "opencode",
                arguments: ["auth", "login"]
            ),
            fallbackURL: URL(string: "https://opencode.ai/auth")!,
            environment: ["PATH": "/opt/homebrew/bin"],
            isExecutable: { $0 == "/opt/homebrew/bin/opencode" },
            launchTerminal: {
                launchedCommands.append($0)
                return true
            },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(result == .success(.launched))
        #expect(
            launchedCommands
                == ["'/opt/homebrew/bin/opencode' 'auth' 'login'"]
        )
        #expect(openedURLs.isEmpty)
    }

    @Test
    func unrelatedOpenCodexExecutableIsIgnored() {
        let result = ProviderSetup.resolvedExecutablePath(
            "opencode",
            environment: ["PATH": "/Users/test/.local/bin"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            isExecutable: {
                $0 == "/Users/test/.local/bin/opencodex"
            }
        )

        #expect(result == nil)
    }

    @Test
    func terminalLaunchFailureOpensDirectAuthenticationFallback() {
        let fallbackURL = URL(string: "https://opencode.ai/auth")!
        var openedURLs: [URL] = []

        let result = ProviderSetup.performTerminal(
            TerminalLaunchSpecification(
                executable: "opencode",
                arguments: ["auth", "login"]
            ),
            fallbackURL: fallbackURL,
            environment: ["PATH": "/opt/homebrew/bin"],
            isExecutable: { $0 == "/opt/homebrew/bin/opencode" },
            launchTerminal: { _ in false },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(result == .success(.openedFallback(fallbackURL)))
        #expect(openedURLs == [fallbackURL])
    }

    @Test
    func terminalAlternativesPreferProviderCLIThenInstalledFallback() {
        let fallbackURL = URL(string: "https://github.com/copilot")!
        let specifications = [
            TerminalLaunchSpecification(
                executable: "copilot",
                arguments: []
            ),
            TerminalLaunchSpecification(
                executable: "gh",
                arguments: ["auth", "login"]
            )
        ]
        var launchedCommands: [String] = []

        let preferred = ProviderSetup.performTerminalAlternatives(
            specifications,
            fallbackURL: fallbackURL,
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            isExecutable: { path in
                path == "/usr/local/bin/copilot"
                    || path == "/opt/homebrew/bin/gh"
            },
            launchTerminal: {
                launchedCommands.append($0)
                return true
            },
            openURL: { _ in true }
        )
        #expect(preferred == .success(.launched))
        #expect(
            launchedCommands
                == ["'/usr/local/bin/copilot'"]
        )

        launchedCommands.removeAll()
        let fallbackCLI = ProviderSetup.performTerminalAlternatives(
            specifications,
            fallbackURL: fallbackURL,
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            isExecutable: { $0 == "/opt/homebrew/bin/gh" },
            launchTerminal: {
                launchedCommands.append($0)
                return true
            },
            openURL: { _ in true }
        )
        #expect(fallbackCLI == .success(.launched))
        #expect(
            launchedCommands
                == ["'/opt/homebrew/bin/gh' 'auth' 'login'"]
        )
    }

    @Test
    func missingAntigravityAppLaunchesInstalledOAuthCLI() {
        let fallbackURL = URL(
            string: "https://antigravity.google/docs/cli/install"
        )!
        var launchedCommands: [String] = []
        var openedURLs: [URL] = []

        let result = ProviderSetup.performApplicationOrTerminal(
            ApplicationLaunchSpecification(
                name: "Antigravity",
                bundleIdentifier: "com.google.antigravity",
                fallbackURL: fallbackURL
            ),
            specifications: [
                TerminalLaunchSpecification(
                    executable: "agy",
                    arguments: []
                )
            ],
            fallbackURL: fallbackURL,
            environment: ["PATH": "/opt/homebrew/bin"],
            isExecutable: { $0 == "/opt/homebrew/bin/agy" },
            resolveApplication: { _ in nil },
            openApplication: { _ in false },
            launchTerminal: {
                launchedCommands.append($0)
                return true
            },
            openURL: {
                openedURLs.append($0)
                return true
            }
        )

        #expect(result == .success(.launched))
        #expect(launchedCommands == ["'/opt/homebrew/bin/agy'"])
        #expect(openedURLs.isEmpty)
    }

    private func descriptor(
        _ provider: ProviderID
    ) throws -> ProviderSetupDescriptor {
        try #require(ProviderSetup.descriptor(for: provider))
    }
}
