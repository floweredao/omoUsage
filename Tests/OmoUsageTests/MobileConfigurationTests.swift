import Foundation
import Testing
@testable import OmoUsage

@Suite
struct MobileConfigurationTests {
    @Test
    func bothAppsShareThePrivateICloudSnapshotIdentifier() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expected = "$(TeamIdentifierPrefix)com.omo.usage"

        for name in ["OmoUsage", "OmoUsageMobile"] {
            let url = root
                .appending(path: "Config")
                .appending(path: "\(name).entitlements")
            let data = try Data(contentsOf: url)
            let plist = try #require(
                PropertyListSerialization.propertyList(
                    from: data,
                    format: nil
                ) as? [String: Any]
            )

            #expect(
                plist[
                    "com.apple.developer.ubiquity-kvstore-identifier"
                ] as? String == expected
            )
        }
    }
}
