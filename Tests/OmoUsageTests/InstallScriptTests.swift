import Foundation
import Testing

@Suite
struct InstallScriptTests {
    @Test
    func installsVerifiedReleaseOverExistingApp() throws {
        let fixture = try InstallScriptReleaseFixture()
        defer { fixture.remove() }
        try fixture.publish(checksumMatches: true)
        let stale = try fixture.installStaleApp()

        let result = try fixture.runInstaller()

        #expect(result.status == 0, "\(result.output)")
        #expect(FileManager.default.fileExists(atPath: fixture.installedInfoPlist.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test
    func refusesArchiveWithWrongChecksum() throws {
        let fixture = try InstallScriptReleaseFixture()
        defer { fixture.remove() }
        try fixture.publish(checksumMatches: false)
        let stale = try fixture.installStaleApp()

        let result = try fixture.runInstaller()

        #expect(result.status != 0)
        #expect(FileManager.default.fileExists(atPath: stale.path))
    }
}

private struct InstallScriptReleaseFixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "omousage-install-\(UUID().uuidString)")
    let version = "9.9.9"

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var installDirectory: URL { root.appending(path: "Applications") }
    var installedInfoPlist: URL {
        installDirectory.appending(path: "OmoUsage.app/Contents/Info.plist")
    }

    func publish(checksumMatches: Bool) throws {
        let app = root.appending(path: "build/OmoUsage.app")
        let macOS = app.appending(path: "Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: macOS.appending(path: "OmoUsage")
        )
        let info: [String: String] = [
            "CFBundleIdentifier": "com.omo.usage",
            "CFBundleExecutable": "OmoUsage",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])

        let download = root.appending(path: "releases/download/v\(version)")
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        let archive = download.appending(path: "OmoUsage-\(version).zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        let digest = checksumMatches
            ? try run("/usr/bin/shasum", ["-a", "256", archive.path]).output.prefix(64)
            : Substring(String(repeating: "0", count: 64))
        try "\(digest)  OmoUsage-\(version).zip\n"
            .write(to: download.appending(path: "SHA256SUMS"), atomically: true, encoding: .utf8)
    }

    func installStaleApp() throws -> URL {
        let marker = installDirectory.appending(path: "OmoUsage.app/stale-marker")
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: marker)
        return marker
    }

    func runInstaller() throws -> (status: Int32, output: String) {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Scripts/install.sh")
        return try run("/bin/sh", [script.path], environment: [
            "OMO_USAGE_RELEASE_BASE_URL": root.appending(path: "releases").absoluteString
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "OMO_USAGE_VERSION": version,
            "OMO_USAGE_INSTALL_DIR": installDirectory.path,
            "OMO_USAGE_NO_LAUNCH": "1"
        ], checked: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        checked: Bool = true
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(environment) { _, requested in requested }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = (process.terminationStatus, String(decoding: data, as: UTF8.self))
        if checked && result.0 != 0 {
            Issue.record("\(executable) failed: \(result.1)")
        }
        return result
    }
}
