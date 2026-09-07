import Foundation
import Testing

@Suite
struct ReleasePipelineTests {
    @Test
    func trustedReleasePlanIsCompleteAndOrdered() throws {
        let result = try releasePlan(environment: validEnvironment)
        #expect(result.status == 0)

        let requiredSteps = [
            "package-app.sh --developer-id",
            "codesign --verify --deep --strict --verbose=2",
            "ditto -c -k --keepParent",
            "xcrun notarytool submit",
            "xcrun stapler staple",
            "xcrun stapler validate",
            "spctl --assess --type execute --verbose=2",
            "shasum -a 256",
            "MANIFEST="
        ]
        var previousIndex = result.output.startIndex
        for step in requiredSteps {
            let range = try #require(
                result.output.range(of: step, range: previousIndex..<result.output.endIndex),
                "missing or out-of-order release step: \(step)"
            )
            previousIndex = range.upperBound
        }
        #expect(result.output.contains("OmoUsage-0.1.15.zip"))
        #expect(result.output.contains("OmoUsage-0.1.15.sha256"))
        #expect(result.output.contains("OmoUsage-0.1.15-manifest.txt"))
        #expect(result.output.contains("SOURCE_COMMIT=\(try sourceCommit())"))
    }

    @Test
    func releaseFailsClosedWithoutEveryTrustInput() throws {
        for key in [
            "OMO_USAGE_CODESIGN_IDENTITY",
            "OMO_USAGE_TEAM_IDENTIFIER",
            "OMO_USAGE_NOTARY_PROFILE",
            "OMO_USAGE_RELEASE_REF"
        ] {
            var environment = validEnvironment
            environment.removeValue(forKey: key)
            let result = try releasePlan(environment: environment)
            #expect(result.status != 0, "release accepted missing \(key)")
        }

        var untrusted = validEnvironment
        untrusted["OMO_USAGE_RELEASE_REF"] = "refs/heads/main"
        #expect(try releasePlan(environment: untrusted).status != 0)

        var wrongTag = validEnvironment
        wrongTag["OMO_USAGE_RELEASE_REF"] = "refs/tags/v9.9.9"
        #expect(try releasePlan(environment: wrongTag).status != 0)
    }

    @Test
    func packagingKeepsExplicitAdHocAndDeveloperIDModesSeparate() throws {
        let script = try contents("Scripts/package-app.sh")
        let signingHelper = try contents("Scripts/sign-app.sh")
        #expect(script.contains("--adhoc"))
        #expect(script.contains("--developer-id"))
        #expect(signingHelper.contains("--options runtime"))
        #expect(signingHelper.contains("--timestamp"))
        #expect(script.contains("codesign --verify --deep --strict"))

        let adHoc = try process(
            executable: "/bin/sh",
            arguments: [scriptPath("package-app.sh"), "--print-signing-plan", "--adhoc"],
            environment: [:]
        )
        #expect(adHoc.status == 0)
        #expect(adHoc.output.contains("SIGNING_MODE=adhoc"))
        #expect(adHoc.output.contains("SIGNING_IDENTITY=-"))
        #expect(adHoc.output.contains("CLOUD_KVS_AVAILABLE=no"))
    }

    @Test
    func signingHelperPassesOnlyTheDedicatedKeychainToCodesign() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "OmoUsageSigningHelper-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "bin")
        let log = root.appending(path: "codesign.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try executable(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$FAKE_CODESIGN_LOG\"\n",
            at: bin.appending(path: "codesign")
        )

        let result = try process(
            executable: "/bin/sh",
            arguments: [
                scriptPath("sign-app.sh"), "--developer-id",
                "/tmp/Synthetic.app", "Developer ID Application: Synthetic (TESTTEAM)",
                "/tmp/synthetic-entitlements.plist"
            ],
            environment: [
                "PATH": "\(bin.path):/usr/bin:/bin",
                "FAKE_CODESIGN_LOG": log.path,
                "OMO_USAGE_SIGNING_KEYCHAIN": "/tmp/synthetic.keychain-db"
            ]
        )

        #expect(result.status == 0)
        let arguments = try contentsOfURL(log).split(separator: " ").map(String.init)
        #expect(arguments.contains("--options"))
        #expect(arguments.contains("runtime"))
        #expect(arguments.contains("--timestamp"))
        let keychainIndex = try #require(arguments.firstIndex(of: "--keychain"))
        #expect(arguments[keychainIndex + 1] == "/tmp/synthetic.keychain-db")
        #expect(arguments.filter { $0 == "--keychain" }.count == 1)
    }

    @Test
    func ephemeralKeychainCleanupNeverMutatesUserSearchList() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "OmoUsageKeychainWrapper-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "bin")
        let securityLog = root.appending(path: "security.log")
        let commandLog = root.appending(path: "command.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try executable(
            """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_SECURITY_LOG"
            case "$1" in
                create-keychain)
                    for argument in "$@"; do keychain="$argument"; done
                    : > "$keychain"
                    ;;
                delete-keychain)
                    rm -f "$2"
                    ;;
            esac
            """,
            at: bin.appending(path: "security")
        )
        try executable("#!/bin/sh\nexit 0\n", at: bin.appending(path: "xcrun"))
        try executable(
            "#!/bin/sh\nprintf 'SIGNING_KEYCHAIN=%s\\n' \"$OMO_USAGE_SIGNING_KEYCHAIN\" > \"$FAKE_COMMAND_LOG\"\ntest -f \"$OMO_USAGE_SIGNING_KEYCHAIN\"\n",
            at: bin.appending(path: "capture-command")
        )

        let result = try process(
            executable: "/bin/sh",
            arguments: [scriptPath("with-signing-keychain.sh"), bin.appending(path: "capture-command").path],
            environment: [
                "PATH": "\(bin.path):/usr/bin:/bin",
                "FAKE_SECURITY_LOG": securityLog.path,
                "FAKE_COMMAND_LOG": commandLog.path,
                "CERTIFICATE_P12_BASE64": "YQ==",
                "CERTIFICATE_PASSWORD": "synthetic-certificate-password",
                "NOTARY_APPLE_ID": "synthetic@example.invalid",
                "NOTARY_PASSWORD": "synthetic-notary-password",
                "OMO_USAGE_TEAM_IDENTIFIER": "TESTTEAM",
                "OMO_USAGE_NOTARY_PROFILE": "synthetic-profile"
            ]
        )

        #expect(result.status == 0)
        let securityCalls = try contentsOfURL(securityLog)
        #expect(!securityCalls.contains("list-keychains"))
        let commandOutput = try contentsOfURL(commandLog)
        let keychain = try #require(
            commandOutput.split(separator: "=").last.map(String.init)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(securityCalls.contains("create-keychain"))
        #expect(securityCalls.contains("delete-keychain \(keychain)"))
        #expect(!FileManager.default.fileExists(atPath: keychain))
    }

    @Test
    func releaseWorkflowIsTagOnlyProtectedAndLeastPrivilege() throws {
        let workflow = try contents(".github/workflows/release.yml")
        #expect(workflow.contains("tags:"))
        #expect(!workflow.contains("pull_request:"))
        #expect(!workflow.contains("workflow_dispatch:"))
        #expect(workflow.contains("permissions:\n  contents: read"))
        #expect(!workflow.contains("contents: write"))
        #expect(!workflow.contains("environment:"))
        #expect(workflow.contains("Scripts/with-signing-keychain.sh"))
        #expect(workflow.contains("CERTIFICATE_P12_BASE64: ${{ secrets."))
        #expect(workflow.contains("NOTARY_PASSWORD: ${{ secrets."))
        #expect(
            workflow.contains(
                "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4"
            )
        )
        #expect(!workflow.contains("softprops/action-gh-release"))

        let actionLines = workflow.split(separator: "\n").filter { $0.contains("uses:") }
        #expect(!actionLines.isEmpty)
        for line in actionLines {
            let action = line.split(separator: "uses:", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)
            #expect(
                action.wholeMatch(
                    of: /[^\s@]+@[0-9a-f]{40}\s+#\s+v\d+/
                ) != nil
            )
        }
        #expect(!workflow.contains("@v4"))
        #expect(!workflow.contains("@v2"))
    }

    private var validEnvironment: [String: String] {
        [
            "OMO_USAGE_CODESIGN_IDENTITY": "Developer ID Application: Synthetic (TESTTEAM)",
            "OMO_USAGE_TEAM_IDENTIFIER": "TESTTEAM",
            "OMO_USAGE_NOTARY_PROFILE": "synthetic-notary-profile",
            "OMO_USAGE_NOTARY_KEYCHAIN": "/tmp/synthetic.keychain-db",
            "OMO_USAGE_RELEASE_REF": "refs/tags/v0.1.15"
        ]
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ path: String) throws -> String {
        try contentsOfURL(repositoryRoot.appending(path: path))
    }

    private func contentsOfURL(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func executable(_ contents: String, at url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func scriptPath(_ name: String) -> String {
        repositoryRoot.appending(path: "Scripts").appending(path: name).path
    }

    private func sourceCommit() throws -> String {
        let result = try process(
            executable: "/usr/bin/git",
            arguments: ["-C", repositoryRoot.path, "rev-parse", "HEAD"],
            environment: [:]
        )
        #expect(result.status == 0)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func releasePlan(
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        try process(
            executable: "/bin/sh",
            arguments: [scriptPath("release-app.sh"), "--dry-run"],
            environment: environment
        )
    }

    private func process(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var cleanEnvironment = ProcessInfo.processInfo.environment
        for key in [
            "OMO_USAGE_CODESIGN_IDENTITY", "OMO_USAGE_TEAM_IDENTIFIER",
            "OMO_USAGE_NOTARY_PROFILE", "OMO_USAGE_NOTARY_KEYCHAIN",
            "OMO_USAGE_SIGNING_KEYCHAIN", "OMO_USAGE_RELEASE_REF"
        ] {
            cleanEnvironment.removeValue(forKey: key)
        }
        cleanEnvironment.merge(environment) { _, requested in requested }
        process.environment = cleanEnvironment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
