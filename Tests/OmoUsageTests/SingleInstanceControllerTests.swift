import Foundation
import Testing
@testable import OmoUsage

@Suite(.serialized)
struct SingleInstanceControllerTests {
    @Test(.timeLimit(.minutes(1)))
    func ownerReceivesActivationAndContenderExits() async throws {
        let fixture = try SingleInstanceFixture()
        defer { fixture.cleanup() }

        let owner = try fixture.launch()
        let ownerEvent = try await owner.nextEvent()
        #expect(ownerEvent == "owner")

        let metadata = try String(contentsOf: fixture.lockURL, encoding: .utf8)
        #expect(metadata == "\(owner.processIdentifier)\n")

        let contender = try fixture.launch()
        let contenderEvent = try await contender.nextEvent()
        #expect(contenderEvent == "contender")
        #expect(try await contender.terminationStatus() == 0)

        let activationEvent = try await owner.nextEvent()
        #expect(activationEvent == "activation")
        #expect(try await owner.terminationStatus() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleLivePIDMetadataNeverOverridesAdvisoryLockOwnership() async throws {
        let fixture = try SingleInstanceFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: fixture.lockURL,
            atomically: true,
            encoding: .utf8
        )

        let owner = try fixture.launch()
        #expect(try await owner.nextEvent() == "owner")

        let contender = try fixture.launch()
        #expect(try await contender.nextEvent() == "contender")
        #expect(try await contender.terminationStatus() == 0)
        #expect(try await owner.nextEvent() == "activation")
        #expect(try await owner.terminationStatus() == 0)
    }

    @Test
    func pendingFixtureEventWaitIsCancellationResponsive() async {
        let events = SingleInstanceFixtureEvents()
        let waiter = Task {
            try await events.nextEvent()
        }
        waiter.cancel()
        events.finishOutput()
        events.terminate(status: 0)

        do {
            _ = try await waiter.value
            Issue.record("Cancelled fixture event wait unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("Cancelled fixture event wait returned \(type(of: error))")
        }
    }

    @Test
    func pendingFixtureTerminationWaitIsCancellationResponsive() async {
        let events = SingleInstanceFixtureEvents()
        let waiter = Task {
            try await events.terminationStatus()
        }
        waiter.cancel()
        events.terminate(status: 0)

        do {
            _ = try await waiter.value
            Issue.record("Cancelled fixture termination wait unexpectedly succeeded")
        } catch is CancellationError {
        } catch {
            Issue.record("Cancelled termination wait returned \(type(of: error))")
        }
    }

    @Test @MainActor
    func productionNamespaceAndLockLocationAreAppSpecific() throws {
        let lockURL = try SingleInstanceController.defaultLockURL(
            fileManager: .default
        )

        #expect(
            SingleInstanceController.activationNotificationName.rawValue
                == "com.omo.usage.single-instance.activate"
        )
        #expect(lockURL.lastPathComponent == "interactive-instance.lock")
        #expect(lockURL.deletingLastPathComponent().lastPathComponent == "OmoUsage")
    }
}

private final class SingleInstanceFixture: @unchecked Sendable {
    let directory: URL
    let lockURL: URL
    private let notificationName: String
    private let executableURL: URL
    private let lock = NSLock()
    private var processes: [SingleInstanceFixtureProcess] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "SingleInstanceControllerTests-\(UUID().uuidString)"
        )
        lockURL = directory.appending(path: "interactive-instance.lock")
        notificationName = "com.omo.usage.tests.\(UUID().uuidString).activate"
        executableURL = try Self.productExecutableURL()
    }

    func launch() throws -> SingleInstanceFixtureProcess {
        let fixtureProcess = try SingleInstanceFixtureProcess(
            executableURL: executableURL,
            environment: [
                "OMO_USAGE_SINGLE_INSTANCE_FIXTURE": "1",
                "OMO_USAGE_SINGLE_INSTANCE_LOCK_PATH": lockURL.path,
                "OMO_USAGE_SINGLE_INSTANCE_NOTIFICATION": notificationName
            ]
        )
        lock.withLock {
            processes.append(fixtureProcess)
        }
        return fixtureProcess
    }

    func cleanup() {
        let running = lock.withLock { processes }
        for process in running where process.isRunning {
            process.terminate()
        }
        for process in running {
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func productExecutableURL() throws -> URL {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = repositoryRoot
            .appending(path: ".build/debug/OmoUsage")
        guard FileManager.default.isExecutableFile(
            atPath: executable.path
        ) else {
            throw SingleInstanceFixtureError.productExecutableNotFound
        }
        return executable
    }
}

private final class SingleInstanceFixtureProcess: @unchecked Sendable {
    private let process: Process
    private let events = SingleInstanceFixtureEvents()
    private let output: Pipe

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(executableURL: URL, environment: [String: String]) throws {
        process = Process()
        output = Pipe()
        process.executableURL = executableURL
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, fixture in fixture }
        )
        process.standardOutput = output
        process.standardError = output

        let events = self.events
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                events.finishOutput()
            } else {
                events.receive(data)
            }
        }
        process.terminationHandler = { process in
            events.terminate(status: process.terminationStatus)
        }
        try process.run()
    }

    func nextEvent() async throws -> String {
        try await events.nextEvent()
    }

    func terminationStatus() async throws -> Int32 {
        try await events.terminationStatus()
    }

    func terminate() {
        process.terminate()
    }

    func waitUntilExit() {
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
    }
}

private final class SingleInstanceFixtureEvents: @unchecked Sendable {
    private struct EventWaiter {
        let id: UUID
        let continuation: CheckedContinuation<String, any Error>
    }

    private struct TerminationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Int32, any Error>
    }

    private let lock = NSLock()
    private var bufferedData = Data()
    private var lines: [String] = []
    private var status: Int32?
    private var outputFinished = false
    private var eventWaiter: EventWaiter?
    private var terminationWaiter: TerminationWaiter?

    func receive(_ data: Data) {
        let delivery: (CheckedContinuation<String, any Error>, String)? =
            lock.withLock {
                bufferedData.append(data)
                while let newline = bufferedData.firstIndex(of: 0x0A) {
                    let lineData = bufferedData[..<newline]
                    bufferedData.removeSubrange(...newline)
                    if let line = String(data: lineData, encoding: .utf8) {
                        lines.append(line)
                    }
                }
                guard let eventWaiter, !lines.isEmpty else { return nil }
                self.eventWaiter = nil
                return (eventWaiter.continuation, lines.removeFirst())
            }
        if let (continuation, line) = delivery {
            continuation.resume(returning: line)
        }
    }

    func finishOutput() {
        let failure: (
            CheckedContinuation<String, any Error>,
            SingleInstanceFixtureError
        )? = lock.withLock {
            outputFinished = true
            guard
                lines.isEmpty,
                let status,
                let eventWaiter
            else {
                return nil
            }
            self.eventWaiter = nil
            return (
                eventWaiter.continuation,
                .exitedBeforeEvent(status)
            )
        }
        if let (continuation, error) = failure {
            continuation.resume(throwing: error)
        }
    }

    func terminate(status: Int32) {
        let deliveries: (
            event: (
                CheckedContinuation<String, any Error>,
                SingleInstanceFixtureError
            )?,
            termination: CheckedContinuation<Int32, any Error>?
        ) = lock.withLock {
            self.status = status
            let eventDelivery: (
                CheckedContinuation<String, any Error>,
                SingleInstanceFixtureError
            )?
            if outputFinished, lines.isEmpty, let eventWaiter {
                self.eventWaiter = nil
                eventDelivery = (
                    eventWaiter.continuation,
                    .exitedBeforeEvent(status)
                )
            } else {
                eventDelivery = nil
            }
            let terminationDelivery = terminationWaiter?.continuation
            terminationWaiter = nil
            return (eventDelivery, terminationDelivery)
        }
        if let (continuation, error) = deliveries.event {
            continuation.resume(throwing: error)
        }
        deliveries.termination?.resume(returning: status)
    }

    func nextEvent() async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<String, any Error>? = lock.withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if !lines.isEmpty {
                        return .success(lines.removeFirst())
                    }
                    if outputFinished, let status {
                        return .failure(
                            SingleInstanceFixtureError
                                .exitedBeforeEvent(status)
                        )
                    }
                    precondition(eventWaiter == nil)
                    eventWaiter = EventWaiter(
                        id: id,
                        continuation: continuation
                    )
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancelEventWaiter(id: id)
        }
    }

    func terminationStatus() async throws -> Int32 {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Int32, any Error>? = lock.withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if let status {
                        return .success(status)
                    }
                    precondition(terminationWaiter == nil)
                    terminationWaiter = TerminationWaiter(
                        id: id,
                        continuation: continuation
                    )
                    return nil
                }
                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancelTerminationWaiter(id: id)
        }
    }

    private func cancelEventWaiter(id: UUID) {
        let continuation: CheckedContinuation<String, any Error>? =
            lock.withLock {
                guard eventWaiter?.id == id else { return nil }
                let continuation = eventWaiter?.continuation
                eventWaiter = nil
                return continuation
            }
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelTerminationWaiter(id: UUID) {
        let continuation: CheckedContinuation<Int32, any Error>? =
            lock.withLock {
                guard terminationWaiter?.id == id else { return nil }
                let continuation = terminationWaiter?.continuation
                terminationWaiter = nil
                return continuation
            }
        continuation?.resume(throwing: CancellationError())
    }
}

private enum SingleInstanceFixtureError: Error {
    case productExecutableNotFound
    case exitedBeforeEvent(Int32)
}
