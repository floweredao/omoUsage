import OmoUsageCore
import Foundation

enum ProviderTransportError: Error, Equatable, Sendable {
    case authenticationRequired(ProviderID)
    case requestFailed(ProviderID, Int)
    case transientTransport(ProviderID, URLError.Code)
    case invalidResponse(ProviderID)
    case invalidContentType(ProviderID, String?)
    case responseTooLarge(ProviderID, limit: Int)
    case invalidJSON(ProviderID)
    case operationTimedOut(ProviderID)
}

/// A non-2xx status plus the response details a caller needs to classify it.
/// Thrown only by `data(for:endpoint:detailingStatusFailures:)` with the
/// flag set, so callers that do not opt in keep receiving
/// `ProviderTransportError` unchanged.
struct ProviderHTTPStatusFailure: Error, Equatable, Sendable {
    let transportError: ProviderTransportError
    /// RFC 6749 `error` code from a JSON body, e.g. `invalid_grant`.
    let oauthErrorCode: String?
    /// `Retry-After` in seconds from now, when the server sent one.
    let retryAfter: TimeInterval?
}

enum ProviderHTTPOperation: Sendable {
    case safe
    case unsafe
}

struct ProviderHTTP: Sendable {
    typealias MonotonicNow = @Sendable () -> TimeInterval
    typealias WallNow = @Sendable () -> Date
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    typealias Random = @Sendable () -> Double

    let session: URLSession
    let retryPolicy: ProviderRetryPolicy
    private let monotonicNow: MonotonicNow
    private let wallNow: WallNow
    private let sleep: Sleeper
    private let random: Random

    init(
        session: URLSession = .shared,
        retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy(),
        monotonicNow: @escaping MonotonicNow = {
            ProcessInfo.processInfo.systemUptime
        },
        wallNow: @escaping WallNow = Date.init,
        sleep: @escaping Sleeper = { delay in
            try await Task.sleep(for: .seconds(delay))
        },
        random: @escaping Random = { Double.random(in: 0...1) }
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.monotonicNow = monotonicNow
        self.wallNow = wallNow
        self.sleep = sleep
        self.random = random
    }

    func data(
        for request: URLRequest,
        endpoint: ProviderEndpointDescriptor,
        detailingStatusFailures: Bool = false
    ) async throws -> Data {
        try endpoint.validate(request)
        return try await data(
            for: request,
            provider: endpoint.provider,
            operation: endpoint.safety == .safe ? .safe : .unsafe,
            retriesRateLimit: endpoint.retriesRateLimit,
            detailingStatusFailures: detailingStatusFailures
        )
    }

    func data(
        for request: URLRequest,
        provider: ProviderID,
        operation: ProviderHTTPOperation? = nil,
        retriesRateLimit: Bool = true,
        detailingStatusFailures: Bool = false
    ) async throws -> Data {
        let retrySafe: Bool
        switch operation {
        case .safe:
            retrySafe = true
        case .unsafe:
            retrySafe = false
        case nil:
            retrySafe = Self.isSafeMethod(request.httpMethod)
        }
        let deadline = monotonicNow() + retryPolicy.operationTimeout
        var attempt = 1

        while true {
            try Task.checkCancellation()
            let remaining = deadline - monotonicNow()
            guard remaining > 0 else {
                throw ProviderTransportError.operationTimedOut(provider)
            }
            var attemptRequest = request
            if attemptRequest.timeoutInterval <= 0 {
                attemptRequest.timeoutInterval = remaining
            } else {
                attemptRequest.timeoutInterval = min(
                    attemptRequest.timeoutInterval,
                    remaining
                )
            }

            do {
                let (data, response) = try await boundedData(
                    for: attemptRequest,
                    provider: provider
                )
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else {
                    throw ProviderTransportError.invalidResponse(provider)
                }
                try validateBodySize(
                    data,
                    response: response,
                    provider: provider
                )
                if response.statusCode == 401 || response.statusCode == 403 {
                    throw ProviderTransportError.authenticationRequired(
                        provider
                    )
                }
                guard (200..<300).contains(response.statusCode) else {
                    let error = ProviderTransportError.requestFailed(
                        provider,
                        response.statusCode
                    )
                    guard
                        retrySafe,
                        Self.isRetryable(status: response.statusCode),
                        response.statusCode != 429 || retriesRateLimit,
                        attempt < retryPolicy.maximumAttempts
                    else {
                        throw statusFailure(
                            error,
                            response: response,
                            data: data,
                            detailed: detailingStatusFailures
                        )
                    }
                    let serverDelay = retryPolicy.retryAfterDelay(
                        from: response,
                        now: wallNow()
                    )
                    if
                        let serverDelay,
                        serverDelay > deadline - monotonicNow()
                    {
                        throw statusFailure(
                            error,
                            response: response,
                            data: data,
                            detailed: detailingStatusFailures
                        )
                    }
                    let delay = serverDelay ?? retryPolicy.backoffDelay(
                        afterAttempt: attempt,
                        randomValue: random()
                    )
                    try await waitBeforeRetry(
                        delay: delay,
                        deadline: deadline,
                        provider: provider
                    )
                    attempt += 1
                    continue
                }
                try validateJSONResponse(
                    data,
                    response: response,
                    provider: provider
                )
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ProviderTransportError {
                throw error
            } catch let error as URLError {
                guard error.code != .cancelled else {
                    throw CancellationError()
                }
                guard
                    retrySafe,
                    Self.isTransient(error.code),
                    attempt < retryPolicy.maximumAttempts
                else {
                    if Self.isTransient(error.code) {
                        throw ProviderTransportError.transientTransport(
                            provider,
                            error.code
                        )
                    }
                    throw error
                }
                let delay = retryPolicy.backoffDelay(
                    afterAttempt: attempt,
                    randomValue: random()
                )
                try await waitBeforeRetry(
                    delay: delay,
                    deadline: deadline,
                    provider: provider
                )
                attempt += 1
            }
        }
    }

    private func statusFailure(
        _ error: ProviderTransportError,
        response: HTTPURLResponse,
        data: Data,
        detailed: Bool
    ) -> any Error {
        guard detailed else { return error }
        let body = try? JSONSerialization.jsonObject(with: data)
        return ProviderHTTPStatusFailure(
            transportError: error,
            oauthErrorCode: (body as? [String: Any])?["error"] as? String,
            retryAfter: retryPolicy.retryAfterDelay(
                from: response,
                now: wallNow()
            )
        )
    }

    private func waitBeforeRetry(
        delay: TimeInterval,
        deadline: TimeInterval,
        provider: ProviderID
    ) async throws {
        let remaining = deadline - monotonicNow()
        guard delay <= remaining else {
            throw ProviderTransportError.operationTimedOut(provider)
        }
        try await sleep(delay)
        try Task.checkCancellation()
        guard monotonicNow() < deadline else {
            throw ProviderTransportError.operationTimedOut(provider)
        }
    }

    private func boundedData(
        for request: URLRequest,
        provider: ProviderID
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let limit = retryPolicy.maximumResponseBytes
        guard
            response.expectedContentLength <= 0
                || response.expectedContentLength <= limit
        else {
            bytes.task.cancel()
            throw ProviderTransportError.responseTooLarge(
                provider,
                limit: limit
            )
        }

        var data = Data()
        data.reserveCapacity(
            min(max(Int(response.expectedContentLength), 0), limit)
        )
        for try await byte in bytes {
            guard data.count < limit else {
                bytes.task.cancel()
                throw ProviderTransportError.responseTooLarge(
                    provider,
                    limit: limit
                )
            }
            data.append(byte)
        }
        return (data, response)
    }

    private func validateBodySize(
        _ data: Data,
        response: HTTPURLResponse,
        provider: ProviderID
    ) throws {
        let declaredSize = response.expectedContentLength
        guard
            declaredSize <= 0
                || declaredSize <= retryPolicy.maximumResponseBytes,
            data.count <= retryPolicy.maximumResponseBytes
        else {
            throw ProviderTransportError.responseTooLarge(
                provider,
                limit: retryPolicy.maximumResponseBytes
            )
        }
    }

    private func validateJSONResponse(
        _ data: Data,
        response: HTTPURLResponse,
        provider: ProviderID
    ) throws {
        let contentType = response.value(
            forHTTPHeaderField: "Content-Type"
        )
        guard Self.isJSONContentType(contentType) else {
            throw ProviderTransportError.invalidContentType(
                provider,
                contentType
            )
        }
        do {
            _ = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw ProviderTransportError.invalidJSON(provider)
        }
    }

    private static func isSafeMethod(_ method: String?) -> Bool {
        switch (method ?? "GET").uppercased() {
        case "GET", "HEAD", "OPTIONS": true
        default: false
        }
    }

    private static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private static func isTransient(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            true
        default:
            false
        }
    }

    private static func isJSONContentType(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mime = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mime == "application/json"
            || mime == "application/x-amz-json-1.0"
            || mime?.hasSuffix("+json") == true
    }
}
