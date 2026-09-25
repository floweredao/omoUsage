// swift-tools-version: 6.1
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let versionConfiguration = try String(
    contentsOf: packageRoot.appending(
        path: "Config/Version.xcconfig"
    ),
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
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "OmoUsageCore", targets: ["OmoUsageCore"]),
        .executable(name: "OmoUsage", targets: ["OmoUsage"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.6"
        )
    ],
    targets: [
        .target(
            name: "OmoUsageCore",
            path: "Sources/OmoUsageCore",
            exclude: ["AGENTS.md"],
            sources: [
                "Localization/AppLanguage.swift",
                "Localization/AppStrings.swift",
                "Localization/ProviderTextLocalization.swift",
                "Models/DashboardSnapshot.swift",
                "Models/ProviderID.swift",
                "Models/ProviderVisualStyle.swift",
                "Models/UsageModels.swift",
                "Models/ProviderDisplayOrder.swift",
                "Sync/UsageSnapshotSync.swift"
            ]
        ),
        .executableTarget(
            name: "OmoUsage",
            dependencies: [
                "OmoUsageCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/OmoUsage",
            exclude: [
                "Mobile",
                "AGENTS.md",
                "Credentials/AGENTS.md",
                "Providers/AGENTS.md",
                "Settings/AGENTS.md",
                "WebDashboard/AGENTS.md"
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .define(
                    "OMO_USAGE_MARKETING_VERSION_\(marketingVersion.replacingOccurrences(of: ".", with: "_"))"
                ),
                .define("OMO_USAGE_BUILD_\(currentProjectVersion)"),
                .define(
                    "OMO_USAGE_FIXTURES",
                    .when(configuration: .debug)
                )
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "OmoUsageTests",
            dependencies: ["OmoUsage", "OmoUsageCore"],
            path: "Tests/OmoUsageTests",
            exclude: ["AGENTS.md"]
        )
    ]
)
