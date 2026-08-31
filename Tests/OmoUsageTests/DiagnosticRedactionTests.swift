import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite(.serialized)
struct DiagnosticRedactionTests {
    private let now = Date(timeIntervalSince1970: 1_788_134_400)

    @Test
    func hostileErrorDescriptionsNeverReachStoredOrExportedDiagnostics() throws {
        let secrets = [
            "Bearer issue19-bearer-sentinel",
            "Basic aXNzdWUxOTpwYXNzd29yZA==",
            "https://loopback.invalid/usage?token=issue19-query-sentinel",
            "Cookie: session=issue19-cookie-sentinel",
            "eyJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJpc3N1ZTE5In0.signature",
            "sk-issue19-api-key-like-sentinel-1234567890",
            "/Users/issue19-private-home/.config/openusage/accounts.json",
            "issue19-private-account-alias",
            "issue19-localized-error-description",
            "provider-mutation-journal-issue19-private-label"
        ]
        let store = DiagnosticStore(capacity: secrets.count)

        for (index, secret) in secrets.enumerated() {
            let error = DiagnosticFixtureError(description: secret)
            store.record(
                DiagnosticRedactor.event(
                    error: error,
                    provider: .claude,
                    category: .providerRefresh,
                    accountOrdinal: index + 1,
                    occurredAt: now.addingTimeInterval(Double(index))
                )
            )
        }

        let data = try store.exportData()
        let exported = String(decoding: data, as: UTF8.self)
        for secret in secrets {
            #expect(!exported.contains(secret))
        }
        #expect(store.events.count == secrets.count)
        #expect(store.events.allSatisfy { $0.status == .failed })
    }

    @Test
    func exportContainsExactlyTheAllowedMachineFields() throws {
        let store = DiagnosticStore(capacity: 4)
        store.record(
            DiagnosticEvent(
                provider: .claude,
                status: .requestRejected,
                category: .providerRefresh,
                accountOrdinal: 2,
                occurredAt: now
            )
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: store.exportData())
                as? [[String: Any]]
        )
        let event = try #require(object.first)

        #expect(
            Set(event.keys) == [
                "provider", "status", "category", "schemaRevision",
                "accountOrdinal", "occurredAt"
            ]
        )
        #expect(event["provider"] as? String == ProviderID.claude.rawValue)
        #expect(event["status"] as? String == DiagnosticStatus.requestRejected.rawValue)
        #expect(event["category"] as? String == DiagnosticCategory.providerRefresh.rawValue)
        #expect(event["schemaRevision"] as? Int == 1)
        #expect(event["accountOrdinal"] as? Int == 2)
        #expect(event["occurredAt"] is String)
    }

    @Test
    func storeIsBoundedAndSanitizesOrdinalsBeforeStorage() {
        let store = DiagnosticStore(capacity: 2)
        for ordinal in [-1, 1, 2] {
            store.record(
                DiagnosticEvent(
                    provider: .openrouter,
                    status: .failed,
                    category: .accountRegistry,
                    accountOrdinal: ordinal,
                    occurredAt: now.addingTimeInterval(Double(ordinal))
                )
            )
        }

        #expect(store.events.count == 2)
        #expect(store.events.map(\.accountOrdinal) == [1, 2])
    }

    @Test
    func typedProviderFailuresAreClassifiedWithoutDescriptions() {
        let authentication = DiagnosticRedactor.event(
            error: ProviderTransportError.authenticationRequired(.claude),
            provider: .claude,
            category: .providerRefresh,
            occurredAt: now
        )
        let rejected = DiagnosticRedactor.event(
            error: ProviderTransportError.requestFailed(.claude, 503),
            provider: .claude,
            category: .providerRefresh,
            occurredAt: now
        )
        let timedOut = DiagnosticRedactor.event(
            error: ProviderTransportError.operationTimedOut(.claude),
            provider: .claude,
            category: .providerRefresh,
            occurredAt: now
        )

        #expect(authentication.status == .authenticationRequired)
        #expect(rejected.status == .requestRejected)
        #expect(timedOut.status == .timedOut)
    }

    @Test
    func exportActionWritesPrivateFileThroughChosenDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "DiagnosticRedactionTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "diagnostics.json")
        let store = DiagnosticStore(capacity: 2)
        store.record(
            DiagnosticEvent(
                status: .failed,
                category: .webListener,
                occurredAt: now
            )
        )
        let action = DiagnosticExportAction(
            store: store,
            chooseDestination: { destination }
        )

        let result = action.perform()
        let exportedURL = try #require(try result.get())
        let attributes = try FileManager.default.attributesOfItem(
            atPath: exportedURL.path
        )

        #expect(exportedURL == destination)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try Data(contentsOf: destination) == store.exportData())
    }

    @Test
    func cancellingExportDoesNotCreateAFile() throws {
        let store = DiagnosticStore(capacity: 1)
        let action = DiagnosticExportAction(
            store: store,
            chooseDestination: { nil }
        )

        #expect(try action.perform().get() == nil)
    }

    @Test
    func scopedProductionSourcesHaveNoRawLoggingBoundary() throws {
        let repository = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "Sources/OmoUsage/AppDelegate.swift",
            "Sources/OmoUsage/OmoUsageApp.swift",
            "Sources/OmoUsage/Providers/ClaudeUsageProvider.swift",
            "Sources/OmoUsage/WebDashboard/WebDashboardServer.swift"
        ]
        let forbidden = [
            "NSLog(",
            "Logger(",
            "String(describing: error)",
            "String(reflecting: error)",
            "error.localizedDescription"
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: repository.appending(path: relativePath),
                encoding: .utf8
            )
            for token in forbidden {
                #expect(!source.contains(token))
            }
        }
    }
}

private struct DiagnosticFixtureError: Error, CustomStringConvertible {
    let description: String
}
