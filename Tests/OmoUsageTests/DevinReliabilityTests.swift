import Foundation
import Testing
@testable import OmoUsage

@Suite
struct DevinReliabilityTests {
    @Test
    func parsesCurrentUserStatusPlanStatusEnvelope() async throws {
        try await hephaestusDevinWithTemporaryDirectory { directory in
            let credentials = directory.appending(
                path: ".local/share/devin/credentials.toml"
            )
            try FileManager.default.createDirectory(
                at: credentials.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                "windsurf_api_key = \"hephaestus-devin-token\"".utf8
            ).write(to: credentials)

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [
                HephaestusDevinPlanStatusURLProtocol.self
            ]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let provider = DevinUsageProvider(
                discovery: CredentialDiscovery(
                    paths: CredentialPaths(
                        claude: directory.appending(path: "missing-claude.json"),
                        codex: directory.appending(path: "missing-codex.json")
                    ),
                    environment: [:],
                    keychain: HephaestusDevinMissingKeychain(),
                    homeDirectory: directory,
                    commandPaths: []
                ),
                http: ProviderHTTP(session: session)
            )
            let now = Date(timeIntervalSince1970: 1_786_032_000)

            let usage = try await provider.fetch(now: now)

            #expect(usage.provider == .devin)
            #expect(usage.planName == "Core")
            #expect(usage.updatedAt == now)

            let meters = usage.groups.flatMap(\.meters)
            let daily = try #require(
                meters.first { $0.period == .session }
            )
            let weekly = try #require(
                meters.first { $0.period == .week }
            )
            #expect(daily.percentRemaining == 80)
            #expect(
                daily.resetsAt?.timeIntervalSince1970 == 1_900_000_000
            )
            #expect(weekly.percentRemaining == 68)
            #expect(
                weekly.resetsAt?.timeIntervalSince1970 == 1_900_500_000
            )
            #expect(
                hephaestusDevinMonetaryValue(
                    usage.groups.first?.creditText
                ) == 10
            )
        }
    }

    @Test
    func rejectsUntrustedCredentialServerBeforeSendingAPIKey() async throws {
        try await hephaestusDevinWithTemporaryDirectory { directory in
            let credentials = directory.appending(
                path: ".local/share/devin/credentials.toml"
            )
            try FileManager.default.createDirectory(
                at: credentials.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(
                """
                windsurf_api_key = "hephaestus-devin-token"
                api_server_url = "http://evil.example"
                """.utf8
            ).write(to: credentials)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [
                HephaestusDevinPlanStatusURLProtocol.self
            ]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let provider = DevinUsageProvider(
                discovery: CredentialDiscovery(
                    paths: CredentialPaths(
                        claude: directory.appending(path: "missing-claude.json"),
                        codex: directory.appending(path: "missing-codex.json")
                    ),
                    environment: [:],
                    keychain: HephaestusDevinMissingKeychain(),
                    homeDirectory: directory,
                    commandPaths: []
                ),
                http: ProviderHTTP(session: session)
            )

            do {
                _ = try await provider.fetch(now: .now)
                Issue.record("Expected unsafe endpoint rejection")
            } catch {
                #expect(
                    error as? ProviderTransportError
                        == .invalidResponse(.devin)
                )
            }
        }
    }
}

private struct HephaestusDevinMissingKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        nil
    }
}

private final class HephaestusDevinPlanStatusURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        #expect(
            request.url?.absoluteString
                == "https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
        )
        #expect(request.httpMethod == "POST")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "application/json"
        )
        #expect(
            request.value(
                forHTTPHeaderField: "Connect-Protocol-Version"
            ) == "1"
        )
        let requestBody = requestBodyData(request).flatMap {
            try? UsageJSON.object($0)
        }
        let metadata = requestBody.flatMap {
            UsageJSON.object($0["metadata"])
        }
        #expect(metadata?["apiKey"] as? String == "hephaestus-devin-token")
        #expect(metadata?["ideName"] as? String == "devin")
        #expect(metadata?["ideVersion"] as? String == "1.108.2")
        #expect(metadata?["extensionName"] as? String == "devin")
        #expect(metadata?["extensionVersion"] as? String == "1.108.2")
        #expect(metadata?["locale"] as? String == "ko")
        let body = Data(
            """
            {
              "userStatus": {
                "planStatus": {
                  "planInfo": {
                    "planName": "Core",
                    "hideDailyQuota": false
                  },
                  "dailyQuotaRemainingPercent": 80,
                  "weeklyQuotaRemainingPercent": 68,
                  "dailyQuotaResetAtUnix": 1900000000,
                  "weeklyQuotaResetAtUnix": 1900500000,
                  "overageBalanceMicros": 10000000
                }
              }
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

private func hephaestusDevinWithTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "HephaestusDevinReliability-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func hephaestusDevinMonetaryValue(_ text: String?) -> Decimal? {
    guard let text else { return nil }
    let scalarSet = CharacterSet(charactersIn: "0123456789.-")
    let number = text.unicodeScalars
        .filter { scalarSet.contains($0) }
        .map(String.init)
        .joined()
    return Decimal(string: number, locale: Locale(identifier: "en_US_POSIX"))
}
