import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct RefreshTimestampPresenterTests {
    private let updatedAt = Date(timeIntervalSince1970: 1_785_672_000)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test
    func showsNowOnlyBeforeTenSeconds() {
        #expect(
            RefreshTimestampPresenter.footerText(
                refreshedAt: updatedAt,
                now: updatedAt.addingTimeInterval(9.999),
                timeZone: utc
            ) == "방금"
        )
        #expect(
            RefreshTimestampPresenter.footerText(
                refreshedAt: updatedAt,
                now: updatedAt.addingTimeInterval(10),
                timeZone: utc
            ) == "12:00"
        )
        #expect(
            RefreshTimestampPresenter.providerText(
                updatedAt: updatedAt,
                now: updatedAt.addingTimeInterval(9.999),
                timeZone: utc
            ) == "방금 기준"
        )
        #expect(
            RefreshTimestampPresenter.providerText(
                updatedAt: updatedAt,
                now: updatedAt.addingTimeInterval(10),
                timeZone: utc
            ) == "12:00 기준"
        )
    }

    @Test
    func formatsMidnightAndNoonInTwentyFourHourTime() {
        let midnight = Date(timeIntervalSince1970: 1_785_628_800)
        #expect(
            RefreshTimestampPresenter.footerText(
                refreshedAt: midnight,
                now: midnight.addingTimeInterval(10),
                timeZone: utc
            ) == "00:00"
        )
        #expect(
            RefreshTimestampPresenter.footerText(
                refreshedAt: updatedAt,
                now: updatedAt.addingTimeInterval(10),
                timeZone: utc
            ) == "12:00"
        )
    }

    @Test(arguments: [AppLanguage.korean, .english])
    func clockKeepsTwentyFourHourTimeInEveryAppLanguage(
        language: AppLanguage
    ) {
        let evening = updatedAt.addingTimeInterval(11 * 3_600)
        #expect(
            RefreshTimestampPresenter.footerText(
                refreshedAt: evening,
                now: evening.addingTimeInterval(10),
                language: language,
                timeZone: utc
            ) == "23:00"
        )
        #expect(
            RefreshTimestampPresenter.providerText(
                updatedAt: evening,
                now: evening.addingTimeInterval(10),
                language: language,
                timeZone: utc
            ).contains("23:00")
        )
    }

    @Test
    func futureTimestampRemainsNow() {
        #expect(
            RefreshTimestampPresenter.footerText(
                refreshedAt: updatedAt,
                now: updatedAt.addingTimeInterval(-1),
                timeZone: utc
            ) == "방금"
        )
    }
}

@Suite
struct UsageRefreshSchedulerTests {
    @Test(arguments: [ProviderID.claude, .codex])
    @MainActor
    func companionLaunchUsesItsProviderCompletionSignal(provider: ProviderID) async {
        let coordinator = ProviderConnectionCoordinator()
        coordinator.record(.success(.launched), for: provider)
        var refreshCount = 0

        #expect(refreshCount == 0)
        #expect(
            coordinator.state(for: provider) == .waitingForCredential
        )
        await coordinator.applicationDidBecomeActive(
            refresh: { refreshCount += 1 },
            availability: { (_: ProviderID) in .authenticationRequired }
        )
        // Claude waits for the observed CLI exit; Codex retains activation refresh.
        #expect(refreshCount == (provider == .claude ? 0 : 1))
        #expect(
            coordinator.state(for: provider) == .waitingForCredential
        )
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func repeatsRefreshEveryMinute() async {
        let (ticks, tickSignal) = AsyncStream<Void>.makeStream()
        let (delays, delaySignal) = AsyncStream<Duration>.makeStream()
        let (refreshes, refreshSignal) = AsyncStream<Void>.makeStream()
        let scheduler = UsageRefreshScheduler(
            sleep: { duration in
                delaySignal.yield(duration)
                var iterator = ticks.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    throw CancellationError()
                }
            },
            refresh: {
                refreshSignal.yield()
            }
        )

        scheduler.start()

        #expect(await nextEvent(from: refreshes) != nil)
        #expect(await nextEvent(from: delays) == .seconds(60))
        tickSignal.yield()
        #expect(await nextEvent(from: refreshes) != nil)
        #expect(await nextEvent(from: delays) == .seconds(60))

        scheduler.stop()
        tickSignal.finish()
        delaySignal.finish()
        refreshSignal.finish()
    }
}

private func nextEvent<Element: Sendable>(
    from stream: AsyncStream<Element>
) async -> Element? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}
