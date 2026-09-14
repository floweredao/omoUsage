import AppKit
import Foundation
import Testing
@testable import OmoUsage

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct TailscaleDashboardRecoveryTests {
    private let host = "recovery-device.fixture-tailnet.ts.net"
    private let port: UInt16 = 7_827

    @Test
    func failedFirstInspectionRecoversGatewayWithoutManualRetry() async throws {
        let service = RecoveryService([
            .failure(.commandFailed), .success(.ready(host: host))
        ])
        let clock = RecoveryClock()
        let (controller, access, _) = makeController(service, clock: clock)
        let gateway = WebDashboardAccessGateway(
            accessStore: access,
            router: WebDashboardRouter(
                snapshotData: { Data("{}".utf8) },
                indexHTML: Data("fixture".utf8)
            )
        )
        let request = WebDashboardHTTPRequest(
            method: "GET", path: "/",
            headers: ["host": "\(host):8443"], body: Data()
        )
        let monitoring = controller.startMonitoring()
        defer { controller.stopMonitoring() }

        #expect(gateway.response(request: request).statusCode == 403)
        #expect(try await clock.delays.next() == .seconds(1))
        clock.advance()
        await monitoring.value

        #expect(gateway.response(request: request).statusCode == 200)
        #expect(service.inspectionCount == 2)
        #expect(service.mutations.isEmpty)
    }

    @Test
    func initialInspectionExportsLocalURLBeforeRemoteRecovery() async throws {
        let service = RecoveryService([
            .success(.signedOut), .success(.ready(host: host))
        ])
        let clock = RecoveryClock()
        let (controller, access, _) = makeController(service, clock: clock)
        let urlFile = FileManager.default.temporaryDirectory.appending(
            path: "recovery-url-\(UUID().uuidString).txt"
        )
        var exportResult: Result<Void, any Error>?
        var exports = 0
        let monitoring = controller.startMonitoring(onInitialInspection: {
            exports += 1
            exportResult = Result {
                try FixtureWebDashboardURLExporter.exportIfRequested(
                    accessStore: access,
                    environment: [
                        "OMO_USAGE_FIXTURE_MODE": "1",
                        "OMO_USAGE_DASHBOARD_URL_FILE": urlFile.path
                    ]
                )
            }
        })
        defer {
            controller.stopMonitoring()
            try? FileManager.default.removeItem(at: urlFile)
        }
        #expect(try await clock.delays.next() == .seconds(1))
        try #require(exportResult).get()
        #expect(try String(contentsOf: urlFile, encoding: .utf8)
            == "http://127.0.0.1:7827\n")
        clock.advance()
        await monitoring.value
        #expect(exports == 1)
    }

    @Test
    func retriesRemainCappedWithoutExhaustingOrMutatingServe() async throws {
        let delays = [1, 2, 4, 8, 16, 30, 60, 60, 60]
        let service = RecoveryService(
            delays.map { _ in .success(.signedOut) }
                + [.success(.ready(host: host))]
        )
        let clock = RecoveryClock()
        let (controller, _, _) = makeController(service, clock: clock)
        let monitoring = controller.startMonitoring()
        defer { controller.stopMonitoring() }

        for seconds in delays {
            #expect(try await clock.delays.next() == .seconds(seconds))
            clock.advance()
        }
        await monitoring.value

        #expect(controller.state == .ready(host: host))
        #expect(service.inspectionCount == 10)
        #expect(service.mutations.isEmpty)
        #expect(clock.requested.count == delays.count)
    }

    @Test
    func repeatedStartsAndConcurrentRefreshesShareOneInspection() async throws {
        let service = RecoveryService(
            [.success(.ready(host: host))], blocked: [1]
        )
        let (controller, _, _) = makeController(service)
        let monitoring = controller.startMonitoring()
        defer { controller.stopMonitoring(); service.release(1) }
        #expect(try await service.entries.next() == 1)
        let repeated = controller.startMonitoring()
        let started = RecoverySignal<Void>()
        let first = Task { started.send(()); await controller.refresh() }
        let second = Task { started.send(()); await controller.refresh() }
        try await started.next()
        try await started.next()
        service.release(1)
        await monitoring.value
        await repeated.value
        await first.value
        await second.value

        #expect(service.inspectionCount == 1)
        #expect(service.maximumConcurrentOperations == 1)
    }

    @Test
    func newerDisableIntentSupersedesAnOlderInspection() async throws {
        let service = RecoveryService([
            .success(.ready(host: host)),
            .success(.ready(host: "stale-device.fixture-tailnet.ts.net")),
            .success(.available(host: host))
        ], blocked: [2])
        let (controller, access, _) = makeController(service)
        await controller.refresh()
        #expect(try await service.entries.next() == 1)
        let old = Task { await controller.refresh() }
        defer { service.release(2) }
        #expect(try await service.entries.next() == 2)
        let started = RecoverySignal<Void>()
        let manual = Task { started.send(()); await controller.disable() }
        try await started.next()
        service.release(2)
        await old.value
        await manual.value

        #expect(service.mutations == ["disable"])
        #expect(service.maximumConcurrentOperations == 1)
        #expect(access.mode == .local(port: port))
        #expect(controller.state == .available(host: host))
    }

    @Test
    func newerEnableIntentSupersedesAnOlderInspection() async throws {
        let service = RecoveryService([
            .success(.available(host: host)),
            .success(.available(host: host)),
            .success(.ready(host: host))
        ], blocked: [2])
        let (controller, access, _) = makeController(service)
        await controller.refresh()
        #expect(try await service.entries.next() == 1)
        let old = Task { await controller.refresh() }
        defer { service.release(2) }
        #expect(try await service.entries.next() == 2)
        let started = RecoverySignal<Void>()
        let manual = Task { started.send(()); await controller.enable() }
        try await started.next()
        service.release(2)
        await old.value
        await manual.value

        #expect(service.mutations == ["enable"])
        #expect(service.maximumConcurrentOperations == 1)
        #expect(access.mode == .tailscale(host: host, httpsPort: 8_443))
        #expect(controller.state == .ready(host: host))
    }

    @Test
    func shutdownPreventsStalePublicationAndRetry() async throws {
        let service = RecoveryService(
            [.success(.ready(host: host))], blocked: [1]
        )
        let clock = RecoveryClock()
        let (controller, access, diagnostics) = makeController(service, clock: clock)
        let monitoring = controller.startMonitoring()
        defer { service.release(1) }
        #expect(try await service.entries.next() == 1)
        controller.stopMonitoring()
        service.release(1)
        await monitoring.value
        controller.systemDidWake()

        #expect(access.mode == .local(port: port))
        #expect(controller.state == .checking)
        #expect(clock.requested.isEmpty)
        #expect(diagnostics.events.isEmpty)
        #expect(service.inspectionCount == 1)
    }

    @Test
    func cancelledCallerCannotPublishDetachedInspection() async throws {
        let service = RecoveryService(
            [.success(.ready(host: host))], blocked: [1]
        )
        let (controller, access, diagnostics) = makeController(service)
        let caller = Task { await controller.refresh() }
        defer { service.release(1) }
        #expect(try await service.entries.next() == 1)
        caller.cancel()
        service.release(1)
        await caller.value

        #expect(access.mode == .local(port: port))
        #expect(controller.state == .checking)
        #expect(diagnostics.events.isEmpty)
    }

    @Test
    func cancelledSharedWaiterDoesNotPermanentlyStopRecovery() async throws {
        let service = RecoveryService(
            [.success(.ready(host: host)), .success(.ready(host: host))],
            blocked: [1]
        )
        let clock = RecoveryClock()
        let (controller, access, _) = makeController(service, clock: clock)
        let monitoring = controller.startMonitoring()
        defer { controller.stopMonitoring(); service.release(1) }
        #expect(try await service.entries.next() == 1)
        let joined = RecoverySignal<Void>()
        let waiter = Task {
            joined.send(())
            await controller.refresh()
        }
        try await joined.next()
        waiter.cancel()
        service.release(1)
        await waiter.value

        #expect(try await clock.delays.next() == .seconds(1))
        #expect(access.mode == .local(port: port))
        clock.advance()
        await monitoring.value
        #expect(access.mode == .tailscale(host: host, httpsPort: 8_443))
        #expect(service.inspectionCount == 2)
        #expect(service.maximumConcurrentOperations == 1)
        #expect(service.mutations.isEmpty)
    }

    @Test
    func confirmedOfflineStatusRevokesPreviouslyAcceptedRemoteHost() async {
        let service = RecoveryService([
            .success(.ready(host: host)), .failure(.offline)
        ])
        let (controller, access, diagnostics) = makeController(service)
        await controller.refresh()
        await controller.refresh()

        #expect(access.mode == .local(port: port))
        #expect(controller.state == .failed(.offline))
        #expect(diagnostics.events.last?.status == .transient)
    }

    @Test
    func wakeRechecksReadyStateAndRestartsRecovery() async throws {
        let service = RecoveryService([
            .success(.ready(host: host)), .success(.signedOut),
            .success(.ready(host: host))
        ])
        let clock = RecoveryClock()
        let (controller, access, _) = makeController(service, clock: clock)
        let notifications = NotificationCenter()
        await controller.startMonitoring(wakeNotifications: notifications).value
        defer { controller.stopMonitoring() }
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(try await clock.delays.next() == .seconds(1))
        #expect(access.mode == .local(port: port))
        let monitoring = controller.startMonitoring()
        clock.advance()
        await monitoring.value

        #expect(access.mode == .tailscale(host: host, httpsPort: 8_443))
        #expect(service.inspectionCount == 3)
        #expect(service.mutations.isEmpty)
    }

    @Test
    func manualNonreadyInspectionRestartsAnIdleRecoveryLifetime() async throws {
        let service = RecoveryService([
            .success(.ready(host: host)), .success(.signedOut),
            .success(.signedOut), .success(.ready(host: host))
        ])
        let clock = RecoveryClock()
        let (controller, _, _) = makeController(service, clock: clock)
        await controller.startMonitoring().value
        defer { controller.stopMonitoring() }
        await controller.refresh()
        #expect(try await clock.delays.next() == .seconds(1))
        let monitoring = controller.startMonitoring()
        clock.advance()
        #expect(try await clock.delays.next() == .seconds(2))
        clock.advance()
        await monitoring.value
        #expect(controller.state == .ready(host: host))
        #expect(service.mutations.isEmpty)
    }

    @Test(arguments: [true, false])
    func shutdownRejectsSubsequentManualStateChanges(enable: Bool) async {
        let inspection: TailscaleDashboardInspection = enable
            ? .available(host: host) : .ready(host: host)
        let service = RecoveryService([.success(inspection)])
        let (controller, _, _) = makeController(service)
        await controller.refresh()
        let acceptedState = controller.state
        controller.stopMonitoring()
        if enable { await controller.enable() } else { await controller.disable() }
        await controller.refresh()

        #expect(controller.state == acceptedState)
        #expect(service.inspectionCount == 1)
        #expect(service.mutations.isEmpty)
    }

    @Test
    func shutdownCancelsPendingRetryWithoutAnotherInspection() async throws {
        let service = RecoveryService([.success(.signedOut)])
        let clock = RecoveryClock()
        let (controller, _, _) = makeController(service, clock: clock)
        let monitoring = controller.startMonitoring()
        #expect(try await clock.delays.next() == .seconds(1))
        controller.stopMonitoring()
        await monitoring.value
        clock.advance()

        #expect(service.inspectionCount == 1)
        #expect(clock.requested == [.seconds(1)])
    }

    @Test
    func cancelledManualEnableDoesNotStartVerificationInspection() async throws {
        let service = RecoveryService(
            [.success(.available(host: host)), .success(.ready(host: host))],
            blockMutation: true
        )
        let (controller, access, _) = makeController(service)
        await controller.refresh()
        let caller = Task { await controller.enable() }
        defer { service.releaseMutation() }
        try await service.mutationEntries.next()
        caller.cancel()
        service.releaseMutation()
        await caller.value

        #expect(service.inspectionCount == 1)
        #expect(access.mode == .local(port: port))
    }

    @Test
    func failureDiagnosticsAreCategorizedDeduplicatedAndRedacted() async throws {
        let service = RecoveryService([
            .failure(.commandFailed), .failure(.commandFailed),
            .failure(.timedOut), .failure(.invalidStatus),
            .success(.signedOut), .failure(.offline),
            .success(.ready(host: host))
        ])
        let (controller, _, diagnostics) = makeController(service)
        for _ in 0..<7 { await controller.refresh() }

        #expect(diagnostics.events.map(\.status) == [
            .failed, .timedOut, .invalidResponse,
            .authenticationRequired, .transient, .recovered
        ])
        #expect(diagnostics.events.allSatisfy { $0.category == .tailscaleDashboard })
        let exported = String(decoding: try diagnostics.exportData(), as: UTF8.self)
        #expect(!exported.contains(host))
        #expect(!exported.contains("/"))
    }

    @Test
    func failedInspectionRetainsAcceptedHostUntilSuccessfulNonreadyResult() async {
        let service = RecoveryService([
            .success(.ready(host: host)), .failure(.commandFailed),
            .success(.signedOut)
        ])
        let (controller, access, _) = makeController(service)
        await controller.refresh()
        await controller.refresh()
        #expect(access.mode == .tailscale(host: host, httpsPort: 8_443))
        await controller.refresh()
        #expect(access.mode == .local(port: port))
    }

    @Test
    func cancelledCLIInspectionDoesNotStartServeStatusCommand() async throws {
        let commands = RecoveryCommands()
        let service = TailscaleCLIService(
            executable: URL(filePath: "/fixture/tailscale"),
            execute: { _, arguments in
                commands.record(arguments)
                if arguments.first == "status" {
                    commands.started.send(())
                    guard commands.gate.wait(timeout: .now() + 5) == .success else {
                        throw RecoveryTestError.signalTimedOut
                    }
                    return TailscaleCommandResult(
                        status: 0,
                        standardOutput: Data("""
                        {"BackendState":"Running","Self":{"Online":true,"DNSName":"recovery-device.fixture-tailnet.ts.net."}}
                        """.utf8),
                        standardError: Data()
                    )
                }
                return TailscaleCommandResult(
                    status: 0, standardOutput: Data("{}".utf8), standardError: Data()
                )
            }
        )
        let caller = Task.detached {
            try service.inspect(dashboardPort: 7_827)
        }
        defer { commands.gate.signal() }
        try await commands.started.next()
        caller.cancel()
        commands.gate.signal()
        _ = await caller.result

        #expect(commands.arguments.count == 1)
    }

    @Test(arguments: [Int32(1), Int32(0)])
    func cliFailureAndOfflineStatusAreNotReportedAsSignedOut(exitCode: Int32) throws {
        let service = TailscaleCLIService(
            executable: URL(filePath: "/fixture/tailscale"),
            execute: { _, _ in
                TailscaleCommandResult(
                    status: exitCode,
                    standardOutput: Data("""
                    {"BackendState":"Running","Self":{"Online":false,"DNSName":"recovery-device.fixture-tailnet.ts.net."}}
                    """.utf8),
                    standardError: Data("fixture-token /fixture/private-path".utf8)
                )
            }
        )
        #expect(throws: exitCode == 0
            ? TailscaleDashboardFailure.offline : .commandFailed) {
            try service.inspect(dashboardPort: port)
        }
    }

    @Test
    func cliTimeoutRetainsItsTypedCategory() async {
        let service = TailscaleCLIService(
            executable: URL(filePath: "/fixture/tailscale"),
            execute: { _, _ in throw BoundedProcessError.timedOut }
        )
        let (controller, _, diagnostics) = makeController(service)
        await controller.refresh()
        #expect(controller.state == .failed(.timedOut))
        #expect(diagnostics.events.map(\.status) == [.timedOut])
    }

    private func makeController(
        _ service: any TailscaleDashboardServing,
        clock: RecoveryClock = RecoveryClock()
    ) -> (TailscaleDashboardController, WebDashboardAccessStore, DiagnosticStore) {
        let access = WebDashboardAccessStore(mode: .local(port: port))
        let diagnostics = DiagnosticStore()
        return (
            TailscaleDashboardController(
                service: service, dashboardPort: port, accessStore: access,
                statusStore: WebDashboardStatusStore(port: port),
                diagnostics: diagnostics,
                retryWait: { try await clock.wait($0) }
            ),
            access,
            diagnostics
        )
    }
}

private enum RecoveryTestError: Error {
    case signalTimedOut
}

private struct RecoverySignal<Value: Sendable>: Sendable {
    private let pair = AsyncStream.makeStream(of: Value.self)

    func send(_ value: Value) { pair.continuation.yield(value) }

    func next() async throws -> Value {
        // The suite's time limit cancels a blocked stream wait.
        var iterator = pair.stream.makeAsyncIterator()
        guard let value = await iterator.next() else {
            throw RecoveryTestError.signalTimedOut
        }
        return value
    }
}

@MainActor
private final class RecoveryClock {
    let delays = RecoverySignal<Duration>()
    private var continuation: AsyncStream<Void>.Continuation?
    private(set) var requested: [Duration] = []

    func wait(_ duration: Duration) async throws {
        let pair = AsyncStream.makeStream(of: Void.self)
        continuation = pair.continuation
        requested.append(duration)
        delays.send(duration)
        var iterator = pair.stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func advance() { continuation?.yield(()) }
}

private final class RecoveryService: TailscaleDashboardServing, @unchecked Sendable {
    private let lock = NSLock()
    private let results: [Result<TailscaleDashboardInspection, TailscaleDashboardFailure>]
    private let gates: [Int: DispatchSemaphore]
    private let mutationGate: DispatchSemaphore?
    let entries = RecoverySignal<Int>()
    let mutationEntries = RecoverySignal<Void>()
    private var count = 0
    private var active = 0
    private var maximum = 0
    private var changes: [String] = []

    init(
        _ results: [Result<TailscaleDashboardInspection, TailscaleDashboardFailure>],
        blocked: Set<Int> = [],
        blockMutation: Bool = false
    ) {
        self.results = results
        gates = Dictionary(uniqueKeysWithValues: blocked.map {
            ($0, DispatchSemaphore(value: 0))
        })
        mutationGate = blockMutation ? DispatchSemaphore(value: 0) : nil
    }

    var inspectionCount: Int { lock.withLock { count } }
    var maximumConcurrentOperations: Int { lock.withLock { maximum } }
    var mutations: [String] { lock.withLock { changes } }

    func release(_ index: Int) { gates[index]?.signal() }
    func releaseMutation() { mutationGate?.signal() }

    func inspect(dashboardPort: UInt16) throws -> TailscaleDashboardInspection {
        let index = lock.withLock {
            count += 1
            active += 1
            maximum = max(maximum, active)
            return count
        }
        defer { lock.withLock { active -= 1 } }
        entries.send(index)
        if let gate = gates[index],
            gate.wait(timeout: .now() + 5) != .success {
            throw RecoveryTestError.signalTimedOut
        }
        return try results[min(index - 1, results.count - 1)].get()
    }

    func enable(dashboardPort: UInt16) throws { try recordMutation("enable") }
    func disable() throws { try recordMutation("disable") }

    private func recordMutation(_ name: String) throws {
        lock.withLock {
            maximum = max(maximum, active + 1)
            changes.append(name)
        }
        mutationEntries.send(())
        if let mutationGate,
            mutationGate.wait(timeout: .now() + 5) != .success {
            throw RecoveryTestError.signalTimedOut
        }
    }
}

private final class RecoveryCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let started = RecoverySignal<Void>()
    let gate = DispatchSemaphore(value: 0)

    var arguments: [[String]] { lock.withLock { recorded } }
    func record(_ arguments: [String]) { lock.withLock { recorded.append(arguments) } }
}
