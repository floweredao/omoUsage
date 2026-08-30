import Foundation
import Testing
@testable import OmoUsage

@Suite
struct BoundedProcessRunnerTests {
    @Test
    func timeoutDrainsBothPipesThenTerminatesAndKills() async throws {
        let scheduler = BoundedProcessManualScheduler()
        let recorder = BoundedProcessEventRecorder()
        let runner = BoundedProcessRunner(
            schedule: scheduler.schedule,
            event: recorder.record
        )
        let task = Task.detached {
            try runner.run(
                executable: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; printf output-ready; "
                        + "printf error-ready >&2; while :; do :; done"
                ],
                timeout: 60,
                terminationGrace: 60
            )
        }

        let firstDeadline = await scheduler.nextScheduledDeadline()
        await recorder.waitForPipeReads()
        firstDeadline()
        let graceDeadline = await scheduler.nextScheduledDeadline()
        graceDeadline()

        let error = await #expect(throws: BoundedProcessError.self) {
            _ = try await task.value
        }
        #expect(error == .timedOut)
        let events = recorder.events
        #expect(events.contains { if case .started = $0 { true } else { false } })
        #expect(events.contains(.deadlineReached))
        #expect(events.contains(.terminateSent))
        #expect(events.contains(.killSent))
        #expect(events.contains(.standardOutputEOF))
        #expect(events.contains(.standardErrorEOF))
        #expect(events.contains { if case .terminated = $0 { true } else { false } })
        #expect(recorder.startedPID.map(processIsRunning) == false)
    }

    private func processIsRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}

private final class BoundedProcessManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []
    private var waiters: [CheckedContinuation<@Sendable () -> Void, Never>] = []

    func schedule(
        _ duration: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        lock.withLock {
            if waiters.isEmpty {
                callbacks.append(action)
            } else {
                waiters.removeFirst().resume(returning: action)
            }
        }
        return {}
    }

    func nextScheduledDeadline() async -> @Sendable () -> Void {
        if let callback = lock.withLock({
            callbacks.isEmpty ? nil : callbacks.removeFirst()
        }) {
            return callback
        }
        return await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }
}

private final class BoundedProcessEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BoundedProcessEvent] = []
    private var pipeWaiters: [CheckedContinuation<Void, Never>] = []

    var events: [BoundedProcessEvent] { lock.withLock { recorded } }
    var startedPID: Int32? {
        lock.withLock {
            for case let .started(pid) in recorded { return pid }
            return nil
        }
    }

    func record(_ event: BoundedProcessEvent) {
        lock.withLock {
            recorded.append(event)
            if hasReadBothPipes {
                let waiters = pipeWaiters
                pipeWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }

    func waitForPipeReads() async {
        if lock.withLock({ hasReadBothPipes }) { return }
        await withCheckedContinuation { continuation in
            lock.withLock { pipeWaiters.append(continuation) }
        }
    }

    private var hasReadBothPipes: Bool {
        recorded.contains {
            if case .standardOutputRead = $0 { true } else { false }
        } && recorded.contains {
            if case .standardErrorRead = $0 { true } else { false }
        }
    }
}
