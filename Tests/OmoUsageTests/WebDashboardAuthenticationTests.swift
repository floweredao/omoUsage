import Foundation
import Testing
@testable import OmoUsage

@Suite
struct WebDashboardAuthenticationTests {
    private let localHost = "127.0.0.1:7827"
    private let localOrigin = "http://127.0.0.1:7827"

    @Test
    func unauthenticatedReadsAndMutationsAreRejected() {
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

        #expect(read.statusCode == 401)
        #expect(mutation.statusCode == 401)
    }

    @Test
    func malformedAndForeignHostsAreRejectedBeforeAuthentication() {
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
    func bootstrapIsOneUseAndCreatesStrictHTTPOnlySessionCookie() throws {
        let store = makeStore()
        let gateway = makeGateway(store: store)
        let bootstrapURL = try store.makeBootstrapURL()
        let token = try #require(
            URLComponents(url: bootstrapURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "token" }?.value
        )
        let bootstrap = request(
            method: "GET",
            path: "/bootstrap",
            query: "token=\(token)"
        )

        let first = gateway.response(request: bootstrap)
        let replay = gateway.response(request: bootstrap)
        let cookie = try #require(first.headers["Set-Cookie"])

        #expect(first.statusCode == 303)
        #expect(first.headers["Location"] == "/")
        #expect(cookie.contains("HttpOnly"))
        #expect(cookie.contains("SameSite=Strict"))
        #expect(cookie.contains("Path=/"))
        #expect(!cookie.contains(token))
        #expect(replay.statusCode == 401)
    }

    @Test
    func fixtureBootstrapExportIsExplicitPrivateAndNeverProduction() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "WebBootstrapExport-\(UUID().uuidString)"
        )
        let fixtureURL = directory.appending(path: "bootstrap-url.txt")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = makeStore()

        try FixtureWebBootstrapExporter.exportIfRequested(
            accessStore: store,
            environment: [
                "OMO_USAGE_FIXTURE_MODE": "1",
                "OMO_USAGE_BOOTSTRAP_URL_FILE": fixtureURL.path
            ]
        )

        let value = try String(contentsOf: fixtureURL, encoding: .utf8)
        let permissions = try #require(
            try FileManager.default.attributesOfItem(
                atPath: fixtureURL.path
            )[.posixPermissions] as? NSNumber
        )
        #expect(value.hasPrefix("http://127.0.0.1:7827/bootstrap?token=b_"))
        #expect(permissions.intValue == 0o600)

        try FileManager.default.removeItem(at: fixtureURL)
        try FixtureWebBootstrapExporter.exportIfRequested(
            accessStore: store,
            environment: [
                "OMO_USAGE_BOOTSTRAP_URL_FILE": fixtureURL.path
            ]
        )
        #expect(!FileManager.default.fileExists(atPath: fixtureURL.path))
    }

    @Test
    func validSessionAuthenticatesHTMLAndAPIReads() throws {
        let authenticated = try authenticatedGateway()

        let html = authenticated.gateway.response(
            request: request(
                method: "GET",
                path: "/",
                headers: ["cookie": authenticated.cookie]
            )
        )
        let api = authenticated.gateway.response(
            request: request(
                method: "GET",
                path: "/api/snapshot",
                headers: ["cookie": authenticated.cookie]
            )
        )

        #expect(html.statusCode == 200)
        #expect(api.statusCode == 200)
    }

    @Test
    func authenticatedMutationsRequireExactOriginAndCSRF() throws {
        let authenticated = try authenticatedGateway()
        let cookieHeader = ["cookie": authenticated.cookie]

        let missingOrigin = authenticated.gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh",
                headers: cookieHeader
            )
        )
        let foreignOrigin = authenticated.gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh",
                headers: cookieHeader.merging(
                    ["origin": "https://evil.example"],
                    uniquingKeysWith: { _, new in new }
                )
            )
        )
        let missingCSRF = authenticated.gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh",
                headers: cookieHeader.merging(
                    ["origin": localOrigin],
                    uniquingKeysWith: { _, new in new }
                )
            )
        )
        let accepted = authenticated.gateway.response(
            request: request(
                method: "POST",
                path: "/api/refresh",
                headers: cookieHeader.merging(
                    [
                        "origin": localOrigin,
                        "x-omo-csrf": "fixture-csrf"
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
        )

        #expect(missingOrigin.statusCode == 403)
        #expect(foreignOrigin.statusCode == 403)
        #expect(missingCSRF.statusCode == 403)
        #expect(accepted.statusCode == 202)
    }

    @Test
    func localIsDefaultAndRemoteModeRequiresExactTailscaleHost() throws {
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
                host: "fixture-device.fixture-tailnet.ts.net"
            )
        )
        #expect(invalidRemote == .local(port: 7_827))
        #expect(
            remote.accepts(
                host: "fixture-device.fixture-tailnet.ts.net"
            )
        )
        #expect(!remote.accepts(host: "other.fixture-tailnet.ts.net"))

        let remoteStore = WebDashboardAccessStore(
            mode: remote,
            tokenGenerator: { "fixture-secret" }
        )
        let remoteURL = try remoteStore.makeBootstrapURL()
        #expect(
            remoteURL.absoluteString.hasPrefix(
                "https://fixture-device.fixture-tailnet.ts.net/bootstrap?"
            )
        )
        let token = try #require(
            URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first?.value
        )
        let remoteGateway = makeGateway(store: remoteStore)
        let bootstrap = remoteGateway.response(
            request: WebDashboardHTTPRequest(
                method: "GET",
                path: "/bootstrap",
                query: "token=\(token)",
                headers: [
                    "host": "fixture-device.fixture-tailnet.ts.net"
                ]
            )
        )
        #expect(bootstrap.headers["Set-Cookie"]?.contains("; Secure") == true)
    }

    private func makeStore() -> WebDashboardAccessStore {
        WebDashboardAccessStore(
            mode: .local(port: 7_827),
            tokenGenerator: { "fixture-secret" }
        )
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

    private func authenticatedGateway() throws -> (
        gateway: WebDashboardAccessGateway,
        cookie: String
    ) {
        let store = makeStore()
        let gateway = makeGateway(store: store)
        let bootstrapURL = try store.makeBootstrapURL()
        let token = try #require(
            URLComponents(url: bootstrapURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "token" }?.value
        )
        let response = gateway.response(
            request: request(
                method: "GET",
                path: "/bootstrap",
                query: "token=\(token)"
            )
        )
        let setCookie = try #require(response.headers["Set-Cookie"])
        let cookie = try #require(setCookie.split(separator: ";").first)
        return (gateway, String(cookie))
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
