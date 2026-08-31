import Foundation
import Testing
import OmoUsageCore

@Suite
struct CoreBoundaryTests {
    @Test
    func publicConsumerRoundTripsSchemaV4TypedMetricsAndFreshness() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_786_867_200)
        let successAt = checkedAt.addingTimeInterval(-3_600)
        let expected = DashboardSnapshot(
            providers: [
                ProviderUsage(
                    provider: .openrouter,
                    planName: "Pro",
                    groups: [
                        UsageGroup(
                            id: "typed",
                            title: nil,
                            meters: [
                                UsageMeter(
                                    id: "spend",
                                    title: "Last 30 days",
                                    period: .extra,
                                    metric: .spend(amount: 3, currency: .usd)
                                )
                            ],
                            creditText: nil
                        )
                    ],
                    availability: .available,
                    lastSuccessfulAt: successAt,
                    lastRefreshAttemptAt: checkedAt,
                    refreshFailure: .network
                )
            ],
            generatedAt: checkedAt,
            lastRefreshAttemptAt: checkedAt,
            oldestDisplayedSuccessAt: successAt
        )

        let encoded = try UsageSnapshotCodec.encode(expected)
        let decoded = try UsageSnapshotCodec.decode(encoded)
        let presentation = MobileFreshnessPresentation(
            snapshot: decoded,
            now: checkedAt.addingTimeInterval(15 * 60),
            hasSyncIssue: false
        )

        #expect(UsageSnapshotCodec.currentVersion == 4)
        #expect(decoded == expected)
        #expect(decoded.providers[0].groups[0].meters[0].metric.kind == .spend)
        #expect(decoded.providers[0].freshness == .stale)
        #expect(presentation.age == .stale)
    }

    @Test(.timeLimit(.minutes(1)))
    func packageResolvesAsAnOutOfTreeCoreDependency() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = FileManager.default.temporaryDirectory.appending(
            path: "OmoUsageCoreConsumer-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sources = fixture.appending(
            path: "Sources/Consumer",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        try """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "Consumer",
            platforms: [.macOS(.v15)],
            dependencies: [.package(path: "\(root.path)")],
            targets: [
                .executableTarget(
                    name: "Consumer",
                    dependencies: [
                        .product(name: "OmoUsageCore", package: "OmoUsage")
                    ]
                )
            ]
        )
        """.write(
            to: fixture.appending(path: "Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try """
        import OmoUsageCore
        print(UsageSnapshotCodec.currentVersion)
        """.write(
            to: sources.appending(path: "main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let logURL = fixture.appending(path: "build.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swift", "build",
            "--package-path", fixture.path,
            "--scratch-path", fixture.appending(path: ".build").path
        ]
        process.currentDirectoryURL = fixture
        process.standardOutput = log
        process.standardError = log
        try process.run()
        process.waitUntilExit()
        let buildOutput = String(
            data: try Data(contentsOf: logURL),
            encoding: .utf8
        ) ?? "out-of-tree build failed"

        #expect(
            process.terminationStatus == 0,
            Comment(rawValue: buildOutput)
        )
    }
}
