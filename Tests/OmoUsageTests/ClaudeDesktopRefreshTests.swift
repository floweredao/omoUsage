import Foundation
import Testing
@testable import OmoUsage

@Suite
struct ClaudeDesktopRefreshTests {
    @Test
    func decryptsClaudeDesktopV10SessionCookie() throws {
        let encrypted = Data([
            0x76, 0x31, 0x30, 0x00, 0x01, 0x02, 0x03, 0x04,
            0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
            0x0D, 0x0E, 0x0F, 0x9B, 0x40, 0x89, 0x37, 0x4C,
            0x79, 0xB5, 0x22, 0x73, 0xFE, 0x69, 0xFB, 0x9A,
            0xE6, 0x03, 0xFA, 0x26, 0x10, 0xE9, 0xA7, 0x8A,
            0x8B, 0xF9, 0x74, 0xD2, 0x92, 0x3D, 0x9E, 0x2A,
            0x5D, 0xDA, 0xE9
        ])

        let value = try ClaudeDesktopCookieDecryptor.decrypt(
            encrypted,
            password: "test-password"
        )

        #expect(value == "session-fixture")
    }

    @Test
    func queriesClaudeSafeStorageWithoutAccountConstraint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageClaudeKeychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let cookiesURL = directory.appending(path: "Cookies")
        let historyURL = directory.appending(
            path: "plan-usage-history.json"
        )
        try Data().write(to: cookiesURL)
        try Data(#"{"samples":[]}"#.utf8).write(to: historyURL)
        let keychain = RecordingClaudeRefreshKeychain()
        let reader = ClaudeDesktopSessionReader(
            cookieDatabaseURL: cookiesURL,
            historyURL: historyURL,
            keychain: keychain
        )

        #expect(
            throws: ClaudeDesktopSessionError.keychainUnavailable
        ) {
            try reader.current()
        }
        let request = keychain.lastRequest()
        #expect(request?.service == "Claude Safe Storage")
        #expect(request?.account == "")
    }

    @Test
    func parsesScopedWeeklySubscriptionLimitsAndResets() throws {
        let data = Data(
            """
            {
              "five_hour": {
                "utilization": 10,
                "resets_at": "2026-08-15T20:30:00.123456+00:00"
              },
              "seven_day": {
                "utilization": 20,
                "resets_at": "2026-08-20T00:00:00+00:00"
              },
              "limits": [
                {
                  "kind": "weekly_scoped",
                  "group": "weekly",
                  "percent": 30,
                  "resets_at": "2026-08-20T00:00:00.654321+00:00",
                  "scope": {
                    "model": {
                      "id": "claude-opus-4-1",
                      "display_name": "Claude Opus 4.1"
                    }
                  }
                }
              ]
            }
            """.utf8
        )

        let usage = try ClaudeUsageParser.parse(
            data,
            planName: "Claude.ai",
            now: Date(timeIntervalSince1970: 1_785_675_000)
        )
        let meters = usage.groups.flatMap(\.meters)

        #expect(
            meters.map(\.id)
                == [
                    "claude.session",
                    "claude.week",
                    "claude.week.model.claude-opus-4-1"
                ]
        )
        #expect(meters.map(\.percentRemaining) == [90, 80, 70])
        #expect(meters.allSatisfy { $0.resetsAt != nil })
    }

    @Test
    func parsesFableOnlyLimitWhenModelIDIsMissing() throws {
        let data = Data(
            """
            {
              "five_hour": {"utilization": 10},
              "seven_day": {"utilization": 20},
              "limits": [
                {
                  "kind": "weekly_scoped",
                  "group": "weekly",
                  "percent": 44,
                  "resets_at": "2026-08-20T00:00:00.654321+00:00",
                  "scope": {
                    "model": {
                      "id": null,
                      "display_name": "Fable"
                    }
                  }
                }
              ]
            }
            """.utf8
        )

        let usage = try ClaudeUsageParser.parse(
            data,
            planName: "Max 20x",
            now: Date(timeIntervalSince1970: 1_785_675_000)
        )
        let fable = try #require(
            usage.groups
                .flatMap(\.meters)
                .first { $0.id == "claude.week.model.fable" }
        )

        #expect(fable.id == "claude.week.model.fable")
        #expect(fable.title == "Fable 주간")
        #expect(fable.percentRemaining == 56)
        #expect(fable.resetsAt != nil)
    }

    @Test
    func refreshesFromDesktopSessionWhenCodeCredentialMissing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "OmoUsageClaudeRefresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let historyURL = directory.appending(path: "plan-usage-history.json")
        try Data(
            """
            {
              "version": 2,
              "samples": [
                {
                  "t": 1785653400000,
                  "org": "test-organization",
                  "u": {"fh": 1, "sd": 0}
                }
              ]
            }
            """.utf8
        ).write(to: historyURL)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeRefreshURLProtocol.self]
        let provider = ClaudeUsageProvider(
            discovery: CredentialDiscovery(
                paths: CredentialPaths(
                    claude: directory.appending(path: "missing-claude.json"),
                    codex: directory.appending(path: "missing-codex.json")
                ),
                environment: [:],
                keychain: MissingClaudeRefreshKeychain(),
                homeDirectory: directory
            ),
            http: ProviderHTTP(
                session: URLSession(configuration: configuration)
            ),
            desktopUsageURL: historyURL,
            desktopSessionDiscovery: ClaudeDesktopSessionDiscovery {
                ClaudeDesktopSession(
                    organizationID: "test-organization",
                    cookieHeader: "sessionKey=<redacted>"
                )
            }
        )
        let fixedNow = Date(timeIntervalSince1970: 1_785_675_000)

        let usage = try await provider.fetch(now: fixedNow)

        #expect(
            usage.groups.flatMap(\.meters).map(\.percentRemaining)
                == [58, 75]
        )
        #expect(usage.updatedAt == fixedNow)
    }
}

private struct MissingClaudeRefreshKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private final class RecordingClaudeRefreshKeychain: KeychainReading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var request: (service: String, account: String)?

    func value(service: String, account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        request = (service, account)
        return nil
    }

    func lastRequest() -> (service: String, account: String)? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private final class ClaudeRefreshURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Data(
            """
            {
              "five_hour": {"utilization": 42},
              "seven_day": {"utilization": 25}
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
