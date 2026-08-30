import Darwin
import Foundation

enum BoundedProcessError: Error, Equatable {
    case timedOut
}

enum BoundedProcessEvent: Equatable, Sendable {
    case started(Int32)
    case standardOutputRead(Int)
    case standardErrorRead(Int)
    case deadlineReached
    case terminateSent
    case killSent
    case standardOutputEOF
    case standardErrorEOF
    case terminated(Int32)
}

struct BoundedProcessResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
}

struct BoundedProcessRunner: Sendable {
    typealias Schedule = @Sendable (
        _ duration: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void

    private let schedule: Schedule
    private let event: @Sendable (BoundedProcessEvent) -> Void

    init(
        schedule: @escaping Schedule = Self.dispatchSchedule,
        event: @escaping @Sendable (BoundedProcessEvent) -> Void = { _ in }
    ) {
        self.schedule = schedule
        self.event = event
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 0.25
    ) throws -> BoundedProcessResult {
        try Task.checkCancellation()

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let output = BoundedProcessOutput()
        let lifecycle = BoundedProcessLifecycle()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError

        installReader(
            standardOutput.fileHandleForReading,
            stream: .standardOutput,
            output: output,
            lifecycle: lifecycle
        )
        installReader(
            standardError.fileHandleForReading,
            stream: .standardError,
            output: output,
            lifecycle: lifecycle
        )
        process.terminationHandler = { process in
            event(.terminated(process.terminationStatus))
            lifecycle.processTerminated()
        }

        do {
            try process.run()
        } catch {
            closeReaders(
                standardOutput.fileHandleForReading,
                standardError.fileHandleForReading,
                output: output,
                lifecycle: lifecycle
            )
            throw error
        }
        event(.started(process.processIdentifier))

        let cancelDeadline = schedule(max(0, timeout)) {
            if lifecycle.deadlineReached() {
                event(.deadlineReached)
            }
        }
        let outcome = lifecycle.waitForInitialOutcome()
        cancelDeadline()

        if outcome == .deadline {
            event(.terminateSent)
            process.terminate()
            if lifecycle.beginGracePeriod() {
                let cancelGrace = schedule(max(0, terminationGrace)) {
                    lifecycle.graceReached()
                }
                let graceExpired = lifecycle.waitForGraceOutcome()
                cancelGrace()
                if graceExpired {
                    event(.killSent)
                    kill(process.processIdentifier, SIGKILL)
                    lifecycle.waitForTermination()
                }
            }
        }

        closeReaders(
            standardOutput.fileHandleForReading,
            standardError.fileHandleForReading,
            output: output,
            lifecycle: lifecycle
        )
        try Task.checkCancellation()
        guard outcome == .terminated else {
            throw BoundedProcessError.timedOut
        }
        return BoundedProcessResult(
            status: process.terminationStatus,
            standardOutput: output.standardOutput,
            standardError: output.standardError
        )
    }

    fileprivate enum Stream: Equatable {
        case standardOutput
        case standardError
    }

    private func installReader(
        _ handle: FileHandle,
        stream: Stream,
        output: BoundedProcessOutput,
        lifecycle: BoundedProcessLifecycle
    ) {
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                if output.recordEOF(stream, event: event) {
                    lifecycle.reachedEOF()
                }
                return
            }
            output.append(data, to: stream)
            switch stream {
            case .standardOutput:
                event(.standardOutputRead(data.count))
            case .standardError:
                event(.standardErrorRead(data.count))
            }
        }
    }

    private func closeReaders(
        _ standardOutput: FileHandle,
        _ standardError: FileHandle,
        output: BoundedProcessOutput,
        lifecycle: BoundedProcessLifecycle
    ) {
        standardOutput.readabilityHandler = nil
        standardError.readabilityHandler = nil
        try? standardOutput.close()
        try? standardError.close()
        if output.recordEOF(.standardOutput, event: event) {
            lifecycle.reachedEOF()
        }
        if output.recordEOF(.standardError, event: event) {
            lifecycle.reachedEOF()
        }
    }

    private static func dispatchSchedule(
        _ duration: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, duration),
            execute: item
        )
        let cancellation = BoundedProcessScheduledCancellation(item: item)
        return { cancellation.cancel() }
    }
}

private final class BoundedProcessScheduledCancellation: @unchecked Sendable {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    private var outputReachedEOF = false
    private var errorReachedEOF = false

    var standardOutput: Data { lock.withLock { output } }
    var standardError: Data { lock.withLock { error } }

    func append(_ data: Data, to stream: BoundedProcessRunner.Stream) {
        lock.withLock {
            switch stream {
            case .standardOutput: output.append(data)
            case .standardError: error.append(data)
            }
        }
    }

    @discardableResult
    func recordEOF(
        _ stream: BoundedProcessRunner.Stream,
        event: @Sendable (BoundedProcessEvent) -> Void
    ) -> Bool {
        let shouldPublish = lock.withLock {
            switch stream {
            case .standardOutput:
                guard !outputReachedEOF else { return false }
                outputReachedEOF = true
            case .standardError:
                guard !errorReachedEOF else { return false }
                errorReachedEOF = true
            }
            return true
        }
        guard shouldPublish else { return false }
        event(stream == .standardOutput ? .standardOutputEOF : .standardErrorEOF)
        return true
    }
}

private final class BoundedProcessLifecycle: @unchecked Sendable {
    enum InitialOutcome { case terminated, deadline }

    private let lock = NSLock()
    private let initialSignal = DispatchSemaphore(value: 0)
    private let graceSignal = DispatchSemaphore(value: 0)
    private let terminationSignal = DispatchSemaphore(value: 0)
    private var initialOutcome: InitialOutcome?
    private var didTerminate = false
    private var eofCount = 0
    private var graceExpired = false

    func processTerminated() {
        let signals = lock.withLock { () -> (Bool, Bool) in
            guard !didTerminate else { return (false, false) }
            didTerminate = true
            let signalsInitial = resolveCompletionIfReady()
            return (signalsInitial, true)
        }
        if signals.0 { initialSignal.signal() }
        if signals.1 {
            graceSignal.signal()
            terminationSignal.signal()
        }
    }

    func reachedEOF() {
        let signalsInitial = lock.withLock {
            eofCount += 1
            return resolveCompletionIfReady()
        }
        if signalsInitial { initialSignal.signal() }
    }

    private func resolveCompletionIfReady() -> Bool {
        guard didTerminate, eofCount == 2, initialOutcome == nil else {
            return false
        }
        initialOutcome = .terminated
        return true
    }

    func deadlineReached() -> Bool {
        let resolved = lock.withLock {
            guard initialOutcome == nil else { return false }
            initialOutcome = .deadline
            return true
        }
        if resolved { initialSignal.signal() }
        return resolved
    }

    func waitForInitialOutcome() -> InitialOutcome {
        initialSignal.wait()
        return lock.withLock { initialOutcome! }
    }

    func beginGracePeriod() -> Bool {
        !lock.withLock { didTerminate }
    }

    func graceReached() {
        let shouldSignal = lock.withLock {
            guard !didTerminate, !graceExpired else { return false }
            graceExpired = true
            return true
        }
        if shouldSignal { graceSignal.signal() }
    }

    func waitForGraceOutcome() -> Bool {
        graceSignal.wait()
        return lock.withLock { graceExpired && !didTerminate }
    }

    func waitForTermination() {
        if lock.withLock({ didTerminate }) { return }
        terminationSignal.wait()
    }
}
