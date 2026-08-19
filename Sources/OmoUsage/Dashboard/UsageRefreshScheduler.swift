import Foundation

@MainActor
final class UsageRefreshScheduler {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Refresh = @MainActor @Sendable () async -> Void

    let interval: Duration

    private let sleep: Sleep
    private let refresh: Refresh
    private var task: Task<Void, Never>?

    init(
        interval: Duration = .seconds(60),
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        refresh: @escaping Refresh
    ) {
        self.interval = interval
        self.sleep = sleep
        self.refresh = refresh
    }

    func start() {
        guard task == nil else { return }
        task = Task { [interval, refresh, sleep] in
            while !Task.isCancelled {
                await refresh()
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
