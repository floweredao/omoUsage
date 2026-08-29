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
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root
                .appending(path: "Config")
                .appending(path: "Info.plist")
        )
        return try #require(
            PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        )
    }
}
