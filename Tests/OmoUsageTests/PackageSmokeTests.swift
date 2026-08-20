import Foundation
import Testing
@testable import OmoUsage

@Suite
struct PackageSmokeTests {
    @Test
    func desktopBundleDeclaresReleaseVersionAndIcon() throws {
        let info = try desktopInfo()

        #expect(info["CFBundleShortVersionString"] as? String == "0.1.2")
        #expect(info["CFBundleIconFile"] as? String == "OmoUsage.icns")
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
