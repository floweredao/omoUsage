import Foundation
import Testing
@testable import OmoUsage

@Suite
struct CursorReliabilityTests {
    @Test
    func primaryUsageSummaryUsesCurrentGETContract() async throws {
        try await CursorReliabilityFixture.withDirectory { home in
            let token = "cursor-reliability-contract-\(UUID().uuidString)"
            try CursorReliabilityFixture.createCredential(
                token: token,
                home: home
            )
            CursorReliabilityURLProtocol.register(
                token: token,
                response: .legacyCompatible
            )
            defer { CursorReliabilityURLProtocol.unregister(token: token) }

            _ = try await CursorReliabilityFixture.provider(
                home: home
            ).fetch(now: Date(timeIntervalSince1970: 1_786_032_000))

            let requests = CursorReliabilityURLProtocol.requests(token: token)
            let summary = requests.first {
                $0.url?.host == "api2.cursor.sh"
                    && $0.url?.path == "/api/usage-summary"
            }
            #expect(summary != nil)
            #expect(summary?.httpMethod == "GET")
            #expect(
                summary?.value(forHTTPHeaderField: "Authorization")
                    == "Bearer \(token)"
            )
            #expect(
                summary?.value(forHTTPHeaderField: "Accept")
                    == "application/json"
            )
            #expect(summary?.httpBody == nil)
        }
    }

    @Test
    func mapsCurrentUsageAndBillingCycleFields() async throws {
        try await CursorReliabilityFixture.withDirectory { home in
            let token = "cursor-reliability-mapping-\(UUID().uuidString)"
            try CursorReliabilityFixture.createCredential(
                token: token,
                home: home
            )
            CursorReliabilityURLProtocol.register(
                token: token,
                response: .currentSummary
            )
            defer { CursorReliabilityURLProtocol.unregister(token: token) }
            let now = Date(timeIntervalSince1970: 1_786_032_000)
            let expectedReset = try #require(
                ISO8601DateFormatter().date(
                    from: "2026-09-01T00:00:00Z"
                )
            )

            let usage = try await CursorReliabilityFixture.provider(
                home: home
            ).fetch(now: now)

            #expect(usage.planName == "Pro")
            let meters = usage.groups.flatMap(\.meters)
            #expect(meters.map(\.title) == [
                "총 사용량", "Auto 사용량", "API 사용량", "크레딧"
            ])
            #expect(meters.map(\.metric) == [
                .quotaRemaining(percent: 75),
                .quotaRemaining(percent: 80),
                .quotaRemaining(percent: 70),
                .credit(balance: 875, unit: .credits)
            ])
            #expect(meters.dropLast().allSatisfy { $0.resetsAt == expectedReset })
            #expect(meters.last?.resetsAt == nil)
            #expect(usage.updatedAt == now)
        }
    }

    @Test
    func corruptCursorDatabaseIsNotReportedAsLoggedOut() throws {
        try CursorReliabilityFixture.withDirectory { home in
            let database = CursorReliabilityFixture.database(home: home)
            try FileManager.default.createDirectory(
                at: database.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("not a sqlite database".utf8).write(to: database)
            let discovery = CursorReliabilityFixture.discovery(home: home)

            #expect(throws: LocalDataAccessError.commandFailed) {
                try discovery.cursor(
                    now: Date(timeIntervalSince1970: 1_786_032_000)
                )
            }
        }
    }
}

private enum CursorReliabilityFixture {
    static func provider(home: URL) -> CursorUsageProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CursorReliabilityURLProtocol.self]
        return CursorUsageProvider(
            discovery: discovery(home: home),
            http: ProviderHTTP(
                session: URLSession(configuration: configuration)
            )
        )
    }

    static func discovery(home: URL) -> CredentialDiscovery {
        CredentialDiscovery(
            paths: CredentialPaths(
                claude: home.appending(path: "missing-claude.json"),
                codex: home.appending(path: "missing-codex.json")
            ),
            environment: [:],
            keychain: CursorReliabilityKeychain(),
            homeDirectory: home,
            commandPaths: []
        )
    }

    static func database(home: URL) -> URL {
        home.appending(
            components: "Library",
            "Application Support",
            "Cursor",
            "User",
            "globalStorage",
            "state.vscdb"
        )
    }

    static func createCredential(token: String, home: URL) throws {
        let database = database(home: home)
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [
            database.path,
            """
            CREATE TABLE ItemTable(key TEXT, value TEXT);
            INSERT INTO ItemTable VALUES(
              'cursorAuth/accessToken',
              '\(token)'
            );
            """
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LocalDataAccessError.commandFailed
        }
    }

    static func withDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "OmoUsageCursorReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    static func withDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "OmoUsageCursorReliability-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}

private struct CursorReliabilityKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private final class CursorReliabilityRequestStore: @unchecked Sendable {
    enum Response {
        case legacyCompatible
        case currentSummary
    }

    static let shared = CursorReliabilityRequestStore()

    private let lock = NSLock()
    private var entries: [String: (Response, [URLRequest])] = [:]

    func register(token: String, response: Response) {
        lock.withLock {
            entries[token] = (response, [])
        }
    }

    func unregister(token: String) {
        _ = lock.withLock {
            entries.removeValue(forKey: token)
        }
    }

    func record(_ request: URLRequest) -> Response? {
        lock.withLock {
            guard let token = Self.token(from: request),
                  var entry = entries[token]
            else {
                return nil
            }
            entry.1.append(request)
            entries[token] = entry
            return entry.0
        }
    }

    func requests(token: String) -> [URLRequest] {
        lock.withLock { entries[token]?.1 ?? [] }
    }

    private static func token(from request: URLRequest) -> String? {
        let prefix = "Bearer "
        guard let authorization = request.value(
            forHTTPHeaderField: "Authorization"
        ), authorization.hasPrefix(prefix) else {
            return nil
        }
        return String(authorization.dropFirst(prefix.count))
    }
}

private final class CursorReliabilityURLProtocol: URLProtocol,
    @unchecked Sendable
{
    static func register(
        token: String,
        response: CursorReliabilityRequestStore.Response
    ) {
        CursorReliabilityRequestStore.shared.register(
            token: token,
            response: response
        )
    }

    static func unregister(token: String) {
        CursorReliabilityRequestStore.shared.unregister(token: token)
    }

    static func requests(token: String) -> [URLRequest] {
        CursorReliabilityRequestStore.shared.requests(token: token)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api2.cursor.sh"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let responseKind = CursorReliabilityRequestStore.shared.record(
            request
        ), let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }
        let body: String = switch responseKind {
        case .legacyCompatible:
            if url.path.hasSuffix("GetPlanInfo") {
                #"{"planName":"Pro"}"#
            } else {
                #"{"planUsage":{"usedPercent":25}}"#
            }
        case .currentSummary:
            """
            {
              "billingCycleStart": "2026-08-01T00:00:00Z",
              "billingCycleEnd": "2026-09-01T00:00:00Z",
              "membershipType": "pro",
              "individualUsage": {
                "plan": {
                  "enabled": true,
                  "used": 500,
                  "limit": 2000,
                  "remaining": 1500,
                  "totalPercentUsed": 25,
                  "autoPercentUsed": 20,
                  "apiPercentUsed": 30
                },
                "onDemand": {
                  "enabled": true,
                  "used": 125,
                  "limit": 1000,
                  "remaining": 875
                }
              }
            }
            """
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
