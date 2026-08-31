import Foundation
import Testing

@Suite
struct CIConfigurationTests {
    @Test
    func workflowHasBoundedLeastPrivilegePullRequestAndPushJobs() throws {
        let workflow = try contents(".github/workflows/ci.yml")

        #expect(workflow.contains("pull_request:"))
        #expect(workflow.contains("push:"))
        #expect(workflow.contains("permissions:\n  contents: read"))
        #expect(workflow.contains("concurrency:"))
        #expect(workflow.contains("cancel-in-progress: true"))
        #expect(!workflow.contains("release:"))
        #expect(!workflow.contains("workflow_dispatch:"))
        #expect(!workflow.contains("contents: write"))
        #expect(!workflow.contains("id-token: write"))
        #expect(!workflow.contains("pull-requests: write"))

        for job in ["policy", "swiftpm", "xcode", "package-smoke"] {
            let body = try jobBody(named: job, in: workflow)
            #expect(body.contains("runs-on: macos-15"), "\(job) must run on macOS")
            #expect(body.contains("timeout-minutes:"), "\(job) must be bounded")
            #expect(body.contains("uses: actions/checkout@v4"))
            #expect(body.contains("run: sh Scripts/ci-check.sh \(job)"))
        }
    }

    @Test
    func localParityOwnsEveryDeterministicGate() throws {
        let script = try contents("Scripts/ci-check.sh")
        let requiredCommands = [
            "sh Scripts/check-repository-hygiene.sh",
            "sh Scripts/check-core-boundary.sh",
            "sh Scripts/check-source-policy.sh",
            "xcodegen generate",
            "git diff --exit-code -- OmoUsage.xcodeproj",
            "swift test",
            "swift build -c debug",
            "swift build -c release",
            "-destination 'generic/platform=macOS'",
            "-destination 'generic/platform=macOS,variant=Mac Catalyst'",
            "-sdk iphoneos",
            "SUPPORTED_PLATFORMS=iphoneos",
            "-sdk iphonesimulator",
            "SUPPORTED_PLATFORMS=iphonesimulator",
            "CODE_SIGNING_ALLOWED=NO",
            "swift test --filter PackageSmokeTests"
        ]

        for command in requiredCommands {
            #expect(script.contains(command), "missing CI command: \(command)")
        }
        #expect(!script.contains("package-app.sh"))
        #expect(!script.contains("codesign"))
        #expect(!script.contains("notary"))
        #expect(!script.contains("upload"))
    }

    @Test
    func workflowPinsActionsToMajorVersions() throws {
        let workflow = try contents(".github/workflows/ci.yml")
        let actionLines = workflow.split(separator: "\n").filter {
            $0.contains("uses:")
        }

        #expect(!actionLines.isEmpty)
        for line in actionLines {
            let action = line.split(separator: "uses:", maxSplits: 1)[1]
                .trimmingCharacters(in: .whitespaces)
            #expect(action.wholeMatch(of: /[^\s@]+@v\d+/) != nil)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appending(path: path),
            encoding: .utf8
        )
    }

    private func jobBody(named name: String, in workflow: String) throws -> String {
        let marker = "  \(name):\n"
        guard let start = workflow.range(of: marker)?.upperBound else {
            throw CIConfigurationError.missingJob(name)
        }
        let nextJob = ["policy", "swiftpm", "xcode", "package-smoke"]
            .filter { $0 != name }
            .compactMap { workflow.range(of: "\n  \($0):\n", range: start..<workflow.endIndex) }
            .map(\.lowerBound)
            .min()
        return String(workflow[start..<(nextJob ?? workflow.endIndex)])
    }
}

private enum CIConfigurationError: Error {
    case missingJob(String)
}
