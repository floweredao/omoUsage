import Foundation
import Testing
@testable import OmoUsage

@Suite
@MainActor
struct CopilotDeviceAuthenticationTests {
    private static let device = #"{"device_code":"fixture-device","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#

    @Test
    func deviceFlowHonorsPendingAndSlowDownThenReturnsTheToken() async throws {
        let server = CopilotDeviceServer(responses: [
            Self.device,
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down","interval":10}"#,
            #"{"access_token":"fixture-github-token","token_type":"bearer","scope":"read:user"}"#
        ])
        var waits: [Int] = []
        var presented: CopilotDeviceCode?
        let snapshot = try await CopilotDeviceAuthenticationClient(
            exchange: { try server.respond($0, $1) },
            pollWait: { waits.append($0) }
        ).authenticate { code in
            presented = code
            return true
        }

        #expect(presented == CopilotDeviceCode(
            userCode: "ABCD-1234",
            verificationURL: URL(string: "https://github.com/login/device")!
        ))
        #expect(waits == [5, 5, 10])
        #expect(snapshot.provider == .copilot)
        #expect(snapshot.accessToken == "fixture-github-token")
        #expect(snapshot.source == .keychain)

        let codeRequest = server.requests[0]
        #expect(codeRequest.purpose == .copilotDeviceCode)
        #expect(codeRequest.request.url?.absoluteString == "https://github.com/login/device/code")
        try ProviderContractCatalog.endpoint(.copilotDeviceCode, for: .copilot).validate(codeRequest.request)
        #expect(Self.form(codeRequest.request) == ["client_id": "Iv1.b507a08c87ecfe98", "scope": "read:user"])
        let tokenRequest = server.requests[1]
        #expect(tokenRequest.purpose == .copilotDeviceToken)
        try ProviderContractCatalog.endpoint(.copilotDeviceToken, for: .copilot).validate(tokenRequest.request)
        #expect(Self.form(tokenRequest.request) == [
            "client_id": "Iv1.b507a08c87ecfe98",
            "device_code": "fixture-device",
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])
    }

    @Test(arguments: [
        (#"{"error":"access_denied"}"#, ClaudeBrowserAuthenticationError.authorizationDenied),
        (#"{"error":"expired_token"}"#, .timedOut),
        (#"{"error":"unsupported_grant_type"}"#, .exchangeFailed),
        (#"{"access_token":"has space"}"#, .invalidToken)
    ])
    func terminalPollResponsesEndTheSignIn(
        _ response: String,
        _ expected: ClaudeBrowserAuthenticationError
    ) async {
        let server = CopilotDeviceServer(responses: [Self.device, response])
        await #expect(throws: expected) {
            try await CopilotDeviceAuthenticationClient(
                exchange: { try server.respond($0, $1) },
                pollWait: { _ in }
            ).authenticate { _ in true }
        }
    }

    @Test
    func verificationPageOutsideGitHubIsNeverOpened() async {
        let server = CopilotDeviceServer(responses: [
            Self.device.replacingOccurrences(of: "https://github.com/login/device", with: "https://example.com/login/device")
        ])
        var presented = false
        await #expect(throws: ClaudeBrowserAuthenticationError.invalidToken) {
            try await CopilotDeviceAuthenticationClient(
                exchange: { try server.respond($0, $1) },
                pollWait: { _ in }
            ).authenticate { _ in
                presented = true
                return true
            }
        }
        #expect(!presented)
    }

    @Test
    func codeThatNeverGetsApprovedTimesOutAtTheDeviceDeadline() async {
        let shortDevice = Self.device.replacingOccurrences(of: #""expires_in":900"#, with: #""expires_in":12"#)
        let server = CopilotDeviceServer(responses: [shortDevice] + Array(
            repeating: #"{"error":"authorization_pending"}"#, count: 5
        ))
        var waits: [Int] = []
        await #expect(throws: ClaudeBrowserAuthenticationError.timedOut) {
            try await CopilotDeviceAuthenticationClient(
                exchange: { try server.respond($0, $1) },
                pollWait: { waits.append($0) }
            ).authenticate { _ in true }
        }
        #expect(waits == [5, 5])
    }

    private static func form(_ request: URLRequest) -> [String: String] {
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }
}

@MainActor
private final class CopilotDeviceServer {
    private var responses: [String]
    private(set) var requests: [(request: URLRequest, purpose: ProviderEndpointPurpose)] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func respond(_ request: URLRequest, _ purpose: ProviderEndpointPurpose) throws -> Data {
        requests.append((request, purpose))
        return Data(try #require(responses.isEmpty ? nil : responses.removeFirst()).utf8)
    }
}
