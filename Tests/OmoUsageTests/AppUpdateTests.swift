import Foundation
import Testing

@Suite
struct AppUpdateTests {
    @Test
    func desktopUpdatesUseSignedHTTPSFeedWithoutAutomaticPrompts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Config/Info.plist"))
        let info = try #require(
            PropertyListSerialization.propertyList(
                from: data, format: nil
            ) as? [String: Any]
        )
        #expect(
            info["SUFeedURL"] as? String
                == "https://github.com/floweredao/omoUsage/releases/latest/download/appcast.xml"
        )
        let publicKey = info["SUPublicEDKey"] as? String ?? ""
        #expect(Data(base64Encoded: publicKey)?.count == 32)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }
}
