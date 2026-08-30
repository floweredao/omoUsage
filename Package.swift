// swift-tools-version: 6.1
import Foundation
import PackageDescription

let versionConfiguration = try String(
    contentsOfFile: "Config/Version.xcconfig",
    encoding: .utf8
)
let versionSettings: [String: String] = Dictionary(
    uniqueKeysWithValues: versionConfiguration.split(separator: "\n").compactMap {
        line in
        let assignment = line.split(separator: "=", maxSplits: 1)
        guard assignment.count == 2 else {
            return nil
        }
        return (
            assignment[0].trimmingCharacters(in: .whitespaces),
            assignment[1].trimmingCharacters(in: .whitespaces)
        )
    }
)
let marketingVersion = versionSettings["MARKETING_VERSION"]!
let currentProjectVersion = versionSettings["CURRENT_PROJECT_VERSION"]!

let package = Package(
    name: "OmoUsage",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "OmoUsage", targets: ["OmoUsage"])
    ],
    targets: [
        .executableTarget(
            name: "OmoUsage",
            path: "Sources/OmoUsage",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .define(
                    "OMO_USAGE_MARKETING_VERSION_\(marketingVersion.replacingOccurrences(of: ".", with: "_"))"
                ),
                .define("OMO_USAGE_BUILD_\(currentProjectVersion)")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "OmoUsageTests",
            dependencies: ["OmoUsage"],
            path: "Tests/OmoUsageTests"
        )
    ]
)
