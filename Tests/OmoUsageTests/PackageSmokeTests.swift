import Foundation
import Testing
@testable import OmoUsage

@Suite
struct PackageSmokeTests {
    @Test
    func desktopBundleDeclaresReleaseVersionAndIcon() throws {
        let info = try desktopInfo()

        #expect(info["CFBundleShortVersionString"] as? String == "0.1.7")
        #expect(info["CFBundleIconFile"] as? String == "OmoUsage.icns")
        #expect(info["LSUIElement"] as? Bool == true)
    }

    @Test
    func desktopEntitlementDeclaresTeamScopedCloudKVS() throws {
        let entitlements = try propertyList(
            at: repositoryRoot
                .appending(path: "Config")
                .appending(path: "OmoUsage.entitlements")
        )

        #expect(
            entitlements[
                "com.apple.developer.ubiquity-kvstore-identifier"
            ] as? String == "$(TeamIdentifierPrefix)com.omo.usage"
        )
    }

    @Test
    func packageScriptReportsDeterministicSigningPlans() throws {
        let adHoc = try signingPlan(environment: [:])
        #expect(adHoc.status == 0)
        #expect(adHoc.output.contains("SIGNING_IDENTITY=-\n"))
        #expect(adHoc.output.contains("CLOUD_KVS_AVAILABLE=no\n"))

        let invalidAdHocTeam = try signingPlan(environment: [
            "OMO_USAGE_CODESIGN_IDENTITY": "-",
            "OMO_USAGE_TEAM_IDENTIFIER": "TESTTEAM"
        ])
        #expect(invalidAdHocTeam.status != 0)

        let cloud = try signingPlan(environment: [
            "OMO_USAGE_CODESIGN_IDENTITY":
                "Developer ID Application: Test",
            "OMO_USAGE_TEAM_IDENTIFIER": "TESTTEAM"
        ])
        #expect(cloud.status == 0)
        #expect(
            cloud.output.contains(
                "KVS_IDENTIFIER=TESTTEAM.com.omo.usage\n"
            )
        )
        #expect(cloud.output.contains("CLOUD_KVS_AVAILABLE=yes\n"))
    }

    @Test
    func packageScriptRejectsIdentityWithoutTeam() throws {
        let plan = try signingPlan(environment: [
            "OMO_USAGE_CODESIGN_IDENTITY": "Impossible Identity"
        ])

        #expect(plan.status != 0)
    }

    @Test
    func packagedDashboardAssetsDoNotEvaluateSwiftPMBundle() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "OmoUsagePackageSmoke-\(UUID().uuidString)"
        )
        defer {
            try? fileManager.removeItem(at: root)
        }
        let app = root.appending(path: "OmoUsage.app")
        let contents = app.appending(path: "Contents")
        let resources = contents.appending(path: "Resources")
        try fileManager.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.omo.usage.package-smoke",
            "CFBundleExecutable": "OmoUsage",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appending(path: "Info.plist"))
        let expected = resources.appending(path: "index.html")
        try Data("dashboard".utf8).write(to: expected)
        let bundle = try #require(Bundle(url: app))
        var packageBundleWasRead = false

        let resolved = WebDashboardAssets.resourceURL(
            name: "index",
            extension: "html",
            mainBundle: bundle,
            packageBundle: {
                packageBundleWasRead = true
                return nil
            }
        )

        #expect(resolved?.path == expected.path)
        #expect(!packageBundleWasRead)
    }

    private func desktopInfo() throws -> [String: Any] {
        try propertyList(
            at: repositoryRoot
                .appending(path: "Config")
                .appending(path: "Info.plist")
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        )
    }

    private func signingPlan(
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            repositoryRoot
                .appending(path: "Scripts")
                .appending(path: "package-app.sh").path,
            "--print-signing-plan"
        ]
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.removeValue(
            forKey: "OMO_USAGE_CODESIGN_IDENTITY"
        )
        processEnvironment.removeValue(
            forKey: "OMO_USAGE_TEAM_IDENTIFIER"
        )
        processEnvironment.merge(
            environment,
            uniquingKeysWith: { _, requested in requested }
        )
        process.environment = processEnvironment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self)
        )
    }
}
