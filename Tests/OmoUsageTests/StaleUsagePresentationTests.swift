import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct StaleUsagePresentationTests {
    private let successAt = Date(timeIntervalSince1970: 1_785_675_000)
    private let attemptInterval: TimeInterval = 600

    // MARK: - Refresh merge

    @Test(
        arguments: [
            (TransientProviderFailure.network, ProviderRefreshFailure.network),
            (.transientTransport, .network),
            (.operationTimedOut, .network),
            (.serviceUnavailable, .service),
            (.invalidResponse, .schema),
            (.invalidContentType, .schema),
            (.responseTooLarge, .schema),
            (.invalidJSON, .schema),
            (.parserRejectedPayload, .schema),
            (.credentialMalformed, .credential),
            (.credentialExpired, .credential)
        ]
    )
    @MainActor
    func transientFailureRetainsValuesAndMarksThemStale(
        failure: TransientProviderFailure,
        expected: ProviderRefreshFailure
    ) async {
        let harness = await Harness(failure: failure)

        await harness.refreshSucceeding()
        await harness.refreshFailing()

        let retained = harness.retainedUsage
        #expect(retained?.groups == harness.usage.groups)
        #expect(retained?.planName == harness.usage.planName)
        #expect(retained?.availability == .available)
        #expect(retained?.freshness == .stale)
        #expect(retained?.refreshFailure == expected)
        #expect(retained?.lastSuccessfulAt == successAt)
        #expect(
            retained?.lastRefreshAttemptAt
                == successAt.addingTimeInterval(attemptInterval)
        )
    }

    @Test
    @MainActor
    func successKeepsFreshnessCurrentAndAlignsAttemptWithSuccess() async {
        let harness = await Harness(failure: .network)

        await harness.refreshSucceeding()

        let fresh = harness.retainedUsage
        #expect(fresh?.freshness == .current)
        #expect(fresh?.refreshFailure == nil)
        #expect(fresh?.lastSuccessfulAt == successAt)
        #expect(fresh?.lastRefreshAttemptAt == successAt)
    }

    @Test
    @MainActor
    func repeatedFailuresFreezeSuccessAndAdvanceEveryAttempt() async {
        let harness = await Harness(failure: .network)

        await harness.refreshSucceeding()
        await harness.refreshFailing()
        await harness.refreshFailing()

        let retained = harness.retainedUsage
        #expect(retained?.lastSuccessfulAt == successAt)
        #expect(
            retained?.lastRefreshAttemptAt
                == successAt.addingTimeInterval(attemptInterval * 2)
        )
        #expect(
            harness.viewModel.snapshot.lastRefreshAttemptAt
                == successAt.addingTimeInterval(attemptInterval * 2)
        )
        #expect(
            harness.viewModel.snapshot.oldestDisplayedSuccessAt == successAt
        )
    }

    @Test
    @MainActor
    func recoveryClearsStaleMarking() async {
        let harness = await Harness(failure: .network)

        await harness.refreshSucceeding()
        await harness.refreshFailing()
        await harness.refreshSucceeding()

        let recovered = harness.retainedUsage
        #expect(recovered?.freshness == .current)
        #expect(recovered?.refreshFailure == nil)
        #expect(
            recovered?.lastSuccessfulAt
                == successAt.addingTimeInterval(attemptInterval * 2)
        )
    }

    @Test(
        arguments: [
            TransientProviderFailure.authenticationRequired,
            .credentialNotFound
        ]
    )
    @MainActor
    func authenticationFailureStillRemovesRetainedUsage(
        failure: TransientProviderFailure
    ) async {
        let harness = await Harness(failure: failure)

        await harness.refreshSucceeding()
        await harness.refreshFailing()

        #expect(harness.viewModel.snapshot.providers.isEmpty)
        #expect(
            harness.viewModel.connectionStates[.codex]
                == .authenticationRequired
        )
    }

    // MARK: - Shared presentation

    @Test
    func staleDisplayExposesDistinctSuccessAndAttemptRows() {
        let display = ProviderFreshnessDisplay.make(
            for: staleUsage(),
            includesSuccessRow: false
        )

        #expect(display.showsStaleBadge)
        #expect(display.successAt == successAt)
        #expect(
            display.attemptAt == successAt.addingTimeInterval(attemptInterval)
        )
        #expect(display.successAt != display.attemptAt)
        #expect(display.rowCount == 2)
    }

    @Test
    func currentDisplayHidesTheBadgeAndTheAttemptRow() {
        let display = ProviderFreshnessDisplay.make(
            for: currentUsage(),
            includesSuccessRow: true
        )

        #expect(!display.showsStaleBadge)
        #expect(display.successAt == successAt)
        #expect(display.attemptAt == nil)
        #expect(display.rowCount == 1)
    }

    @Test
    func suppressedTimestampRowStaysHiddenWhileFresh() {
        let display = ProviderFreshnessDisplay.make(
            for: currentUsage(),
            includesSuccessRow: false
        )

        #expect(!display.showsStaleBadge)
        #expect(display.rowCount == 0)
    }

    @Test
    @MainActor
    func staleBadgeIsTextAndSymbolRatherThanColorAlone() {
        #expect(!StaleUsageVisualTokens.symbolName.isEmpty)
        #expect(StaleUsageVisualTokens.usesTextLabel)
        #expect(
            StaleUsageVisualTokens.accent == UsageMeterVisualTokens.extraFill
        )
        for language in AppLanguage.allCases {
            let context = LocalizationContext(language: language)
            #expect(
                context.staleBadgeText()
                    == AppStrings(language: language).text(.refreshFailed)
            )
            #expect(!context.staleBadgeText().isEmpty)
        }
    }

    // MARK: - macOS layout

    @Test
    func popoverReservesTheStaleBadgeAndAttemptRow() {
        let current = currentUsage()
        let stale = staleUsage()

        let growth = DashboardLayout.sectionHeight(stale)
            - DashboardLayout.sectionHeight(current)

        #expect(growth == StaleUsageVisualTokens.badgeRowHeight + 8 + 16 + 8)
        #expect(
            DashboardLayout.panelHeight(for: [stale])
                > DashboardLayout.panelHeight(for: [current])
        )
    }

    // MARK: - Side Notch

    @Test
    func sideNotchMarksStaleProvidersOnTheRail() {
        #expect(SideNotchFreshnessPolicy.showsFailureMarker(for: staleUsage()))
        #expect(
            !SideNotchFreshnessPolicy.showsFailureMarker(for: currentUsage())
        )
        #expect(
            SideNotchFreshnessPolicy.showsFailureMarker(
                for: failedUsage()
            )
        )
    }

    // MARK: - Web and mobile serialization

    @Test
    func snapshotCodecRoundTripsFreshnessMarkers() throws {
        let snapshot = DashboardSnapshot(
            providers: [staleUsage()],
            generatedAt: successAt.addingTimeInterval(attemptInterval),
            lastRefreshAttemptAt: successAt.addingTimeInterval(
                attemptInterval
            ),
            oldestDisplayedSuccessAt: successAt
        )

        let encoded = try UsageSnapshotCodec.encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let payload = try #require(
            (object["providers"] as? [[String: Any]])?.first
        )

        #expect(payload["lastSuccessfulAt"] != nil)
        #expect(payload["lastRefreshAttemptAt"] != nil)
        #expect(payload["refreshFailure"] as? String == "network")
        #expect(try UsageSnapshotCodec.decode(encoded) == snapshot)
    }

    @Test
    func freshProvidersOmitTheFailureMarkerFromTheWirePayload() throws {
        let snapshot = DashboardSnapshot(
            providers: [currentUsage()],
            refreshedAt: successAt
        )

        let encoded = try UsageSnapshotCodec.encode(snapshot)
        let payload = try #require(
            (
                (
                    JSONSerialization.jsonObject(with: encoded)
                        as? [String: Any]
                )?["providers"] as? [[String: Any]]
            )?.first
        )

        #expect(payload["refreshFailure"] == nil)
    }

    @Test
    func codecRejectsAnAttemptOlderThanItsRecordedSuccess() {
        let snapshot = DashboardSnapshot(
            providers: [
                usage(
                    lastSuccessfulAt: successAt,
                    lastRefreshAttemptAt: successAt.addingTimeInterval(-60),
                    refreshFailure: .network
                )
            ],
            generatedAt: successAt,
            lastRefreshAttemptAt: successAt,
            oldestDisplayedSuccessAt: successAt
        )

        #expect(throws: UsageSnapshotCodecError.invalidPayload) {
            try UsageSnapshotCodec.encode(snapshot)
        }
    }

    @Test
    func localizedSnapshotPreservesFreshnessMarkers() {
        let localized = DashboardSnapshot(
            providers: [staleUsage()],
            generatedAt: successAt.addingTimeInterval(attemptInterval),
            lastRefreshAttemptAt: successAt.addingTimeInterval(
                attemptInterval
            ),
            oldestDisplayedSuccessAt: successAt
        ).localized(using: LocalizationContext(language: .english))

        #expect(localized.providers.first?.freshness == .stale)
        #expect(localized.providers.first?.refreshFailure == .network)
        #expect(
            localized.providers.first?.lastRefreshAttemptAt
                == successAt.addingTimeInterval(attemptInterval)
        )
    }

    @Test
    func webClientRendersFreshnessFromTheV3Payload() throws {
        let html = try #require(
            String(
                data: WebDashboardAssets.indexHTML(mutationNonce: "nonce"),
                encoding: .utf8
            )
        )

        #expect(html.contains("provider.lastSuccessfulAt"))
        #expect(html.contains("provider.lastRefreshAttemptAt"))
        #expect(html.contains("provider.refreshFailure"))
        #expect(html.contains("snapshot.lastRefreshAttemptAt"))
        #expect(html.contains("stale-badge"))
        #expect(html.contains("dataset.freshness"))
        #expect(!html.contains("provider.updatedAt"))
        #expect(!html.contains("snapshot.refreshedAt"))
    }

    @Test
    func mobileFixtureShowsOneStaleCardWithDistinctTimestamps() {
        let snapshot = DashboardSnapshot.mobileFixture(now: successAt)
        let stale = snapshot.providers.filter { $0.freshness == .stale }

        #expect(stale.count == 1)
        #expect(stale.first?.refreshFailure != nil)
        #expect(stale.first?.lastSuccessfulAt != nil)
        #expect(stale.first?.lastRefreshAttemptAt != nil)
        #expect(
            stale.first?.lastSuccessfulAt != stale.first?.lastRefreshAttemptAt
        )
        #expect(snapshot.providers.contains { $0.freshness == .current })
    }

    // MARK: - Fixtures

    private func currentUsage() -> ProviderUsage {
        usage(
            lastSuccessfulAt: successAt,
            lastRefreshAttemptAt: successAt,
            refreshFailure: nil
        )
    }

    private func staleUsage() -> ProviderUsage {
        usage(
            lastSuccessfulAt: successAt,
            lastRefreshAttemptAt: successAt.addingTimeInterval(
                attemptInterval
            ),
            refreshFailure: .network
        )
    }

    private func failedUsage() -> ProviderUsage {
        ProviderUsage(
            provider: .codex,
            planName: "Pro",
            groups: [],
            availability: .failed,
            lastSuccessfulAt: nil
        )
    }

    private func usage(
        lastSuccessfulAt: Date?,
        lastRefreshAttemptAt: Date?,
        refreshFailure: ProviderRefreshFailure?
    ) -> ProviderUsage {
        ProviderUsage(
            provider: .codex,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: "codex.usage",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "codex.week",
                            title: "주간",
                            period: .week,
                            percentRemaining: 73
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            lastSuccessfulAt: lastSuccessfulAt,
            lastRefreshAttemptAt: lastRefreshAttemptAt,
            refreshFailure: refreshFailure
        )
    }
}

enum TransientProviderFailure: Sendable {
    case network
    case transientTransport
    case operationTimedOut
    case serviceUnavailable
    case invalidResponse
    case invalidContentType
    case responseTooLarge
    case invalidJSON
    case parserRejectedPayload
    case credentialMalformed
    case credentialExpired
    case authenticationRequired
    case credentialNotFound

    func error(for provider: ProviderID) -> any Error {
        switch self {
        case .network:
            URLError(.notConnectedToInternet)
        case .transientTransport:
            ProviderTransportError.transientTransport(
                provider,
                .networkConnectionLost
            )
        case .operationTimedOut:
            ProviderTransportError.operationTimedOut(provider)
        case .serviceUnavailable:
            ProviderTransportError.requestFailed(provider, 503)
        case .invalidResponse:
            ProviderTransportError.invalidResponse(provider)
        case .invalidContentType:
            ProviderTransportError.invalidContentType(provider, "text/html")
        case .responseTooLarge:
            ProviderTransportError.responseTooLarge(provider, limit: 1_048_576)
        case .invalidJSON:
            ProviderTransportError.invalidJSON(provider)
        case .parserRejectedPayload:
            UsageParsingError.invalidPayload
        case .credentialMalformed:
            CredentialDiscoveryError.malformed(provider)
        case .credentialExpired:
            CredentialDiscoveryError.expired(provider)
        case .authenticationRequired:
            ProviderTransportError.authenticationRequired(provider)
        case .credentialNotFound:
            CredentialDiscoveryError.notFound(provider)
        }
    }
}

@MainActor
private struct Harness {
    let usage: ProviderUsage
    let provider: SwitchableUsageProvider
    let viewModel: UsageDashboardViewModel
    let clock: TestClock

    init(failure: TransientProviderFailure) async {
        let successAt = Date(timeIntervalSince1970: 1_785_675_000)
        usage = ProviderUsage(
            provider: .codex,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: "codex.usage",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "codex.week",
                            title: "주간",
                            period: .week,
                            percentRemaining: 73
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            lastSuccessfulAt: successAt
        )
        provider = SwitchableUsageProvider(usage: usage, failure: failure)
        clock = TestClock(start: successAt)
        let clock = clock
        viewModel = UsageDashboardViewModel(
            providers: [provider],
            now: { clock.value }
        )
    }

    var retainedUsage: ProviderUsage? {
        viewModel.snapshot.providers.first
    }

    func refreshSucceeding() async {
        await provider.setFailing(false)
        await provider.setSuccessTimestamp(clock.value)
        await viewModel.refresh()
        clock.advance(by: 600)
    }

    func refreshFailing() async {
        await provider.setFailing(true)
        await viewModel.refresh()
        clock.advance(by: 600)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) {
        current = start
    }

    var value: Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

private actor SwitchableUsageProvider: UsageProvider {
    nonisolated let id = ProviderID.codex

    private var usage: ProviderUsage
    private let failure: TransientProviderFailure
    private var isFailing = false

    init(usage: ProviderUsage, failure: TransientProviderFailure) {
        self.usage = usage
        self.failure = failure
    }

    func setFailing(_ failing: Bool) {
        isFailing = failing
    }

    func setSuccessTimestamp(_ date: Date) {
        usage = ProviderUsage(
            provider: usage.provider,
            accountID: usage.accountID,
            accountLabel: usage.accountLabel,
            planName: usage.planName,
            groups: usage.groups,
            availability: usage.availability,
            lastSuccessfulAt: date
        )
    }

    func fetch(now: Date) async throws -> ProviderUsage {
        guard !isFailing else {
            throw failure.error(for: id)
        }
        return usage
    }
}
