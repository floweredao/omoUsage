import Foundation
import Testing
@testable import OmoUsage

@Suite(.serialized)
struct ProviderHTTPRetryTests {
    @Test
    func retryAfterDeltaSecondsIsHonored() async throws {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(429, headers: ["Retry-After": "3"]),
                .json(200, #"{"ok":true}"#)
            ]
        )

        let data = try await fixture.http.data(
            for: fixture.request,
            provider: .codex
        )

        #expect(data == Data(#"{"ok":true}"#.utf8))
        #expect(fixture.requestCount == 2)
        #expect(fixture.sleeps == [3])
    }

    @Test
    func retryAfterHTTPDateIsHonored() async throws {
        let wallNow = Date(timeIntervalSince1970: 1_785_801_600)
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(
                    429,
                    headers: ["Retry-After": "Tue, 04 Aug 2026 00:00:05 GMT"]
                ),
                .json(200, #"{"ok":true}"#)
            ],
            wallNow: wallNow
        )

        _ = try await fixture.http.data(
            for: fixture.request,
            provider: .codex
        )

        #expect(fixture.requestCount == 2)
        #expect(fixture.sleeps == [5])
    }

    @Test
    func retryAfterBeyondOperationBudgetSurfacesServerStatus() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(429, headers: ["Retry-After": "60"]),
                .json(200, #"{"ok":true}"#)
            ]
        )

        await #expect(
            throws: ProviderTransportError.requestFailed(.codex, 429)
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 1)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test
    func retries500And503ThenSucceedsWithExponentialJitter() async throws {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(500),
                .response(503),
                .json(200, #"{"ok":true}"#)
            ],
            randomValues: [0.5, 0.25]
        )

        _ = try await fixture.http.data(
            for: fixture.request,
            provider: .codex
        )

        #expect(fixture.requestCount == 3)
        #expect(fixture.sleeps == [0.5, 0.5])
    }

    @Test
    func retriesTransientTransportFailure() async throws {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .transport(.networkConnectionLost),
                .json(200, #"{"ok":true}"#)
            ],
            randomValues: [1]
        )

        _ = try await fixture.http.data(
            for: fixture.request,
            provider: .cursor
        )

        #expect(fixture.requestCount == 2)
        #expect(fixture.sleeps == [1])
    }

    @Test
    func transportExhaustionIsBoundedAndTyped() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .transport(.networkConnectionLost),
                .transport(.networkConnectionLost),
                .transport(.networkConnectionLost)
            ],
            randomValues: [1, 1]
        )

        await #expect(
            throws: ProviderTransportError.transientTransport(
                .cursor,
                .networkConnectionLost
            )
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .cursor
            )
        }
        #expect(fixture.requestCount == 3)
        #expect(fixture.sleeps == [1, 2])
    }

    @Test
    func exhaustionIsBoundedAndTyped() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [.response(503), .response(503), .response(503)],
            randomValues: [1, 1]
        )

        await #expect(
            throws: ProviderTransportError.requestFailed(.codex, 503)
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 3)
        #expect(fixture.sleeps == [1, 2])
    }

    @Test(arguments: [400, 422])
    func permanentClientFailuresDoNotRetry(status: Int) async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [.response(status), .json(200, #"{"ok":true}"#)]
        )

        await #expect(
            throws: ProviderTransportError.requestFailed(.codex, status)
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 1)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test(arguments: [401, 403])
    func authenticationFailuresDoNotRetry(status: Int) async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [.response(status), .json(200, #"{"ok":true}"#)]
        )

        await #expect(
            throws: ProviderTransportError.authenticationRequired(.claude)
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .claude
            )
        }
        #expect(fixture.requestCount == 1)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test(arguments: [408, 429, 500, 599])
    func retryableStatusesAreBounded(status: Int) async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [.response(status), .json(200, #"{"ok":true}"#)],
            randomValues: [0]
        )

        _ = try? await fixture.http.data(
            for: fixture.request,
            provider: .codex
        )

        #expect(fixture.requestCount == 2)
    }

    @Test(arguments: ["text/html", "application/xml"])
    func wrongJSONMIMEDoesNotRetry(contentType: String) async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(
                    200,
                    headers: ["Content-Type": contentType],
                    body: Data(#"{"ok":true}"#.utf8)
                ),
                .json(200, #"{"ok":true}"#)
            ]
        )

        await #expect(
            throws: ProviderTransportError.invalidContentType(
                .codex,
                contentType
            )
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 1)
    }

    @Test
    func missingJSONMIMEDoesNotRetry() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(200, body: Data(#"{"ok":true}"#.utf8)),
                .json(200, #"{"ok":true}"#)
            ]
        )

        await #expect(
            throws: ProviderTransportError.invalidContentType(.codex, nil)
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 1)
    }

    @Test
    func vendorJSONMIMEAndParametersAreAccepted() async throws {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(
                    200,
                    headers: [
                        "Content-Type": "application/problem+json; charset=utf-8"
                    ],
                    body: Data(#"{"ok":true}"#.utf8)
                )
            ]
        )

        _ = try await fixture.http.data(
            for: fixture.request,
            provider: .codex
        )

        #expect(fixture.requestCount == 1)
    }

    @Test
    func oversizedBodyDoesNotRetry() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(
                    200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(repeating: 0x20, count: 17)
                ),
                .json(200, #"{"ok":true}"#)
            ],
            maximumResponseBytes: 16
        )

        await #expect(
            throws: ProviderTransportError.responseTooLarge(
                .codex,
                limit: 16
            )
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func oversizedStreamStopsBeforeTheResponseFinishes() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [.stream],
            maximumResponseBytes: 16
        )
        defer { fixture.finishStreamingIfNeeded() }

        let requestTask = Task {
            await #expect(
                throws: ProviderTransportError.responseTooLarge(
                    .codex,
                    limit: 16
                )
            ) {
                try await fixture.http.data(
                    for: fixture.request,
                    provider: .codex
                )
            }
        }

        await fixture.waitUntilStarted()
        fixture.send(Data(repeating: 0x20, count: 16))
        fixture.send(Data([0x20]))

        await fixture.waitUntilStopped()
        #expect(!fixture.finishedBeforeStop)

        fixture.finishStreamingIfNeeded()
        _ = await requestTask.value
    }

    @Test
    func malformedJSONDoesNotRetry() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .json(200, "{"),
                .json(200, #"{"ok":true}"#)
            ]
        )

        await #expect(
            throws: ProviderTransportError.invalidJSON(.codex)
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 1)
    }

    @Test
    func cancellationIsNeverRetried() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [.transport(.cancelled), .json(200, #"{"ok":true}"#)]
        )

        await #expect(throws: CancellationError.self) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 1)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test
    func explicitlySafePOSTOperationRetriesWithTheSameBody() async throws {
        let body = Data(#"{"query":"usage"}"#.utf8)
        let fixture = ProviderHTTPRetryFixture(
            steps: [.response(503), .json(200, #"{"ok":true}"#)],
            method: "POST",
            body: body,
            randomValues: [0]
        )

        _ = try await fixture.http.data(
            for: fixture.request,
            provider: .devin,
            operation: .safe
        )

        #expect(fixture.requestCount == 2)
        #expect(fixture.requests.compactMap(requestBodyData) == [body, body])
    }

    @Test
    func unsafeOperationIsNeverRetried() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [.response(503), .json(200, #"{"ok":true}"#)],
            method: "POST"
        )

        await #expect(
            throws: ProviderTransportError.requestFailed(.claude, 503)
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .claude,
                operation: .unsafe
            )
        }
        #expect(fixture.requestCount == 1)
        #expect(fixture.sleeps.isEmpty)
    }

    @Test
    func oneOperationDeadlineBoundsAllAttempts() async {
        let fixture = ProviderHTTPRetryFixture(
            steps: [.response(503), .response(503), .json(200, #"{"ok":true}"#)],
            operationTimeout: 1.5,
            randomValues: [1, 1]
        )

        await #expect(
            throws: ProviderTransportError.operationTimedOut(.codex)
        ) {
            try await fixture.http.data(
                for: fixture.request,
                provider: .codex
            )
        }
        #expect(fixture.requestCount == 2)
        #expect(fixture.sleeps == [1])
        #expect(fixture.monotonicTime == 1)
        #expect(fixture.requestTimeouts == [1.5, 0.5])
    }

    @Test
    func backoffAttemptResetsAfterSuccess() async throws {
        let fixture = ProviderHTTPRetryFixture(
            steps: [
                .response(500),
                .json(200, #"{"first":true}"#),
                .response(500),
                .json(200, #"{"second":true}"#)
            ],
            randomValues: [0.5, 0.5]
        )

        _ = try await fixture.http.data(
            for: fixture.request,
            provider: .codex
        )
        _ = try await fixture.http.data(
            for: fixture.request,
            provider: .codex
        )

        #expect(fixture.requestCount == 4)
        #expect(fixture.sleeps == [0.5, 0.5])
    }
}

private final class ProviderHTTPRetryFixture: @unchecked Sendable {
    private let identifier = UUID().uuidString
    private let state: ProviderHTTPRetryState
    let request: URLRequest
    let http: ProviderHTTP

    init(
        steps: [ProviderHTTPRetryStep],
        method: String = "GET",
        body: Data? = nil,
        wallNow: Date = Date(timeIntervalSince1970: 1_786_032_000),
        maximumResponseBytes: Int = 1_024,
        operationTimeout: TimeInterval = 30,
        randomValues: [Double] = []
    ) {
        state = ProviderHTTPRetryState(
            steps: steps,
            randomValues: randomValues
        )
        ProviderHTTPRetryURLProtocol.register(
            identifier: identifier,
            state: state
        )
        var request = URLRequest(
            url: URL(string: "https://\(identifier).retry.test/usage")!
        )
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        self.request = request

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderHTTPRetryURLProtocol.self]
        let policy = ProviderRetryPolicy(
            maximumAttempts: 3,
            baseDelay: 1,
            maximumDelay: 8,
            operationTimeout: operationTimeout,
            maximumResponseBytes: maximumResponseBytes
        )
        http = ProviderHTTP(
            session: URLSession(configuration: configuration),
            retryPolicy: policy,
            monotonicNow: { [state] in state.monotonicTime },
            wallNow: { wallNow },
            sleep: { [state] delay in state.recordSleep(delay) },
            random: { [state] in state.nextRandomValue() }
        )
    }

    deinit {
        ProviderHTTPRetryURLProtocol.unregister(identifier: identifier)
    }

    var requestCount: Int { state.requestCount }
    var requests: [URLRequest] { state.requests }
    var requestTimeouts: [TimeInterval] { state.requestTimeouts }
    var sleeps: [TimeInterval] { state.sleeps }
    var monotonicTime: TimeInterval { state.monotonicTime }
    var finishedBeforeStop: Bool { state.finishedBeforeStop }

    func waitUntilStarted() async {
        await state.waitUntilStreamingStarted()
    }

    func send(_ data: Data) {
        state.sendStreamingData(data)
    }

    func waitUntilStopped() async {
        await state.waitUntilStreamingStopped()
    }

    func finishStreamingIfNeeded() {
        state.finishStreamingIfNeeded()
    }
}

private enum ProviderHTTPRetryStep: Sendable {
    case response(
        Int,
        headers: [String: String] = [:],
        body: Data = Data()
    )
    case transport(URLError.Code)
    case stream

    static func json(_ status: Int, _ body: String) -> Self {
        .response(
            status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }
}

private final class ProviderHTTPRetryState: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingSteps: [ProviderHTTPRetryStep]
    private var remainingRandomValues: [Double]
    private var recordedRequests: [URLRequest] = []
    private var recordedSleeps: [TimeInterval] = []
    private var recordedMonotonicTime: TimeInterval = 0
    private var streamingProtocol: ProviderHTTPRetryURLProtocol?
    private let streamingStarted: AsyncStream<Void>
    private let streamingStartedContinuation: AsyncStream<Void>.Continuation
    private let streamingStopped: AsyncStream<Void>
    private let streamingStoppedContinuation: AsyncStream<Void>.Continuation
    private var streamingFinished = false
    private var recordedFinishedBeforeStop = false

    init(steps: [ProviderHTTPRetryStep], randomValues: [Double]) {
        remainingSteps = steps
        remainingRandomValues = randomValues
        (streamingStarted, streamingStartedContinuation) =
            AsyncStream.makeStream(of: Void.self)
        (streamingStopped, streamingStoppedContinuation) =
            AsyncStream.makeStream(of: Void.self)
    }

    func nextStep(for request: URLRequest) -> ProviderHTTPRetryStep {
        lock.withLock {
            recordedRequests.append(request)
            guard !remainingSteps.isEmpty else {
                return .transport(.badServerResponse)
            }
            return remainingSteps.removeFirst()
        }
    }

    func recordSleep(_ delay: TimeInterval) {
        lock.withLock {
            recordedSleeps.append(delay)
            recordedMonotonicTime += delay
        }
    }

    func nextRandomValue() -> Double {
        lock.withLock {
            guard !remainingRandomValues.isEmpty else { return 1 }
            return remainingRandomValues.removeFirst()
        }
    }

    func startStreaming(_ protocolInstance: ProviderHTTPRetryURLProtocol) {
        lock.withLock { streamingProtocol = protocolInstance }
        streamingStartedContinuation.yield()
        streamingStartedContinuation.finish()
    }

    func waitUntilStreamingStarted() async {
        var iterator = streamingStarted.makeAsyncIterator()
        _ = await iterator.next()
    }

    func sendStreamingData(_ data: Data) {
        if let protocolInstance = lock.withLock({ streamingProtocol }) {
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                didLoad: data
            )
        }
    }

    func stopStreaming() {
        let shouldSignal = lock.withLock {
            guard streamingProtocol != nil else { return false }
            recordedFinishedBeforeStop = streamingFinished
            streamingProtocol = nil
            return true
        }
        if shouldSignal {
            streamingStoppedContinuation.yield()
            streamingStoppedContinuation.finish()
        }
    }

    func waitUntilStreamingStopped() async {
        var iterator = streamingStopped.makeAsyncIterator()
        _ = await iterator.next()
    }

    func finishStreamingIfNeeded() {
        let protocolInstance: ProviderHTTPRetryURLProtocol? = lock.withLock {
            guard !streamingFinished else { return nil }
            streamingFinished = true
            return streamingProtocol
        }
        if let protocolInstance {
            protocolInstance.client?.urlProtocolDidFinishLoading(
                protocolInstance
            )
        }
    }

    var finishedBeforeStop: Bool {
        lock.withLock { recordedFinishedBeforeStop }
    }

    var requestCount: Int { lock.withLock { recordedRequests.count } }
    var requests: [URLRequest] { lock.withLock { recordedRequests } }
    var requestTimeouts: [TimeInterval] {
        lock.withLock { recordedRequests.map(\.timeoutInterval) }
    }
    var sleeps: [TimeInterval] { lock.withLock { recordedSleeps } }
    var monotonicTime: TimeInterval {
        lock.withLock { recordedMonotonicTime }
    }
}

private final class ProviderHTTPRetryURLProtocol: URLProtocol,
    @unchecked Sendable
{
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [
        String: ProviderHTTPRetryState
    ] = [:]

    static func register(
        identifier: String,
        state: ProviderHTTPRetryState
    ) {
        lock.withLock { states[identifier] = state }
    }

    static func unregister(identifier: String) {
        _ = lock.withLock { states.removeValue(forKey: identifier) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".retry.test") == true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let identifier = request.url?.host?.components(
                separatedBy: "."
            ).first,
            let state = Self.lock.withLock({ Self.states[identifier] })
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }

        switch state.nextStep(for: request) {
        case let .transport(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .stream:
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            state.startStreaming(self)
        case let .response(status, headers, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        guard
            let identifier = request.url?.host?.components(
                separatedBy: "."
            ).first,
            let state = Self.lock.withLock({ Self.states[identifier] })
        else { return }
        state.stopStreaming()
    }
}
