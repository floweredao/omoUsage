// swift-tools-version: 6.1
import PackageDescription

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
