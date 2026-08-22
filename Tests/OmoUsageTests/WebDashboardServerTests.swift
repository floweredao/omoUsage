import AppKit
import Foundation
import Testing
@testable import OmoUsage

@Suite
struct WebDashboardServerTests {
    private let refreshedAt = Date(
        timeIntervalSince1970: 1_786_867_200
    )

    @Test
    func snapshotEndpointReturnsSanitizedDashboardJSON() throws {
        let expected = dashboardSnapshot
        let data = try UsageSnapshotCodec.encode(expected)
        let router = WebDashboardRouter(
            snapshotData: { data },
            indexHTML: Data()
        )

        let response = router.response(
            method: "GET",
            path: "/api/snapshot"
        )

        #expect(response.statusCode == 200)
        #expect(
            response.headers["Content-Type"]
                == "application/json; charset=utf-8"
        )
        #expect(try UsageSnapshotCodec.decode(response.body) == expected)
        let body = String(decoding: response.body, as: UTF8.self)
        #expect(!body.localizedCaseInsensitiveContains("token"))
        #expect(!body.localizedCaseInsensitiveContains("cookie"))
        #expect(!body.localizedCaseInsensitiveContains("credential"))
        #expect(!body.contains("/Users/"))
    }

    @Test
    func settingsEndpointPublishesWebLanguageOnly() throws {
        let data = try UsageSnapshotCodec.encode(dashboardSnapshot)
        let settingsStore = WebDashboardSettingsStore(
            controlState: UsageDashboardControlState(
                providerOrder: ProviderID.allCases,
                disconnectedProviders: [.copilot],
                isRefreshing: false
            ),
            language: .korean
        )
        let router = WebDashboardRouter(
            snapshotData: { data },
            settingsData: settingsStore.encoded,
            indexHTML: Data()
        )

        let response = router.response(
            method: "GET",
            path: "/api/settings"
        )

        #expect(response.statusCode == 200)
        #expect(
            response.headers["Content-Type"]
                == "application/json; charset=utf-8"
        )
        let object = try #require(
            JSONSerialization.jsonObject(
                with: response.body
            ) as? [String: Any]
        )
        #expect(
            Set(object.keys) == [
                "providerOrder",
                "disconnectedProviders",
                "webLanguage",
                "isRefreshing",
                "refreshRevision"
            ]
        )
        #expect(
            object["providerOrder"] as? [String]
                == ProviderID.allCases.map(\.rawValue)
        )
        #expect(
            object["disconnectedProviders"] as? [String]
                == [ProviderID.copilot.rawValue]
        )
        #expect(object["webLanguage"] as? String == "korean")
        #expect(object["language"] == nil)
        #expect(object["isRefreshing"] as? Bool == false)
        #expect(object["refreshRevision"] as? Int == 0)
        let body = String(decoding: response.body, as: UTF8.self)
        #expect(!body.localizedCaseInsensitiveContains("token"))
        #expect(!body.localizedCaseInsensitiveContains("cookie"))
        #expect(!body.localizedCaseInsensitiveContains("credential"))
        #expect(!body.localizedCaseInsensitiveContains("apiKey"))
        #expect(!body.contains("/Users/"))
    }

    @Test
    func refreshRevisionAdvancesOnlyWhenRefreshCompletes() {
        let initial = UsageDashboardControlState(
            providerOrder: ProviderID.allCases,
            disconnectedProviders: [],
            isRefreshing: false
        )
        let store = WebDashboardSettingsStore(
            controlState: initial,
            language: .english
        )

        #expect(store.state().refreshRevision == 0)
        store.update(UsageDashboardControlState(
            providerOrder: ProviderID.allCases,
            disconnectedProviders: [],
            isRefreshing: true
        ))
        #expect(store.state().refreshRevision == 0)
        store.update(initial)
        #expect(store.state().refreshRevision == 1)
        store.update(initial)
        #expect(store.state().refreshRevision == 1)
    }

    @Test
    func settingsCommandsRequireNonceAndValidatePayload() {
        let recorder = WebDashboardCommandRecorder()
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            settingsData: { Data(#"{"isRefreshing":false}"#.utf8) },
            indexHTML: Data(),
            appIconSVG: Data(),
            mutationNonce: "correct-nonce",
            dispatchCommand: recorder.record
        )
        let payload = Data(
            """
            {
              "providerOrder": [
                "claude",
                "codex",
                "cursor",
                "antigravity",
                "copilot",
                "devin",
                "grok",
                "opencode",
                "openrouter",
                "zai"
              ]
            }
            """.utf8
        )

        let unauthorized = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: [
                    "content-type": "application/json",
                    "x-omo-csrf": "wrong-nonce"
                ],
                body: payload
            )
        )
        let authorized = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: [
                    "content-type": "application/json",
                    "x-omo-csrf": "correct-nonce"
                ],
                body: payload
            )
        )
        let webLanguage = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: [
                    "content-type": "application/json",
                    "x-omo-csrf": "correct-nonce"
                ],
                body: Data(#"{"webLanguage":"korean"}"#.utf8)
            )
        )
        let legacyAppLanguage = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: [
                    "content-type": "application/json",
                    "x-omo-csrf": "correct-nonce"
                ],
                body: Data(#"{"language":"korean"}"#.utf8)
            )
        )
        let unsupportedWebLanguage = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: [
                    "content-type": "application/json",
                    "x-omo-csrf": "correct-nonce"
                ],
                body: Data(#"{"webLanguage":"japanese"}"#.utf8)
            )
        )
        let unknownField = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: [
                    "content-type": "application/json",
                    "x-omo-csrf": "correct-nonce"
                ],
                body: Data(
                    #"{"webLanguage":"korean","extra":true}"#.utf8
                )
            )
        )

        #expect(unauthorized.statusCode == 403)
        #expect(authorized.statusCode == 202)
        #expect(webLanguage.statusCode == 202)
        #expect(legacyAppLanguage.statusCode == 400)
        #expect(unsupportedWebLanguage.statusCode == 400)
        #expect(unknownField.statusCode == 400)
        #expect(
            authorized.headers["Content-Type"]
                == "application/json; charset=utf-8"
        )
        #expect(recorder.commands.count == 2)
        #expect(
            String(describing: recorder.commands.last)
                .contains("setWebLanguage")
        )
    }

    @Test
    func refreshCommandDispatchesExactlyOnceWithValidNonce() {
        let recorder = WebDashboardCommandRecorder()
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            settingsData: { Data() },
            indexHTML: Data(),
            appIconSVG: Data(),
            mutationNonce: "correct-nonce",
            dispatchCommand: recorder.record
        )

        let response = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/refresh",
                headers: [
                    "x-omo-csrf": "correct-nonce"
                ],
                body: Data()
            )
        )

        #expect(response.statusCode == 202)
        #expect(recorder.commands == [.refresh])
    }

    @Test
    func webLanguageCommandsRequireNonceAndPersistSeparately()
        throws
    {
        let recorder = WebDashboardCommandRecorder()
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            settingsData: { Data() },
            indexHTML: Data(),
            appIconSVG: Data(),
            mutationNonce: "correct-nonce",
            dispatchCommand: recorder.record
        )
        let unauthorized = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: [
                    "content-type": "application/json"
                ],
                body: Data(
                    #"{"webLanguage":"korean"}"#.utf8
                )
            )
        )
        let authorized = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: [
                    "content-type": "application/json",
                    "x-omo-csrf": "correct-nonce"
                ],
                body: Data(
                    #"{"webLanguage":"korean"}"#.utf8
                )
            )
        )

        #expect(unauthorized.statusCode == 403)
        #expect(authorized.statusCode == 202)
        #expect(recorder.commands.count == 1)
        let dispatchedLanguage: AppLanguage? =
            switch recorder.commands.last {
            case .setWebLanguage(let language):
                language
            default:
                nil
            }
        let language = try #require(dispatchedLanguage)
        let suiteName =
            "WebLanguageCommand.persistence.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appStore = AppLanguageStore(defaults: defaults)
        appStore.save(.english)
        let webStore = WebDashboardLanguageStore(
            defaults: defaults,
            fallback: .english
        )
        webStore.save(language)

        #expect(webStore.load() == .korean)
        #expect(appStore.load() == .english)
    }

    @Test
    func rejectsUnauthorizedMalformedAndSecretSettingMutations() {
        let recorder = WebDashboardCommandRecorder()
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            settingsData: { Data() },
            indexHTML: Data(),
            appIconSVG: Data(),
            mutationNonce: "correct-nonce",
            dispatchCommand: recorder.record
        )
        let authorizedHeaders = [
            "content-type": "application/json",
            "x-omo-csrf": "correct-nonce"
        ]

        let unauthorized = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/refresh",
                headers: [:],
                body: Data()
            )
        )
        let malformed = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: authorizedHeaders,
                body: Data("{".utf8)
            )
        )
        let secret = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: authorizedHeaders,
                body: Data(#"{"apiKey":"secret"}"#.utf8)
            )
        )
        let invalidProvider = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: authorizedHeaders,
                body: Data(
                    #"{"provider":"unknown","visible":false}"#.utf8
                )
            )
        )
        let incompleteOrder = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: authorizedHeaders,
                body: Data(
                    #"{"providerOrder":["claude","codex"]}"#.utf8
                )
            )
        )

        #expect(unauthorized.statusCode == 403)
        #expect(malformed.statusCode == 400)
        #expect(secret.statusCode == 400)
        #expect(invalidProvider.statusCode == 400)
        #expect(incompleteOrder.statusCode == 400)
        #expect(recorder.commands.isEmpty)
    }

    @Test
    func rejectsOversizedSerializedRequests() {
        let body = Data(repeating: 0x61, count: 16 * 1_024)
        var request = Data(
            """
            POST /api/settings HTTP/1.1\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            \r
            """.utf8
        )
        request.append(body)

        #expect(WebDashboardHTTPRequest.parse(request) == nil)
    }

    @Test
    func rejectsOverflowingContentLength() {
        let request = Data(
            (
                "POST /api/settings HTTP/1.1\r\n"
                    + "Content-Type: application/json\r\n"
                    + "Content-Length: \(Int.max)\r\n"
                    + "\r\n"
            ).utf8
        )

        #expect(WebDashboardHTTPRequest.parse(request) == nil)
        #expect(
            WebDashboardHTTPRequest.expectedLength(request)
                == WebDashboardHTTPRequest.maximumBytes + 1
        )
    }

    @Test
    func appIconRouteServesBundledIconBytes() throws {
        let iconURL = try #require(
            Bundle.module.url(
                forResource: "AppIcon",
                withExtension: "svg"
            )
        )
        let expectedIcon = try Data(contentsOf: iconURL)
        let html = WebDashboardAssets.indexHTML(
            mutationNonce: "test-nonce"
        )
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            settingsData: { Data() },
            indexHTML: html,
            appIconSVG: expectedIcon,
            mutationNonce: "test-nonce",
            dispatchCommand: { _ in }
        )

        let indexResponse = router.response(
            method: "GET",
            path: "/"
        )
        let settingsResponse = router.response(
            method: "GET",
            path: "/settings"
        )
        let iconResponse = router.response(
            method: "GET",
            path: "/favicon.svg"
        )

        #expect(settingsResponse.statusCode == 200)
        #expect(settingsResponse.body == indexResponse.body)
        let page = String(
            decoding: settingsResponse.body,
            as: UTF8.self
        )
        #expect(
            page.contains(
                #"rel="icon" type="image/svg+xml" href="/favicon.svg""#
            )
        )
        #expect(
            page.contains(
                #"name="omo-csrf" content="test-nonce""#
            )
        )
        #expect(!page.contains("__OMO_CSRF_TOKEN__"))
        #expect(iconResponse.statusCode == 200)
        #expect(
            iconResponse.headers["Content-Type"]
                == "image/svg+xml; charset=utf-8"
        )
        #expect(
            iconResponse.headers["Cache-Control"]
                == "public, max-age=86400"
        )
        #expect(iconResponse.body == expectedIcon)
    }

    @Test
    func appleTouchIconRouteServesRenderedLocalAppIconAndPagesReferenceIt()
        throws
    {
        let iconURL = try #require(
            Bundle.module.url(
                forResource: "AppIcon",
                withExtension: "svg"
            )
        )
        let expectedIcon = try Data(contentsOf: iconURL)
        let html = WebDashboardAssets.indexHTML(
            mutationNonce: "test-nonce"
        )
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            settingsData: { Data() },
            indexHTML: html,
            appIconSVG: expectedIcon,
            mutationNonce: "test-nonce",
            dispatchCommand: { _ in }
        )

        let indexResponse = router.response(
            method: "GET",
            path: "/"
        )
        let settingsResponse = router.response(
            method: "GET",
            path: "/settings"
        )
        let touchIconResponse = router.response(
            method: "GET",
            path: "/apple-touch-icon.png"
        )

        #expect(indexResponse.body == settingsResponse.body)
        let page = String(
            decoding: indexResponse.body,
            as: UTF8.self
        )
        #expect(
            page.contains(
                """
                rel="apple-touch-icon" sizes="180x180" \
                href="/apple-touch-icon.png"
                """
            )
        )
        #expect(touchIconResponse.statusCode == 200)
        #expect(
            touchIconResponse.headers["Content-Type"] == "image/png"
        )
        #expect(
            touchIconResponse.headers["Cache-Control"]
                == "public, max-age=86400"
        )
        let bitmap = try #require(
            NSBitmapImageRep(data: touchIconResponse.body)
        )
        #expect(bitmap.pixelsWide == 180)
        #expect(bitmap.pixelsHigh == 180)
        let background = try #require(
            bitmap.colorAt(x: 36, y: 36)?.usingColorSpace(.sRGB)
        )
        #expect(background.brightnessComponent > 0.85)
        #expect(background.redComponent > background.blueComponent)
        let orangeRing = try #require(
            bitmap.colorAt(x: 37, y: 90)?.usingColorSpace(.sRGB)
        )
        #expect(orangeRing.redComponent > 0.85)
        #expect(orangeRing.greenComponent > 0.30)
        #expect(orangeRing.greenComponent < 0.65)
        #expect(orangeRing.blueComponent < 0.45)
    }

    @Test
    func rejectsUnsupportedMethodsAndTraversal() throws {
        let data = try UsageSnapshotCodec.encode(dashboardSnapshot)
        let router = WebDashboardRouter(
            snapshotData: { data },
            indexHTML: Data("index".utf8)
        )

        let postResponse = router.response(
            method: "POST",
            path: "/api/snapshot"
        )
        let traversalResponse = router.response(
            method: "GET",
            path: "/../Package.swift"
        )
        let encodedTraversalResponse = router.response(
            method: "GET",
            path: "/%2e%2e/Package.swift"
        )

        #expect(postResponse.statusCode == 405)
        #expect(postResponse.headers["Allow"] == "GET")
        #expect(traversalResponse.statusCode == 404)
        #expect(encodedTraversalResponse.statusCode == 404)
        #expect(
            !String(
                decoding: traversalResponse.body,
                as: UTF8.self
            ).contains("swift-tools-version")
        )
    }

    @Test
    func releasesPortAfterStop() throws {
        let listener = RecordingWebDashboardListener()
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            indexHTML: Data()
        )
        let server = WebDashboardServer(
            listener: listener,
            router: router
        )

        try server.start()
        listener.ready()
        #expect(listener.didStart)
        #expect(server.isRunning)

        server.stop()

        #expect(listener.didStop)
        #expect(!server.isRunning)
    }

    @Test
    func clearsRunningStateAfterListenerFailure() throws {
        let listener = RecordingWebDashboardListener()
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            indexHTML: Data()
        )
        let server = WebDashboardServer(
            listener: listener,
            router: router
        )

        try server.start()
        listener.ready()
        listener.fail()

        #expect(!server.isRunning)
        try server.start()
        #expect(listener.startCount == 2)
    }

    @Test
    func indexRouteServesMobileDashboard() {
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            indexHTML: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            )
        )

        let response = router.response(
            method: "GET",
            path: "/"
        )
        let html = String(decoding: response.body, as: UTF8.self)

        #expect(response.statusCode == 200)
        #expect(
            response.headers["Content-Type"]
                == "text/html; charset=utf-8"
        )
        #expect(html.contains(#"data-omo-dashboard="v1""#))
        #expect(html.contains(#"name="viewport""#))
        #expect(html.contains(#"fetch("/api/snapshot""#))
        #expect(!html.contains("https://"))
        #expect(!html.contains("http://"))
    }

    @Test
    func settingsAccentTextUsesSchemeSpecificAccessibleTokens() {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )

        #expect(html.contains("--standard-text: #3f7568;"))
        #expect(html.contains("--extra-text: #955f2d;"))
        #expect(html.contains("--standard-text: #79b5a5;"))
        #expect(html.contains("--extra-text: #e0a064;"))
        #expect(
            html.contains(
                ".visibility-button {\n      color: var(--standard-text);"
            )
        )
        #expect(
            html.contains(
                ".settings-error {\n      color: var(--extra-text);"
            )
        )
    }

    @Test
    func focusIndicatorMeetsContrastInBothSchemes() throws {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )
        let tokenPattern = try NSRegularExpression(
            pattern: #"--focus:\s*(#[0-9a-fA-F]{6});"#
        )
        let range = NSRange(
            html.startIndex..<html.endIndex,
            in: html
        )
        let focusTokens = tokenPattern.matches(
            in: html,
            range: range
        ).compactMap { match -> String? in
            guard
                let tokenRange = Range(
                    match.range(at: 1),
                    in: html
                )
            else {
                return nil
            }
            return String(html[tokenRange])
        }

        #expect(focusTokens.count == 2)
        let lightFocus = try #require(focusTokens.first)
        let darkFocus = try #require(focusTokens.last)
        #expect(
            try contrastRatio(lightFocus, "#ffffff") >= 3
        )
        #expect(
            try contrastRatio(lightFocus, "#f4f4f0") >= 3
        )
        #expect(
            try contrastRatio(darkFocus, "#20231f") >= 3
        )
        #expect(
            try contrastRatio(darkFocus, "#111310") >= 3
        )
        #expect(
            html.contains("outline: 3px solid var(--focus);")
        )
    }

    @Test
    func settingsMutationsScopeBusyStateToAffectedControl() {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )

        #expect(
            html.contains(
                "const settingsMutationsInFlight = new Map();"
            )
        )
        #expect(html.contains("function presentationSettingsState()"))
        #expect(
            html.contains(
                "settingsMutationsInFlight.has(mutationKey)"
            )
        )
        #expect(
            html.contains(
                "settingsMutationsInFlight.set(mutationKey, expected);"
            )
        )
        #expect(
            html.contains(
                #"button.setAttribute("aria-busy", "true");"#
            )
        )
        #expect(!html.contains("disabled || settingsMutationInFlight"))
        #expect(
            !html.contains(
                "webLanguageSelect.disabled = settingsMutation"
            )
        )
    }

    private var dashboardSnapshot: DashboardSnapshot {
        DashboardSnapshot(
            providers: [
                ProviderUsage(
                    provider: .codex,
                    planName: "Plus",
                    groups: [
                        UsageGroup(
                            id: "limits",
                            title: nil,
                            meters: [
                                UsageMeter(
                                    id: "session",
                                    title: "Session",
                                    period: .session,
                                    percentRemaining: 72,
                                    resetsAt: refreshedAt.addingTimeInterval(
                                        3_600
                                    ),
                                    resetText: "Resets in 1 hour"
                                )
                            ],
                            creditText: nil
                        )
                    ],
                    availability: .available,
                    updatedAt: refreshedAt
                )
            ],
            refreshedAt: refreshedAt
        )
    }
}

@Suite
struct WebDashboardLanguageStoreTests {
    @Test
    func webLanguagePersistsWithoutChangingAppLanguage() {
        let suiteName =
            "WebDashboardLanguageStoreTests.persistence.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(["en-US"], forKey: "AppleLanguages")
        let appStore = AppLanguageStore(defaults: defaults)
        appStore.save(.english)
        let webStore = WebDashboardLanguageStore(
            defaults: defaults,
            fallback: .english
        )

        #expect(webStore.load() == .english)
        webStore.save(.korean)

        #expect(webStore.load() == .korean)
        #expect(appStore.load() == .english)
        #expect(
            defaults.string(forKey: AppLanguageStore.key) == "english"
        )
        #expect(
            defaults.string(forKey: WebDashboardLanguageStore.key)
                == "korean"
        )
    }
}

private func contrastRatio(
    _ foreground: String,
    _ background: String
) throws -> Double {
    let foregroundLuminance = try relativeLuminance(foreground)
    let backgroundLuminance = try relativeLuminance(background)
    let lighter = max(foregroundLuminance, backgroundLuminance)
    let darker = min(foregroundLuminance, backgroundLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(_ hex: String) throws -> Double {
    let value = try #require(
        UInt64(hex.dropFirst(), radix: 16)
    )
    let red = Double((value >> 16) & 0xff) / 255
    let green = Double((value >> 8) & 0xff) / 255
    let blue = Double(value & 0xff) / 255
    let components = [red, green, blue].map { component in
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
    return
        (0.2126 * components[0])
        + (0.7152 * components[1])
        + (0.0722 * components[2])
}

private final class RecordingWebDashboardListener:
    WebDashboardListening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var starts = 0
    private var stopped = false
    private var stateChanged:
        (@Sendable (WebDashboardListenerState) -> Void)?

    var didStart: Bool {
        lock.withLock { starts > 0 }
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    var didStop: Bool {
        lock.withLock { stopped }
    }

    func start(
        response: @escaping @Sendable (Data) -> Data,
        stateChanged: @escaping @Sendable (
            WebDashboardListenerState
        ) -> Void
    ) throws {
        lock.withLock {
            starts += 1
            self.stateChanged = stateChanged
        }
    }

    func ready() {
        lock.withLock { stateChanged }?(.ready)
    }

    func fail() {
        lock.withLock { stateChanged }?(.failed)
    }

    func stop() {
        lock.withLock {
            stopped = true
        }
    }
}

private final class WebDashboardCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [WebDashboardCommand] = []

    var commands: [WebDashboardCommand] {
        lock.withLock { values }
    }

    func record(_ command: WebDashboardCommand) {
        lock.withLock {
            values.append(command)
        }
    }
}
