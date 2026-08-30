import Foundation
@testable import OmoUsage

func providerHTTPTestClient(
    session: URLSession,
    retryPolicy: ProviderRetryPolicy = ProviderRetryPolicy()
) -> ProviderHTTP {
    ProviderHTTP(
        session: session,
        retryPolicy: retryPolicy,
        sleep: { _ in },
        random: { 0 }
    )
}

func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = stream.read(
            &buffer,
            maxLength: buffer.count
        )
        guard count > 0 else { break }
        body.append(buffer, count: count)
    }
    return body
}
