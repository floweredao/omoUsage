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
        #expect(result.output.contains("OmoUsage-0.1.8.zip"))
        #expect(result.output.contains("OmoUsage-0.1.8.sha256"))
        #expect(result.output.contains("OmoUsage-0.1.8-manifest.txt"))
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
        #expect(script.contains("--adhoc"))
        #expect(script.contains("--developer-id"))
        #expect(script.contains("--options runtime"))
        #expect(script.contains("--timestamp"))
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
    func releaseWorkflowIsTagOnlyProtectedAndLeastPrivilege() throws {
        let workflow = try contents(".github/workflows/release.yml")
        #expect(workflow.contains("tags:"))
        #expect(!workflow.contains("pull_request:"))
        #expect(!workflow.contains("workflow_dispatch:"))
        #expect(workflow.contains("permissions:\n  contents: read"))
        #expect(workflow.contains("contents: write"))
        #expect(workflow.contains("environment: release"))
        #expect(workflow.contains("Scripts/with-signing-keychain.sh"))
        #expect(workflow.contains("CERTIFICATE_P12_BASE64: ${{ secrets."))
        #expect(workflow.contains("NOTARY_PASSWORD: ${{ secrets."))
        #expect(workflow.contains("actions/upload-artifact@v4"))
        #expect(workflow.contains("softprops/action-gh-release@v2"))

        let actionLines = workflow.split(separator: "\n").filter { $0.contains("uses:") }
        #expect(!actionLines.isEmpty)
        for line in actionLines {
            let action = line.split(separator: "uses:", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)
            #expect(action.wholeMatch(of: /[^\s@]+@v\d+/) != nil)
        }
    }

    private var validEnvironment: [String: String] {
        [
            "OMO_USAGE_CODESIGN_IDENTITY": "Developer ID Application: Synthetic (TESTTEAM)",
            "OMO_USAGE_TEAM_IDENTIFIER": "TESTTEAM",
            "OMO_USAGE_NOTARY_PROFILE": "synthetic-notary-profile",
            "OMO_USAGE_NOTARY_KEYCHAIN": "/tmp/synthetic.keychain-db",
            "OMO_USAGE_RELEASE_REF": "refs/tags/v0.1.8"
        ]
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
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
            "OMO_USAGE_RELEASE_REF"
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
