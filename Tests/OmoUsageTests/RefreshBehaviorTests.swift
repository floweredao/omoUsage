import Foundation
import Testing
@testable import OmoUsage

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
    @Test
    @MainActor
    func characterizesImmediateLaunchRefresh() async {
        let (events, signal) = AsyncStream<Void>.makeStream()
        var iterator = events.makeAsyncIterator()
        let scheduler = UsageRefreshScheduler {
            signal.yield()
        }

        scheduler.start()

        #expect(await iterator.next() != nil)
        scheduler.stop()
        signal.finish()
    }

    @Test
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
    await withTaskGroup(of: Element?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
        }
        let event = await group.next() ?? nil
        group.cancelAll()
        return event
    }
}
