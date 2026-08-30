import Foundation
import Security
import Testing
@testable import OmoUsage

@Suite
struct AntigravityReliabilityTests {
    private let agReliabilityNow = Date(timeIntervalSince1970: 1_786_800_000)

    @Test
    func parsesAvailableModelsQuotaInfoAndResetTime() throws {
        let usage = try AntigravityUsageParser.parse(
            Data(
                """
                {
                  "models": {
                    "gemini-3.1-pro": {
                      "model": "MODEL_GEMINI_31_PRO",
                      "displayName": "Gemini 3.1 Pro (High)",
                      "quotaInfo": {
                        "remainingFraction": 0.42,
                        "resetTime": "2026-08-20T10:15:30Z"
                      }
                    },
                    "claude-sonnet-4.6": {
                      "model": "MODEL_CLAUDE_SONNET_46",
                      "displayName": "Claude Sonnet 4.6 (Thinking)",
                      "quotaInfo": {
                        "remainingFraction": 0.7,
                        "resetTime": "2026-08-20T11:45:00Z"
                      }
                    }
                  }
                }
                """.utf8
            ),
            now: agReliabilityNow
        )

        #expect(usage.groups.map(\.title) == [
            "Gemini Models",
            "Claude and GPT models"
        ])
        #expect(
            usage.groups.flatMap(\.meters).map(\.percentRemaining)
                == [42, 70]
        )
        #expect(
            usage.groups.flatMap(\.meters).map(\.resetsAt)
                == [
                    agReliabilityDate("2026-08-20T10:15:30Z"),
                    agReliabilityDate("2026-08-20T11:45:00Z")
                ]
        )
    }

    @Test
    func fallsBackAcrossRemoteHostsUsingAvailableModelsPath() async {
        let accessToken = "ag-reliability-\(UUID().uuidString)"
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [
            AGReliabilityURLProtocol.self
        ]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(
                claude: URL(filePath: "/ag-reliability/missing-claude"),
                codex: URL(filePath: "/ag-reliability/missing-codex")
            ),
            environment: [:],
            keychain: AGReliabilityTokenKeychain(accessToken: accessToken)
        )
        let provider = AntigravityUsageProvider(
            discovery: discovery,
            http: providerHTTPTestClient(
                session: session,
                retryPolicy: ProviderRetryPolicy(maximumAttempts: 1)
            )
        )

        let usage = try? await provider.fetch(now: agReliabilityNow)
        let requests = AGReliabilityURLProtocol.requests(
            bearing: accessToken
        )

        #expect(usage?.groups.first?.meters.first?.percentRemaining == 64)
        #expect(requests.map { $0.url?.absoluteString } == [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
            "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
        ])
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Content-Type")
                == "application/json"
        })
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "User-Agent")
                == "antigravity"
        })
    }

    @Test
    func preservesKeychainAccessFailureInsteadOfReportingMissingCredential() {
        let missing = URL(filePath: "/ag-reliability/missing")
        let discovery = CredentialDiscovery(
            paths: CredentialPaths(claude: missing, codex: missing),
            environment: [:],
            keychain: AGReliabilityFailingKeychain()
        )

        #expect(throws: KeychainReadError(status: errSecAuthFailed)) {
            _ = try discovery.antigravity(now: agReliabilityNow)
        }
    }

    private func agReliabilityDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

private struct AGReliabilityTokenKeychain: KeychainReading {
    let accessToken: String

    func value(service: String, account: String) throws -> String? {
        guard service == "gemini", account == "antigravity" else {
            return nil
        }
        return """
        {
          "access_token": "\(accessToken)",
          "expiry": 4102444800
        }
        """
    }
}

private struct AGReliabilityFailingKeychain: KeychainReading {
    func value(service: String, account: String) throws -> String? {
        throw KeychainReadError(status: errSecAuthFailed)
    }
}

private final class AGReliabilityRequestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    func requests(bearing accessToken: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.filter {
            $0.value(forHTTPHeaderField: "Authorization")
                == "Bearer \(accessToken)"
        }
    }
}

private final class AGReliabilityURLProtocol: URLProtocol {
    private static let requestStore = AGReliabilityRequestStore()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        #expect(requestBodyData(request) == Data("{}".utf8))
        Self.requestStore.append(request)
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }

        let isAvailableModels = url.path
            == "/v1internal:fetchAvailableModels"
        let isFallbackHost = url.host
            == "cloudcode-pa.googleapis.com"
        let statusCode = isAvailableModels && isFallbackHost ? 200 : 503
        let body = statusCode == 200
            ? """
              {
                "models": {
                  "gemini-3.1-pro": {
                    "displayName": "Gemini 3.1 Pro (High)",
                    "quotaInfo": {
                      "remainingFraction": 0.64,
                      "resetTime": "2026-08-20T10:15:30Z"
                    }
                  }
                }
              }
              """
            : "{}"
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
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

    static func requests(bearing accessToken: String) -> [URLRequest] {
        requestStore.requests(bearing: accessToken)
    }
}
