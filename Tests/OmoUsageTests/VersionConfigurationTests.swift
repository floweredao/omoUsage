import Foundation
import Testing
@testable import OmoUsage

@Suite
struct VersionConfigurationTests {
    @Test
    func versionConfigurationIsTheOnlyVersionAndBuildSource() throws {
        let configuration = try versionConfiguration()

        #expect(configuration["MARKETING_VERSION"] == "0.1.9")
        #expect(configuration["CURRENT_PROJECT_VERSION"] == "3")

        for infoPlist in ["Info.plist", "MobileInfo.plist"] {
            let info = try propertyList(named: infoPlist)
            #expect(
                info["CFBundleShortVersionString"] as? String ==
                    "$(MARKETING_VERSION)"
            )
            #expect(
                info["CFBundleVersion"] as? String ==
                    "$(CURRENT_PROJECT_VERSION)"
            )
            #expect(
                info["OmoUsageSourceCommit"] as? String ==
                    "$(SOURCE_COMMIT)"
            )
        }
    }

    @Test
    func xcodeAndSwiftPackageManagerConsumeVersionConfiguration() throws {
        let project = try String(
            contentsOf: repositoryRoot.appending(path: "project.yml"),
            encoding: .utf8
        )
        let package = try String(
            contentsOf: repositoryRoot.appending(path: "Package.swift"),
            encoding: .utf8
        )
        let generatedProject = try String(
            contentsOf: repositoryRoot
                .appending(path: "OmoUsage.xcodeproj")
                .appending(path: "project.pbxproj"),
            encoding: .utf8
        )

        #expect(
            project.components(separatedBy: "Config/Version.xcconfig").count - 1
                == 4
        )
        #expect(package.contains("URL(fileURLWithPath: #filePath)"))
        #expect(package.contains("path: \"Config/Version.xcconfig\""))
        #expect(
            generatedProject.split(separator: "\n").filter {
                $0.contains("baseConfigurationReference") &&
                    $0.contains("Version.xcconfig")
            }.count == 4
        )
    }

    private func versionConfiguration() throws -> [String: String] {
        let contents = try String(
            contentsOf: repositoryRoot
                .appending(path: "Config")
                .appending(path: "Version.xcconfig"),
            encoding: .utf8
        )
        return Dictionary(
            uniqueKeysWithValues: contents.split(separator: "\n").compactMap {
                line in
                let assignment = line.split(
                    separator: "=",
                    maxSplits: 1
                )
                guard assignment.count == 2 else {
                    return nil
                }
                return (
                    assignment[0].trimmingCharacters(in: .whitespaces),
                    assignment[1].trimmingCharacters(in: .whitespaces)
                )
            }
        )
    }

    private func propertyList(named name: String) throws -> [String: Any] {
        let data = try Data(
            contentsOf: repositoryRoot
                .appending(path: "Config")
                .appending(path: name)
        )
        return try #require(
            PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
