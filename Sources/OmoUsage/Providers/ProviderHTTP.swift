import Foundation

enum ProviderTransportError: Error, Equatable, Sendable {
    case authenticationRequired(ProviderID)
    case requestFailed(ProviderID, Int)
    case invalidResponse(ProviderID)
}

struct ProviderHTTP: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(
        for request: URLRequest,
        provider: ProviderID
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ProviderTransportError.invalidResponse(provider)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderTransportError.authenticationRequired(provider)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderTransportError.requestFailed(
                provider,
                response.statusCode
            )
        }
        return data
    }
}
