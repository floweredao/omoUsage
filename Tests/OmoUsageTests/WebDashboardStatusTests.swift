import Darwin
import Foundation
@preconcurrency import Network
import Testing
@testable import OmoUsage

@Suite
@MainActor
struct WebDashboardStatusTests {
    @Test
    func successfulStartPublishesStartingThenReadyWithEndpointDetails() throws {
        let listener = StatusRecordingWebDashboardListener()
        let statusStore = WebDashboardStatusStore(port: 7_827)
        let server = makeServer(listener: listener, statusStore: statusStore)

        #expect(statusStore.status.state == .disabled)
        try server.start()
        #expect(statusStore.status.state == .starting)

        listener.ready()

        #expect(statusStore.status.state == .ready)
        #expect(statusStore.status.url.absoluteString == "http://127.0.0.1:7827")
        #expect(statusStore.status.port == 7_827)
        #expect(statusStore.status.bindMode == .loopbackOnly)
    }

    @Test
    func occupiedPortPublishesCategorizedFailureWithoutRawError() throws {
        let listener = StatusRecordingWebDashboardListener()
        let statusStore = WebDashboardStatusStore(port: 49_117)
        let server = makeServer(listener: listener, statusStore: statusStore)

        try server.start()
        listener.fail(.portInUse(port: 49_117))

        #expect(
            statusStore.status.state
                == .failed(.portInUse(port: 49_117))
        )
        #expect(statusStore.status.failure?.category == .portInUse)
        #expect(statusStore.status.failure?.port == 49_117)
    }

    @Test
    func retryAfterPortReleaseReachesReady() throws {
        let listener = StatusRecordingWebDashboardListener()
        let statusStore = WebDashboardStatusStore(port: 49_118)
        let server = makeServer(listener: listener, statusStore: statusStore)

        try server.start()
        listener.fail(.portInUse(port: 49_118))
        #expect(listener.stopCount == 1)

        try server.retry()
        #expect(statusStore.status.state == .starting)
        listener.ready()

        #expect(statusStore.status.state == .ready)
        #expect(listener.startCount == 2)
    }

    @Test
    func repeatedStartAndRetryNeverCreateDuplicateListeners() throws {
        let listener = StatusRecordingWebDashboardListener()
        let statusStore = WebDashboardStatusStore(port: 49_119)
        let server = makeServer(listener: listener, statusStore: statusStore)

        try server.start()
        try server.start()
        try server.retry()
        #expect(listener.startCount == 1)

        listener.ready()
        try server.retry()
        #expect(listener.startCount == 1)
    }

    @Test
    func stopPublishesDisabledAndReleasesListener() throws {
        let listener = StatusRecordingWebDashboardListener()
        let statusStore = WebDashboardStatusStore(port: 49_120)
        let server = makeServer(listener: listener, statusStore: statusStore)

        try server.start()
        listener.ready()
        server.stop()
        server.stop()

        #expect(statusStore.status.state == .disabled)
        #expect(listener.stopCount == 1)
    }

    @Test
    func networkAddressCollisionMapsToPortInUseWithoutRawDetails() {
        let failure = WebDashboardListenerFailure.classify(
            NWError.posix(.EADDRINUSE),
            port: 49_121
        )

        #expect(failure == .portInUse(port: 49_121))
        #expect(failure.category == .portInUse)
    }

    @Test(.timeLimit(.minutes(1)))
    func realCollisionThenReleaseAndRetryUsesOneLoopbackListener() async throws {
        var holder = try openLoopbackSocket(port: 0)
        defer {
            if holder.descriptor >= 0 {
                close(holder.descriptor)
            }
        }
        let port = holder.port
        let listener = NWWebDashboardListener(port: port)
        let collisionStates = AsyncStream.makeStream(
            of: WebDashboardListenerState.self
        )
        try listener.start(
            response: { _ in Data() },
            stateChanged: { state in
                collisionStates.continuation.yield(state)
            }
        )
        let failure = try await requireFailure(collisionStates.stream)
        #expect(failure == .portInUse(port: port))

        close(holder.descriptor)
        holder.descriptor = -1

        let retryStates = AsyncStream.makeStream(
            of: WebDashboardListenerState.self
        )
        try listener.start(
            response: { _ in Data() },
            stateChanged: { state in
                retryStates.continuation.yield(state)
            }
        )
        try await requireDashboardReady(retryStates.stream)
        listener.stop()
    }

    @Test
    func fixturePortOverrideCannotAffectProductionOrSelectPrivilegedPort() {
        #expect(
            WebDashboardPortPolicy.resolve(environment: [
                "OMO_USAGE_WEB_PORT": "49122"
            ]) == WebDashboardPortPolicy.productionPort
        )
        #expect(
            WebDashboardPortPolicy.resolve(environment: [
                "OMO_USAGE_FIXTURE_MODE": "1",
                "OMO_USAGE_WEB_PORT": "49122"
            ]) == 49_122
        )
        #expect(
            WebDashboardPortPolicy.resolve(environment: [
                "OMO_USAGE_FIXTURE_MODE": "1",
                "OMO_USAGE_WEB_PORT": "80"
            ]) == WebDashboardPortPolicy.productionPort
        )
    }

    @Test
    func enablingTailscaleAccessPublishesRemoteDashboardURL()
        async throws
    {
        let service = StubTailscaleDashboardService(
            inspections: [
                .available(
                    host: "fixture-device.fixture-tailnet.ts.net"
                ),
                .ready(
                    host: "fixture-device.fixture-tailnet.ts.net"
                )
            ]
        )
        let accessStore = WebDashboardAccessStore(
            mode: .local(port: 7_827)
        )
        let statusStore = WebDashboardStatusStore(port: 7_827)
        statusStore.publish(.ready)
        let controller = TailscaleDashboardController(
            service: service,
            dashboardPort: 7_827,
            accessStore: accessStore,
            statusStore: statusStore
        )

        await controller.refresh()
        #expect(
            controller.state
                == .available(
                    host: "fixture-device.fixture-tailnet.ts.net"
                )
        )

        await controller.enable()

        #expect(
            controller.state
                == .ready(
                    host: "fixture-device.fixture-tailnet.ts.net"
                )
        )
        #expect(
            accessStore.mode
                == .tailscale(
                    host: "fixture-device.fixture-tailnet.ts.net",
                    httpsPort: 8_443
                )
        )
        #expect(
            statusStore.status.url.absoluteString
                == "https://fixture-device.fixture-tailnet.ts.net:8443"
        )
        #expect(service.enableCount == 1)
    }

    private func requireFailure(
        _ states: AsyncStream<WebDashboardListenerState>
    ) async throws -> WebDashboardListenerFailure {
        for await state in states {
            if case .failed(let failure) = state { return failure }
        }
        throw StatusTestFailure.streamEnded
    }

    private func requireDashboardReady(
        _ states: AsyncStream<WebDashboardListenerState>
    ) async throws {
        for await state in states {
            switch state {
            case .ready:
                return
            case .failed(let failure):
                throw failure
            }
        }
        throw StatusTestFailure.streamEnded
    }

    private func makeServer(
        listener: StatusRecordingWebDashboardListener,
        statusStore: WebDashboardStatusStore
    ) -> WebDashboardServer {
        WebDashboardServer(
            listener: listener,
            router: WebDashboardRouter(
                snapshotData: { Data() },
                indexHTML: Data()
            ),
            accessStore: WebDashboardAccessStore(
                mode: .local(port: statusStore.status.port)
            ),
            statusStore: statusStore
        )
    }
}

private final class StubTailscaleDashboardService:
    TailscaleDashboardServing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var inspections: [TailscaleDashboardInspection]
    private(set) var enableCount = 0

    init(inspections: [TailscaleDashboardInspection]) {
        self.inspections = inspections
    }

    func inspect(
        dashboardPort: UInt16
    ) throws -> TailscaleDashboardInspection {
        lock.withLock { inspections.removeFirst() }
    }

    func enable(dashboardPort: UInt16) throws {
        lock.withLock { enableCount += 1 }
    }

    func disable() throws {}
}

private enum StatusTestFailure: Error {
    case streamEnded
    case socketOperation(Int32)
}

private struct StatusTestSocket {
    var descriptor: Int32
    let port: UInt16
}

private func openLoopbackSocket(
    port: UInt16
) throws -> StatusTestSocket {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw StatusTestFailure.socketOperation(errno)
    }
    do {
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(descriptor, 1) == 0 else {
            throw StatusTestFailure.socketOperation(errno)
        }
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            throw StatusTestFailure.socketOperation(errno)
        }
        return StatusTestSocket(
            descriptor: descriptor,
            port: UInt16(bigEndian: boundAddress.sin_port)
        )
    } catch {
        close(descriptor)
        throw error
    }
}

private final class StatusRecordingWebDashboardListener:
    WebDashboardListening,
    @unchecked Sendable
{
    private var stateChanged:
        (@MainActor @Sendable (WebDashboardListenerState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        response: @escaping @Sendable (Data) -> Data,
        stateChanged: @escaping @MainActor @Sendable (
            WebDashboardListenerState
        ) -> Void
    ) throws {
        startCount += 1
        self.stateChanged = stateChanged
    }

    func stop() {
        stopCount += 1
        stateChanged = nil
    }

    @MainActor
    func ready() {
        stateChanged?(.ready)
    }

    @MainActor
    func fail(_ failure: WebDashboardListenerFailure) {
        stateChanged?(.failed(failure))
    }
}
