import Foundation
import Testing
@testable import OmoUsage

@Suite
struct WebDashboardAuthenticationTests {
    private let localHost = "127.0.0.1:7827"
    private let localOrigin = "http://127.0.0.1:7827"

    @Test
    func acceptedHostsCanReadWithoutBrowserSession() {
        let gateway = makeGateway()

        let read = gateway.response(
            request: request(method: "GET", path: "/api/snapshot")
        )
        let mutation = gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh",
                headers: ["origin": localOrigin]
            )
        )

        #expect(read.statusCode == 200)
        #expect(mutation.statusCode == 403)
    }

    @Test
    func malformedAndForeignHostsAreRejected() {
        let gateway = makeGateway()

        let missing = gateway.response(
            request: WebDashboardHTTPRequest(method: "GET", path: "/")
        )
        let malformed = gateway.response(
            request: request(
                method: "GET",
                path: "/",
                headers: ["host": "127.0.0.1:7827,evil.example"]
            )
        )
        let foreign = gateway.response(
            request: request(
                method: "GET",
                path: "/",
                headers: ["host": "evil.example"]
            )
        )

        #expect(missing.statusCode == 400)
        #expect(malformed.statusCode == 400)
        #expect(foreign.statusCode == 403)
    }

    @Test
    func dashboardURLIsStableAndContainsNoCredentials() {
        let store = makeStore()
        let first = store.dashboardURL
        let second = store.dashboardURL

        #expect(first == second)
        #expect(first.absoluteString == "http://127.0.0.1:7827")
        #expect(first.query == nil)
    }

    @Test
    func fixtureDashboardURLExportIsExplicitAndNeverProduction() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "WebDashboardURLExport-\(UUID().uuidString)"
        )
        let fixtureURL = directory.appending(path: "dashboard-url.txt")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = makeStore()

        try FixtureWebDashboardURLExporter.exportIfRequested(
            accessStore: store,
            environment: [
                "OMO_USAGE_FIXTURE_MODE": "1",
                "OMO_USAGE_DASHBOARD_URL_FILE": fixtureURL.path
            ]
        )

        let value = try String(contentsOf: fixtureURL, encoding: .utf8)
        let permissions = try #require(
            try FileManager.default.attributesOfItem(
                atPath: fixtureURL.path
            )[.posixPermissions] as? NSNumber
        )
        #expect(value == "http://127.0.0.1:7827\n")
        #expect(permissions.intValue == 0o600)

        try FileManager.default.removeItem(at: fixtureURL)
        try FixtureWebDashboardURLExporter.exportIfRequested(
            accessStore: store,
            environment: [
                "OMO_USAGE_DASHBOARD_URL_FILE": fixtureURL.path
            ]
        )
        #expect(!FileManager.default.fileExists(atPath: fixtureURL.path))
    }

    @Test
    func acceptedHostServesHTMLAndAPIReadsWithoutCookies() {
        let gateway = makeGateway()

        let html = gateway.response(
            request: request(
                method: "GET",
                path: "/"
            )
        )
        let api = gateway.response(
            request: request(
                method: "GET",
                path: "/api/snapshot"
            )
        )

        #expect(html.statusCode == 200)
        #expect(api.statusCode == 200)
    }

    @Test
    func mutationsRequireExactOriginAndCSRF() {
        let gateway = makeGateway()
        let missingOrigin = gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh"
            )
        )
        let foreignOrigin = gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh",
                headers: ["origin": "https://evil.example"]
            )
        )
        let missingCSRF = gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh",
                headers: ["origin": localOrigin]
            )
        )
        let accepted = gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh",
                headers: [
                    "origin": localOrigin,
                    "x-omo-csrf": "fixture-csrf"
                ]
            )
        )

        #expect(missingOrigin.statusCode == 403)
        #expect(foreignOrigin.statusCode == 403)
        #expect(missingCSRF.statusCode == 403)
        #expect(accepted.statusCode == 202)
    }

    @Test
    func localIsDefaultAndRemoteModeRequiresExactTailscaleHost() {
        let local = WebDashboardAccessMode.resolve(
            environment: [:],
            port: 7_827
        )
        let remote = WebDashboardAccessMode.resolve(
            environment: [
                "OMO_USAGE_WEB_TAILSCALE_HOST":
                    "fixture-device.fixture-tailnet.ts.net"
            ],
            port: 7_827
        )
        let invalidRemote = WebDashboardAccessMode.resolve(
            environment: [
                "OMO_USAGE_WEB_TAILSCALE_HOST": "public.example"
            ],
            port: 7_827
        )

        #expect(local == .local(port: 7_827))
        #expect(local.accepts(host: "127.0.0.1:7827"))
        #expect(local.accepts(host: "localhost:7827"))
        #expect(!local.accepts(host: "0.0.0.0:7827"))
        #expect(!local.accepts(host: "[::1]:7827"))
        #expect(
            remote == .tailscale(
                host: "fixture-device.fixture-tailnet.ts.net",
                httpsPort: 443
            )
        )
        #expect(invalidRemote == .local(port: 7_827))
        #expect(
            remote.accepts(
                host: "fixture-device.fixture-tailnet.ts.net"
            )
        )
        #expect(!remote.accepts(host: "other.fixture-tailnet.ts.net"))

        let remoteStore = WebDashboardAccessStore(mode: remote)
        let remoteURL = remoteStore.dashboardURL
        #expect(
            remoteURL.absoluteString
                == "https://fixture-device.fixture-tailnet.ts.net"
        )
        let remoteGateway = makeGateway(store: remoteStore)
        let read = remoteGateway.response(
            request: WebDashboardHTTPRequest(
                method: "GET",
                path: "/",
                headers: [
                    "host": "fixture-device.fixture-tailnet.ts.net"
                ]
            )
        )
        #expect(read.statusCode == 200)
    }

    @Test
    func switchingAccessModeUpdatesStableDashboardURL() {
        let store = makeStore()
        #expect(
            store.dashboardURL.absoluteString
                == "http://127.0.0.1:7827"
        )

        store.updateMode(
            .tailscale(
                host: "fixture-device.fixture-tailnet.ts.net",
                httpsPort: 8_443
            )
        )

        #expect(
            store.dashboardURL.absoluteString
                == "https://fixture-device.fixture-tailnet.ts.net:8443"
        )
    }

    @Test
    func tailscaleCLIUsesPrivateDedicatedServePort() throws {
        let recorder = TailscaleCommandRecorder(responses: [
            TailscaleCommandResult(
                status: 0,
                standardOutput: Data(
                    """
                    {
                      "BackendState": "Running",
                      "Self": {
                        "DNSName": "fixture-device.fixture-tailnet.ts.net.",
                        "Online": true
                      }
                    }
                    """.utf8
                ),
                standardError: Data()
            ),
            TailscaleCommandResult(
                status: 0,
                standardOutput: Data("{}".utf8),
                standardError: Data()
            ),
            TailscaleCommandResult(
                status: 0,
                standardOutput: Data(),
                standardError: Data()
            ),
            TailscaleCommandResult(
                status: 0,
                standardOutput: Data(),
                standardError: Data()
            )
        ])
        let client = TailscaleCLIService(
            executable: URL(filePath: "/fixture/tailscale"),
            execute: recorder.run
        )

        #expect(
            try client.inspect(dashboardPort: 7_827)
                == .available(
                    host: "fixture-device.fixture-tailnet.ts.net"
                )
        )
        try client.enable(dashboardPort: 7_827)
        try client.disable()

        #expect(recorder.arguments() == [
            ["status", "--json", "--peers=false"],
            ["serve", "status", "--json"],
            [
                "serve", "--bg", "--yes", "--https=8443",
                "7827"
            ],
            ["serve", "--https=8443", "off"]
        ])
    }

    @Test
    func tailscaleCLIRecognizesItsExistingServeMapping() throws {
        let recorder = TailscaleCommandRecorder(responses: [
            TailscaleCommandResult(
                status: 0,
                standardOutput: Data(
                    """
                    {
                      "BackendState": "Running",
                      "Self": {
                        "DNSName": "fixture-device.fixture-tailnet.ts.net.",
                        "Online": true
                      }
                    }
                    """.utf8
                ),
                standardError: Data()
            ),
            TailscaleCommandResult(
                status: 0,
                standardOutput: Data(
                    """
                    {
                      "TCP": { "8443": { "HTTPS": true } },
                      "Web": {
                        "fixture-device.fixture-tailnet.ts.net:8443": {
                          "Handlers": {
                            "/": {
                              "Proxy": "http://127.0.0.1:7827"
                            }
                          }
                        }
                      }
                    }
                    """.utf8
                ),
                standardError: Data()
            )
        ])
        let client = TailscaleCLIService(
            executable: URL(filePath: "/fixture/tailscale"),
            execute: recorder.run
        )

        #expect(
            try client.inspect(dashboardPort: 7_827)
                == .ready(
                    host: "fixture-device.fixture-tailnet.ts.net"
                )
        )
    }

    @Test(arguments: [
        // The expected port and target must belong to the same handler.
        """
        {"TCP":{"8443":{"HTTPS":true}},"Web":{
          "fixture-device.fixture-tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8787"}}},
          "fixture-device.fixture-tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7827"}}}
        }}
        """,
        """
        {"TCP":{"8443":{"HTTPS":true}},"Web":{
          "other-device.fixture-tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7827"}}}
        }}
        """,
        """
        {"TCP":{"8443":{"HTTPS":true}},"Web":{
          "fixture-device.fixture-tailnet.ts.net:8443":{"Handlers":{"/other":{"Proxy":"http://127.0.0.1:7827"}}}
        }}
        """,
        """
        {"TCP":{"8443":{"HTTPS":false}},"Web":{
          "fixture-device.fixture-tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7827"}}}
        }}
        """,
        """
        {"Web":{
          "fixture-device.fixture-tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7827"}}}
        }}
        """,
        """
        {"TCP":{"8443":{"HTTPS":true}},"Web":{
          "fixture-device.fixture-tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7827"}}}
        },"AllowFunnel":{"fixture-device.fixture-tailnet.ts.net:8443":true}}
        """
    ])
    func tailscaleCLIRejectsUnrelatedOrNonPrivateServeMappings(
        configuration: String
    ) throws {
        let recorder = TailscaleCommandRecorder(responses: [
            TailscaleCommandResult(
                status: 0,
                standardOutput: Data(
                    """
                    {"BackendState":"Running","Self":{
                      "DNSName":"fixture-device.fixture-tailnet.ts.net.",
                      "Online":true
                    }}
                    """.utf8
                ),
                standardError: Data()
            ),
            TailscaleCommandResult(
                status: 0,
                standardOutput: Data(configuration.utf8),
                standardError: Data()
            )
        ])
        let client = TailscaleCLIService(
            executable: URL(filePath: "/fixture/tailscale"),
            execute: recorder.run
        )

        #expect(
            try client.inspect(dashboardPort: 7_827)
                == .available(host: "fixture-device.fixture-tailnet.ts.net")
        )
    }

    private func makeStore() -> WebDashboardAccessStore {
        WebDashboardAccessStore(mode: .local(port: 7_827))
    }

    private func makeGateway(
        store: WebDashboardAccessStore? = nil
    ) -> WebDashboardAccessGateway {
        WebDashboardAccessGateway(
            accessStore: store ?? makeStore(),
            router: WebDashboardRouter(
                snapshotData: { Data(#"{"fixture":true}"#.utf8) },
                indexHTML: Data("fixture html".utf8),
                mutationNonce: "fixture-csrf"
            )
        )
    }

    private func request(
        method: String,
        path: String,
        query: String? = nil,
        headers: [String: String] = [:]
    ) -> WebDashboardHTTPRequest {
        WebDashboardHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: ["host": localHost].merging(
                headers,
                uniquingKeysWith: { _, new in new }
            )
        )
    }
}

private final class TailscaleCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [TailscaleCommandResult]
    private var calls: [[String]] = []

    init(responses: [TailscaleCommandResult]) {
        self.responses = responses
    }

    func run(
        executable: URL,
        arguments: [String]
    ) throws -> TailscaleCommandResult {
        lock.withLock {
            calls.append(arguments)
            return responses.removeFirst()
        }
    }

    func arguments() -> [[String]] {
        lock.withLock { calls }
    }
}
