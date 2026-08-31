import Foundation
import Testing
@testable import OmoUsage

@Suite
struct MobileFreshnessPresentationTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_786_867_200)

    // MARK: - Snapshot age boundary

    @Test
    func snapshotStaysFreshOneSecondBeforeTheThreshold() {
        let presentation = MobileFreshnessPresentation(
            snapshot: freshSnapshot(),
            now: checkedAt.addingTimeInterval(14 * 60 + 59),
            hasSyncIssue: false
        )

        #expect(presentation.age == .fresh)
        #expect(!presentation.isStale)
        #expect(presentation.macLastCheckedAt == checkedAt)
    }

    @Test
    func snapshotBecomesStaleExactlyAtFifteenMinutes() {
        let presentation = MobileFreshnessPresentation(
            snapshot: freshSnapshot(),
            now: checkedAt.addingTimeInterval(15 * 60),
            hasSyncIssue: false
        )

        #expect(MobileFreshnessPresentation.staleThreshold == 15 * 60)
        #expect(presentation.age == .stale)
        #expect(presentation.isStale)
        #expect(presentation.macLastCheckedAt == checkedAt)
    }

    @Test
    func aSnapshotFromTheFutureIsNeverReportedAsStale() {
        let presentation = MobileFreshnessPresentation(
            snapshot: freshSnapshot(),
            now: checkedAt.addingTimeInterval(-3_600),
            hasSyncIssue: false
        )

        #expect(presentation.age == .fresh)
    }

    @Test
    func macCheckTimeIsTheAttemptTimeRatherThanProviderSuccess() {
        let successAt = checkedAt.addingTimeInterval(-7_200)
        let provider = usage(
            lastSuccessfulAt: successAt,
            lastRefreshAttemptAt: checkedAt,
            refreshFailure: .network
        )
        let snapshot = DashboardSnapshot(
            providers: [provider],
            generatedAt: checkedAt,
            lastRefreshAttemptAt: checkedAt,
            oldestDisplayedSuccessAt: successAt
        )

        let presentation = MobileFreshnessPresentation(
            snapshot: snapshot,
            now: checkedAt.addingTimeInterval(60),
            hasSyncIssue: false
        )

        #expect(presentation.macLastCheckedAt == checkedAt)
        #expect(presentation.age == .fresh)
        #expect(snapshot.providers[0].freshness == .stale)
        #expect(snapshot.providers[0].lastSuccessfulAt == successAt)
    }

    // MARK: - Last-good retention

    @Test
    @MainActor
    func syncFailureKeepsTheLastGoodSnapshotAndMarksASyncIssue() {
        let retained = freshSnapshot()
        let loader = MobileFreshnessTestLoader(
            responses: [
                .success(retained),
                .failure(MobileFreshnessTestError.unavailable)
            ]
        )
        let now = checkedAt.addingTimeInterval(15 * 60)
        let viewModel = MobileUsageViewModel(
            loadSnapshot: loader.load,
            now: { now }
        )

        viewModel.reload()
        viewModel.reload()

        let presentation = viewModel.freshnessPresentation
        #expect(viewModel.snapshot == retained)
        #expect(viewModel.loadState == .failed)
        #expect(presentation?.hasSyncIssue == true)
        #expect(presentation?.age == .stale)
        #expect(presentation?.macLastCheckedAt == checkedAt)
        #expect(
            viewModel.snapshot?.providers.first?.lastSuccessfulAt
                == checkedAt
        )
    }

    @Test
    @MainActor
    func aNewerSnapshotClearsTheSyncIssueAndAdvancesTheCheckTime() {
        let retained = freshSnapshot()
        let arrived = snapshot(checkedAt: checkedAt.addingTimeInterval(600))
        let loader = MobileFreshnessTestLoader(
            responses: [
                .success(retained),
                .failure(MobileFreshnessTestError.unavailable),
                .success(arrived)
            ]
        )
        let now = checkedAt.addingTimeInterval(660)
        let viewModel = MobileUsageViewModel(
            loadSnapshot: loader.load,
            now: { now }
        )

        viewModel.reload()
        viewModel.reload()
        viewModel.reload()

        let presentation = viewModel.freshnessPresentation
        #expect(viewModel.snapshot == arrived)
        #expect(viewModel.loadState == .content)
        #expect(presentation?.hasSyncIssue == false)
        #expect(presentation?.age == .fresh)
        #expect(
            presentation?.macLastCheckedAt
                == checkedAt.addingTimeInterval(600)
        )
    }

    // MARK: - Truthful pull to refresh

    @Test
    @MainActor
    func pullRefreshNeverMovesMacOrProviderTimesWithoutANewSnapshot() {
        let retained = freshSnapshot()
        let loader = MobileFreshnessTestLoader(
            responses: [.success(retained), .success(retained)]
        )
        let now = checkedAt.addingTimeInterval(120)
        let viewModel = MobileUsageViewModel(
            loadSnapshot: loader.load,
            now: { now }
        )

        viewModel.reload()
        let before = viewModel.snapshot
        viewModel.reload()

        #expect(loader.requestCount == 2)
        #expect(viewModel.snapshot == before)
        #expect(viewModel.snapshot?.generatedAt == checkedAt)
        #expect(viewModel.freshnessPresentation?.macLastCheckedAt == checkedAt)
        #expect(
            viewModel.snapshot?.providers.first?.lastRefreshAttemptAt
                == checkedAt
        )
        #expect(
            viewModel.snapshot?.providers.first?.lastSuccessfulAt == checkedAt
        )
    }

    @Test
    @MainActor
    func oneRefreshPerformsExactlyOneICloudRead() throws {
        let keyValueStore = MobileFreshnessTestKeyValueStore()
        keyValueStore.set(
            try UsageSnapshotCodec.encode(freshSnapshot()),
            forKey: UbiquitousUsageSnapshotStore.snapshotKey
        )
        let store = UbiquitousUsageSnapshotStore(store: keyValueStore)
        let now = checkedAt
        let viewModel = MobileUsageViewModel(
            loadSnapshot: { try store.load() },
            now: { now }
        )

        viewModel.reload()

        #expect(keyValueStore.synchronizeCount == 1)
        #expect(keyValueStore.readCount == 1)
        #expect(viewModel.loadState == .content)
    }

    // MARK: - Copy and VoiceOver semantics

    @Test
    func refreshCopyPromisesAnICloudCheckAndNoProviderCall() {
        for language in AppLanguage.allCases {
            let strings = AppStrings(language: language)
            let action = strings.text(.checkICloud)
            let explanation = strings.text(.mobileICloudCheckExplanation)

            #expect(action.localizedCaseInsensitiveContains("icloud"))
            #expect(explanation.localizedCaseInsensitiveContains("icloud"))
            #expect(!action.localizedCaseInsensitiveContains("provider"))
            #expect(!action.contains("프로바이더"))
            #expect(strings.text(.macLastChecked).contains("%@"))
            #expect(!strings.text(.mobileSnapshotOutOfDate).isEmpty)
            #expect(!strings.text(.mobileRetainedAfterSyncFailure).isEmpty)
        }
    }

    @Test
    @MainActor
    func voiceOverStatesTheMacCheckTimeStalenessAndSyncIssue() {
        let localization = LocalizationContext(language: .english)
        let stale = MobileFreshnessPresentation(
            snapshot: freshSnapshot(),
            now: checkedAt.addingTimeInterval(15 * 60),
            hasSyncIssue: true
        )
        let current = MobileFreshnessPresentation(
            snapshot: freshSnapshot(),
            now: checkedAt,
            hasSyncIssue: false
        )

        let staleLabel = stale.accessibilityLabel(
            localization,
            clockText: "10:00"
        )
        let currentLabel = current.accessibilityLabel(
            localization,
            clockText: "10:00"
        )

        #expect(
            staleLabel.contains(
                localization.format(.macLastChecked, "10:00")
            )
        )
        #expect(
            staleLabel.contains(localization.text(.mobileSnapshotOutOfDate))
        )
        #expect(
            staleLabel.contains(
                localization.text(.mobileRetainedAfterSyncFailure)
            )
        )
        #expect(
            currentLabel == localization.format(.macLastChecked, "10:00")
        )
        #expect(
            current.statusText(localization, clockText: "10:00")
                == localization.format(.macLastChecked, "10:00")
        )
    }

    @Test
    @MainActor
    func staleSnapshotStateUsesSymbolAndTextRatherThanColorAlone() {
        #expect(!MobileFreshnessVisualTokens.symbolName.isEmpty)
        #expect(MobileFreshnessVisualTokens.usesTextLabel)
        #expect(
            MobileFreshnessVisualTokens.accent == StaleUsageVisualTokens.accent
        )
        for language in AppLanguage.allCases {
            let context = LocalizationContext(language: language)
            #expect(
                context.snapshotAgeBadgeText()
                    == AppStrings(language: language)
                        .text(.mobileSnapshotOutOfDate)
            )
            #expect(!context.snapshotAgeBadgeText().isEmpty)
        }
    }

    // MARK: - Deterministic QA fixture state

    @Test
    func fixtureEnvironmentDescribesBoundaryAndSyncFailureStates() {
        #expect(
            MobileFixtureEnvironment.snapshotAgeSeconds([:]) == 0
        )
        #expect(
            MobileFixtureEnvironment.snapshotAgeSeconds(
                ["OMO_USAGE_FIXTURE_AGE_SECONDS": "899"]
            ) == 899
        )
        #expect(
            MobileFixtureEnvironment.snapshotAgeSeconds(
                ["OMO_USAGE_FIXTURE_AGE_SECONDS": "900"]
            ) == 900
        )
        #expect(
            MobileFixtureEnvironment.snapshotAgeSeconds(
                ["OMO_USAGE_FIXTURE_AGE_SECONDS": "-30"]
            ) == 0
        )
        #expect(
            MobileFixtureEnvironment.snapshotAgeSeconds(
                ["OMO_USAGE_FIXTURE_AGE_SECONDS": "nonsense"]
            ) == 0
        )
        #expect(
            !MobileFixtureEnvironment.simulatesSyncFailure([:])
        )
        #expect(
            MobileFixtureEnvironment.simulatesSyncFailure(
                ["OMO_USAGE_FIXTURE_SYNC_FAILURE": "1"]
            )
        )
    }

    @Test
    @MainActor
    func fixtureSyncFailureRetainsFixtureContentForVisualQA() {
        let fixture = DashboardSnapshot.mobileFixture(now: checkedAt)
        let viewModel = MobileUsageViewModel(
            loadSnapshot: { throw MobileFreshnessTestError.unavailable },
            fixtureSnapshot: fixture,
            simulatesSyncFailure: true,
            now: { self.checkedAt.addingTimeInterval(15 * 60) }
        )

        viewModel.reload()

        #expect(viewModel.snapshot == fixture)
        #expect(viewModel.loadState == .failed)
        #expect(viewModel.freshnessPresentation?.hasSyncIssue == true)
        #expect(viewModel.freshnessPresentation?.age == .stale)
    }

    // MARK: - Fixtures

    private func freshSnapshot() -> DashboardSnapshot {
        snapshot(checkedAt: checkedAt)
    }

    private func snapshot(checkedAt: Date) -> DashboardSnapshot {
        DashboardSnapshot(
            providers: [
                usage(
                    lastSuccessfulAt: checkedAt,
                    lastRefreshAttemptAt: checkedAt,
                    refreshFailure: nil
                )
            ],
            generatedAt: checkedAt,
            lastRefreshAttemptAt: checkedAt,
            oldestDisplayedSuccessAt: checkedAt
        )
    }

    private func usage(
        lastSuccessfulAt: Date?,
        lastRefreshAttemptAt: Date?,
        refreshFailure: ProviderRefreshFailure?
    ) -> ProviderUsage {
        ProviderUsage(
            provider: .codex,
            planName: "Plus",
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

private enum MobileFreshnessTestError: Error {
    case unavailable
}

@MainActor
private final class MobileFreshnessTestLoader {
    private var responses: [Result<DashboardSnapshot?, any Error>]
    private(set) var requestCount = 0

    init(responses: [Result<DashboardSnapshot?, any Error>]) {
        self.responses = responses
    }

    func load() throws -> DashboardSnapshot? {
        requestCount += 1
        return try responses.removeFirst().get()
    }
}

private final class MobileFreshnessTestKeyValueStore:
    UbiquitousKeyValueStoring
{
    private var values: [String: Any] = [:]
    private(set) var synchronizeCount = 0
    private(set) var readCount = 0

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    func data(forKey key: String) -> Data? {
        readCount += 1
        return values[key] as? Data
    }

    func synchronize() -> Bool {
        synchronizeCount += 1
        return true
    }
}
