import AppKit
import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

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
                "accountProviderOrder",
                "accountProviderLabels",
                "disconnectedAccountProviders",
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
    @MainActor
    func settingsEndpointPublishesTwoSameProviderAccountIdentities() throws {
        // Given
        let accountA = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000a"
        )!
        let accountB = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000b"
        )!
        var published: [UsageDashboardControlState] = []
        _ = UsageDashboardViewModel(
            providers: [
                FixtureUsageProvider(
                    id: .openrouter,
                    accountID: accountA,
                    accountLabel: "Team A"
                ),
                FixtureUsageProvider(
                    id: .openrouter,
                    accountID: accountB,
                    accountLabel: "Team B"
                )
            ],
            publishControlState: { published.append($0) }
        )
        let controlState = try #require(published.last)
        let store = WebDashboardSettingsStore(
            controlState: controlState,
            language: .english
        )

        // When
        let object = try #require(
            JSONSerialization.jsonObject(with: store.encoded())
                as? [String: Any]
        )

        // Then
        let accountOrder = try #require(
            object["accountProviderOrder"] as? [[String: String]]
        )
        #expect(accountOrder == [
            ["accountID": accountA.rawValue, "providerID": "openrouter"],
            ["accountID": accountB.rawValue, "providerID": "openrouter"]
        ])
        #expect(
            object["disconnectedAccountProviders"] as? [[String: String]]
                == []
        )
    }

    @Test
    func settingsEndpointKeepsLabelsForHiddenAccounts() throws {
        let accountA = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000a"
        )!
        let accountB = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000b"
        )!
        let identityA = AccountProviderID(
            accountID: accountA,
            providerID: .openrouter
        )
        let identityB = AccountProviderID(
            accountID: accountB,
            providerID: .openrouter
        )
        let store = WebDashboardSettingsStore(
            controlState: UsageDashboardControlState(
                providerOrder: [.openrouter],
                disconnectedProviders: [.openrouter],
                accountProviderOrder: [identityA, identityB],
                accountProviderLabels: [
                    identityA: "QA Team",
                    identityB: "QA Personal"
                ],
                disconnectedAccountProviders: [identityA, identityB],
                isRefreshing: false
            ),
            language: .english
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: store.encoded())
                as? [String: Any]
        )

        #expect(
            object["accountProviderLabels"] as? [String]
                == ["QA Team", "QA Personal"]
        )
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
                "kiro",
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
    func accountCommandsRequireNonceAndValidateConfiguredRoster() throws {
        // Given
        let accountA = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000a"
        )!
        let accountB = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000b"
        )!
        let accountAJSON = accountIdentityJSON(accountA)
        let accountBJSON = accountIdentityJSON(accountB)
        let recorder = WebDashboardCommandRecorder()
        let settings = Data(
            """
            {
              "providerOrder": ["openrouter"],
              "disconnectedProviders": [],
              "accountProviderOrder": [\(accountAJSON), \(accountBJSON)],
              "accountProviderLabels": ["QA Team", "QA Personal"],
              "disconnectedAccountProviders": [],
              "webLanguage": "english",
              "isRefreshing": false,
              "refreshRevision": 0
            }
            """.utf8
        )
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            settingsData: { settings },
            indexHTML: Data(),
            appIconSVG: Data(),
            mutationNonce: "correct-nonce",
            dispatchCommand: recorder.record
        )
        let headers = [
            "content-type": "application/json",
            "x-omo-csrf": "correct-nonce"
        ]

        // When
        let orderResponse = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: headers,
                body: Data(
                    "{\"accountProviderOrder\":[\(accountBJSON),\(accountAJSON)]}"
                        .utf8
                )
            )
        )
        let visibilityResponse = router.response(
            request: WebDashboardHTTPRequest(
                method: "POST",
                path: "/api/settings",
                headers: headers,
                body: Data(
                    "{\"accountProvider\":\(accountAJSON),\"visible\":false}"
                        .utf8
                )
            )
        )

        // Then
        #expect(orderResponse.statusCode == 202)
        #expect(visibilityResponse.statusCode == 202)
        let commands = try #require(
            recorder.commands.count == 2 ? recorder.commands : nil
        )
        #expect(commands == [
            .setAccountProviderOrder([
                AccountProviderID(accountID: accountB, providerID: .openrouter),
                AccountProviderID(accountID: accountA, providerID: .openrouter)
            ]),
            .setAccountVisibility(
                accountProvider: AccountProviderID(
                    accountID: accountA,
                    providerID: .openrouter
                ),
                isVisible: false
            )
        ])
    }

    @Test
    func rejectsDuplicateMalformedAndUnknownAccountCommands() {
        // Given
        let accountA = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000a"
        )!
        let accountB = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000b"
        )!
        let accountAJSON = accountIdentityJSON(accountA)
        let accountBJSON = accountIdentityJSON(accountB)
        let recorder = WebDashboardCommandRecorder()
        let settings = Data(
            """
            {
              "providerOrder": ["openrouter"],
              "disconnectedProviders": [],
              "accountProviderOrder": [\(accountAJSON), \(accountBJSON)],
              "disconnectedAccountProviders": [],
              "webLanguage": "english",
              "isRefreshing": false,
              "refreshRevision": 0
            }
            """.utf8
        )
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            settingsData: { settings },
            indexHTML: Data(),
            appIconSVG: Data(),
            mutationNonce: "correct-nonce",
            dispatchCommand: recorder.record
        )
        let headers = [
            "content-type": "application/json",
            "x-omo-csrf": "correct-nonce"
        ]
        let payloads = [
            "{\"accountProviderOrder\":[\(accountAJSON),\(accountAJSON)]}",
            "{\"accountProviderOrder\":[{\"accountID\":\"bad\",\"providerID\":\"openrouter\"},\(accountBJSON)]}",
            "{\"accountProviderOrder\":[{\"accountID\":\"00000000-0000-0000-0000-00000000000a\",\"providerID\":\"unknown\"},\(accountBJSON)]}",
            "{\"accountProvider\":{\"accountID\":\"00000000-0000-0000-0000-00000000000c\",\"providerID\":\"openrouter\"},\"visible\":false}",
            "{\"accountProvider\":\(accountAJSON),\"visible\":1}"
        ]

        // When
        let responses = payloads.map { payload in
            router.response(
                request: WebDashboardHTTPRequest(
                    method: "POST",
                    path: "/api/settings",
                    headers: headers,
                    body: Data(payload.utf8)
                )
            )
        }

        // Then
        #expect(responses.allSatisfy { $0.statusCode == 400 })
        #expect(recorder.commands.isEmpty)
    }

    @Test
    func snapshotEndpointUsesGenericSameProviderAccountRows() throws {
        // Given
        let accountA = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000a"
        )!
        let accountB = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000b"
        )!
        let snapshot = DashboardSnapshot(
            providers: [
                ProviderUsage(
                    provider: .openrouter,
                    accountID: accountA,
                    accountLabel: "Team A",
                    planName: "Pro",
                    groups: [],
                    availability: .available,
                    updatedAt: refreshedAt
                ),
                ProviderUsage(
                    provider: .openrouter,
                    accountID: accountB,
                    accountLabel: "person@example.com",
                    planName: "Pro",
                    groups: [],
                    availability: .available,
                    updatedAt: refreshedAt
                )
            ],
            refreshedAt: refreshedAt
        )
        let data = try UsageSnapshotCodec.encode(snapshot)
        let router = WebDashboardRouter(
            snapshotData: { data },
            indexHTML: Data()
        )

        // When
        let response = router.response(method: "GET", path: "/api/snapshot")
        let decoded = try UsageSnapshotCodec.decode(response.body)

        // Then
        #expect(Set(decoded.providers.map(\.accountProviderID)).count == 2)
        #expect(decoded.providers.allSatisfy { $0.provider == .openrouter })
        #expect(decoded.providers.map(\.accountLabel) == [
            "Account 1",
            "Account 2"
        ])
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
    func installMetadataSupportsIOSHomeScreen() throws {
        // Given
        let html = WebDashboardAssets.indexHTML(mutationNonce: "test-nonce")
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            indexHTML: html
        )

        // When
        let page = String(
            decoding: router.response(method: "GET", path: "/").body,
            as: UTF8.self
        )
        let icon = router.response(
            method: "GET",
            path: "/apple-touch-icon.png"
        )

        // Then
        #expect(
            page.contains(
                #"rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png""#
            )
        )
        #expect(icon.statusCode == 200)
        #expect(icon.headers["Content-Type"] == "image/png")
        #expect(
            Array(icon.body.prefix(8))
                == [137, 80, 78, 71, 13, 10, 26, 10]
        )
        #expect(icon.body.count > 100)
        #expect(icon.body.count > Set(icon.body).count)
        #expect(icon.body.count >= 24)
        let width = icon.body[16..<20].reduce(0) { ($0 << 8) | UInt32($1) }
        let height = icon.body[20..<24].reduce(0) { ($0 << 8) | UInt32($1) }
        #expect(width == 180)
        #expect(height == 180)
        let bitmap = try #require(NSBitmapImageRep(data: icon.body))
        #expect(bitmap.pixelsWide == 180)
        #expect(bitmap.pixelsHigh == 180)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 1)
        #expect(bitmap.colorAt(x: 90, y: 90)?.alphaComponent == 1)
    }

    @Test
    func installMetadataSupportsAndroidHomeScreen() throws {
        // Given
        let html = WebDashboardAssets.indexHTML(mutationNonce: "test-nonce")
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            indexHTML: html
        )

        // When
        let page = String(
            decoding: router.response(method: "GET", path: "/").body,
            as: UTF8.self
        )
        let manifest = router.response(
            method: "GET",
            path: "/manifest.webmanifest"
        )

        // Then
        #expect(
            page.contains(
                #"rel="manifest" href="/manifest.webmanifest""#
            )
        )
        #expect(manifest.statusCode == 200)
        #expect(
            manifest.headers["Content-Type"]
                == "application/manifest+json"
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: manifest.body)
                as? [String: Any]
        )
        #expect(object["name"] as? String == "OmoUsage")
        #expect(object["short_name"] as? String == "OmoUsage")
        #expect(object["start_url"] as? String == "/")
        #expect(object["display"] as? String == "standalone")
        let icons = try #require(object["icons"] as? [[String: Any]])
        #expect(
            icons.contains {
                ($0["sizes"] as? String) == "192x192"
                    && ($0["purpose"] as? String)?.contains("maskable") == true
            }
        )
        #expect(
            icons.contains {
                ($0["sizes"] as? String) == "512x512"
                    && ($0["purpose"] as? String)?.contains("maskable") == true
            }
        )
        for icon in icons {
            let path = try #require(icon["src"] as? String)
            let size = try #require(icon["sizes"] as? String)
            let response = router.response(method: "GET", path: path)
            #expect(response.statusCode == 200)
            #expect(response.headers["Content-Type"] == "image/png")
            #expect(
                Array(response.body.prefix(8))
                    == [137, 80, 78, 71, 13, 10, 26, 10]
            )
            let widthString = try #require(
                size.split(separator: "x").first.map(String.init)
            )
            let expected = try #require(UInt32(widthString))
            #expect(
                response.body[16..<20]
                    .reduce(0) { ($0 << 8) | UInt32($1) }
                    == expected
            )
            #expect(
                response.body[20..<24]
                    .reduce(0) { ($0 << 8) | UInt32($1) }
                    == expected
            )
            let bitmap = try #require(NSBitmapImageRep(data: response.body))
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 1)
        }
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
    func providerIconRouteServesBundledArtworkOnly() throws {
        let iconURL = try #require(
            Bundle.module.url(
                forResource: "claude",
                withExtension: "svg"
            )
        )
        let expectedIcon = try Data(contentsOf: iconURL)
        let html = WebDashboardAssets.indexHTML(
            mutationNonce: "test-nonce"
        )
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            indexHTML: html,
            providerIconSVGs: [.claude: expectedIcon]
        )

        let iconResponse = router.response(
            method: "GET",
            path: "/provider-icons/claude.svg"
        )
        let missingResponse = router.response(
            method: "GET",
            path: "/provider-icons/cursor.svg"
        )
        let traversalResponse = router.response(
            method: "GET",
            path: "/provider-icons/../claude.svg"
        )
        let wrongMethod = router.response(
            method: "POST",
            path: "/provider-icons/claude.svg"
        )
        let page = String(decoding: html, as: UTF8.self)

        #expect(iconResponse.statusCode == 200)
        #expect(
            iconResponse.headers["Content-Type"]
                == "image/svg+xml; charset=utf-8"
        )
        #expect(iconResponse.body == expectedIcon)
        #expect(missingResponse.statusCode == 404)
        #expect(traversalResponse.statusCode == 404)
        #expect(wrongMethod.statusCode == 405)
        #expect(wrongMethod.headers["Allow"] == "GET")
        #expect(
            page.contains(
                "const artworkProviders = new Set("
            )
        )
        #expect(
            page.contains(
                "image.src = `/provider-icons/${providerID}.svg`;"
            )
        )
        #expect(
            page.contains(
                "icon.dataset.provider = providerID;"
            )
        )
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
    @MainActor
    func releasesPortAfterStop() throws {
        let listener = RecordingWebDashboardListener()
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            indexHTML: Data()
        )
        let server = WebDashboardServer(
            listener: listener,
            router: router,
            accessStore: WebDashboardAccessStore(
                mode: .local(port: 7_827)
            ),
            statusStore: WebDashboardStatusStore(port: 7_827)
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
    func fixtureWebPortOverrideCannotAffectProduction() {
        #expect(
            WebDashboardPortPolicy.resolve(environment: [
                "OMO_USAGE_WEB_PORT": "7828"
            ]) == 7_827
        )
        #expect(
            WebDashboardPortPolicy.resolve(environment: [
                "OMO_USAGE_FIXTURE_MODE": "1",
                "OMO_USAGE_WEB_PORT": "7828"
            ]) == 7_828
        )
        #expect(
            WebDashboardPortPolicy.resolve(environment: [
                "OMO_USAGE_FIXTURE_MODE": "1",
                "OMO_USAGE_WEB_PORT": "0"
            ]) == 7_827
        )
        #expect(
            WebDashboardPortPolicy.resolve(environment: [
                "OMO_USAGE_FIXTURE_MODE": "1",
                "OMO_USAGE_WEB_PORT": "invalid"
            ]) == 7_827
        )
    }

    @Test
    @MainActor
    func clearsRunningStateAfterListenerFailure() throws {
        let listener = RecordingWebDashboardListener()
        let router = WebDashboardRouter(
            snapshotData: { Data() },
            indexHTML: Data()
        )
        let server = WebDashboardServer(
            listener: listener,
            router: router,
            accessStore: WebDashboardAccessStore(
                mode: .local(port: 7_827)
            ),
            statusStore: WebDashboardStatusStore(port: 7_827)
        )

        try server.start()
        listener.ready()
        listener.fail()

        #expect(!server.isRunning)
        try server.start()
        #expect(listener.startCount == 2)
    }

    @Test
    func atomicallyGatesAndFinishesTrackedConnections() {
        let pool = WebDashboardConnectionPool(maximumCount: 2)
        let beforeStart = RecordingWebDashboardConnection()
        let first = RecordingWebDashboardConnection()
        let second = RecordingWebDashboardConnection()
        let rejected = RecordingWebDashboardConnection()
        let afterStop = RecordingWebDashboardConnection()

        #expect(!pool.accept(beforeStart))
        #expect(beforeStart.finishCount == 1)
        pool.startAccepting()
        #expect(pool.accept(first))
        #expect(pool.accept(second))
        #expect(!pool.accept(rejected))
        #expect(pool.count == 2)
        #expect(rejected.finishCount == 1)

        pool.remove(first)
        first.finish()
        pool.stopAcceptingAndFinishAll()

        #expect(first.finishCount == 1)
        #expect(second.finishCount == 1)
        #expect(pool.count == 0)
        #expect(!pool.accept(afterStop))
        #expect(afterStop.finishCount == 1)
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
        #expect(
            html.contains(
                "accountLabelsByKey.get(identityKey)"
            )
        )
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
    func settingsDescriptionsKeepKoreanPhrasesTogether() {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )

        #expect(
            html.contains(
                """
                .settings-description,
                    .settings-sync {
                      color: var(--muted);
                      font-size: 13px;
                      line-height: 1.5;
                      text-wrap: balance;
                      word-break: keep-all;
                      overflow-wrap: anywhere;
                    }
                """
            )
        )
    }

    @Test
    func optimisticAccountReorderKeepsAliasesBoundToIdentity() {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )

        #expect(
            html.contains("const accountLabelsByKey = new Map(")
        )
        #expect(html.contains("accountLabelsByKey.get(identityKey)"))
        #expect(
            !html.contains("presentation.accountProviderLabels[index]")
        )
    }

    @Test
    func snapshotPollingDoesNotReplayCardRevealAnimation() {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )

        #expect(
            html.contains(
                #".cards[data-reveal="true"] .provider-card"#
            )
        )
        #expect(html.contains("let hasRevealedProviderCards = false;"))
        #expect(html.contains("delete cards.dataset.reveal;"))
        #expect(
            !html.contains(
                "\n      .provider-card {\n        animation: reveal"
            )
        )
    }

    @Test
    func legacyDashboardAccountDoesNotRenderDefaultAlias() {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )

        #expect(
            html.contains(
                "providerIdentity(provider).accountID !== legacyAccountID"
            )
        )
        #expect(
            !html.contains(
                "return provider.accountID !== legacyAccountID"
            )
        )
    }

    @Test
    func webClientHasOneInitialSnapshotRefreshOwner() {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )

        #expect(
            !html.contains(
                "\n    refresh();\n    setInterval(refresh, 30_000);"
            )
        )
        #expect(
            html.contains(
                "syncSettings().catch(() => {}).finally(refresh);"
            )
        )
    }

    @Test
    func settingsFailureHidesStaleSynchronizationSuccess() throws {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )
        let failurePattern = try NSRegularExpression(
            pattern:
                #"settingsSync\.hidden = true;\s*settingsError\.hidden = false;"#
        )

        #expect(
            failurePattern.numberOfMatches(
                in: html,
                range: NSRange(
                    html.startIndex..<html.endIndex,
                    in: html
                )
            ) == 1
        )
    }

    @Test
    func failedSettingsMutationKeepsFailureWithoutSuccessCopy() {
        let html = String(
            decoding: WebDashboardAssets.indexHTML(
                mutationNonce: "test-nonce"
            ),
            as: UTF8.self
        )

        #expect(
            html.contains(
                "const failedSettingsMutations = new Set();"
            )
        )
        #expect(
            html.contains(
                "failedSettingsMutations.add(mutationKey);"
            )
        )
        #expect(
            html.contains(
                "settingsSync.hidden = failedSettingsMutations.size > 0;"
            )
        )
        #expect(
            html.contains(
                "if (failedSettingsMutations.size === 0) {"
            )
        )
    }

    @Test
    func settingsMutationsScopeBusyStateToAffectedControl() throws {
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
                #"action.startsWith("move-account-")"#
            )
        )
        #expect(
            html.contains(
                #"? "accountProviderOrder""#
            )
        )
        let orderMutationPattern = try NSRegularExpression(
            pattern: #"mutateSettings\(\s*"accountProviderOrder","#
        )
        #expect(
            orderMutationPattern.numberOfMatches(
                in: html,
                range: NSRange(html.startIndex..<html.endIndex, in: html)
            ) == 2
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

    private func accountIdentityJSON(_ accountID: AccountID) -> String {
        "{\"accountID\":\"\(accountID.rawValue)\",\"providerID\":\"openrouter\"}"
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
        (@MainActor @Sendable (WebDashboardListenerState) -> Void)?

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
        stateChanged: @escaping @MainActor @Sendable (
            WebDashboardListenerState
        ) -> Void
    ) throws {
        lock.withLock {
            starts += 1
            self.stateChanged = stateChanged
        }
    }

    @MainActor
    func ready() {
        lock.withLock { stateChanged }?(.ready)
    }

    @MainActor
    func fail() {
        lock.withLock { stateChanged }?(
            .failed(.portInUse(port: 7_827))
        )
    }

    func stop() {
        lock.withLock {
            stopped = true
        }
    }
}

private final class RecordingWebDashboardConnection:
    WebDashboardConnection,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var finishes = 0

    var finishCount: Int {
        lock.withLock { finishes }
    }

    func finish() {
        lock.withLock {
            finishes += 1
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
