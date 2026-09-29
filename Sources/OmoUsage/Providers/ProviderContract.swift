import OmoUsageCore
import Foundation

enum ProviderEndpointPurpose: String, CaseIterable, Sendable {
    case claudeOAuthUsage = "claude.oauth-usage"
    case claudeTokenRefresh = "claude.token-refresh"
    case claudeDesktopUsage = "claude.desktop-usage"
    case claudeTokenExchange = "claude.token-exchange"
    case codexUsage = "codex.usage"
    case cursorUsageSummary = "cursor.usage-summary"
    case cursorAccount = "cursor.account"
    case antigravityAvailableModels = "antigravity.available-models"
    case copilotUser = "copilot.user"
    case devinUserStatus = "devin.user-status"
    case grokBilling = "grok.billing"
    case grokSettings = "grok.settings"
    case grokOpenIDConfiguration = "grok.openid-configuration"
    case grokTokenRefresh = "grok.token-refresh"
    case kiroUsageLimits = "kiro.usage-limits"
    case openCodeGoUsage = "opencode.go-usage"
    case openRouterCredits = "openrouter.credits"
    case openRouterKey = "openrouter.key"
    case zaiQuota = "zai.quota"
    case zaiSubscription = "zai.subscription"
}

enum ProviderHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

enum ProviderRequestSafety: Sendable {
    case safe
    case unsafe
}

enum ProviderUserAgentPolicy: Sendable {
    case requiredStable
    case systemProvided
}

enum ProviderContractError: Error, Equatable, Sendable {
    case requestDoesNotConform(
        provider: ProviderID,
        purpose: ProviderEndpointPurpose
    )
    case schemaChanged(
        provider: ProviderID,
        purpose: ProviderEndpointPurpose,
        contractRevision: Int
    )
}

struct ProviderEndpointDescriptor: Equatable, Sendable {
    let provider: ProviderID
    let purpose: ProviderEndpointPurpose
    let method: ProviderHTTPMethod
    let requiredHeaderNames: Set<String>
    let userAgentPolicy: ProviderUserAgentPolicy
    let safety: ProviderRequestSafety
    let schemaRevision: Int
    let retriesRateLimit: Bool

    func validate(_ request: URLRequest) throws {
        let methodMatches = (request.httpMethod ?? "GET").uppercased()
            == method.rawValue
        let presentHeaders = Set(
            (request.allHTTPHeaderFields ?? [:]).keys.map {
                $0.lowercased()
            }
        )
        let headersMatch = requiredHeaderNames.allSatisfy {
            presentHeaders.contains($0.lowercased())
        }
        let userAgentMatches = switch userAgentPolicy {
        case .requiredStable:
            presentHeaders.contains("user-agent")
        case .systemProvided:
            true
        }
        guard methodMatches, headersMatch, userAgentMatches else {
            throw ProviderContractError.requestDoesNotConform(
                provider: provider,
                purpose: purpose
            )
        }
    }

    func schemaChecked<Value>(
        _ parse: () throws -> Value
    ) throws -> Value {
        do {
            return try parse()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderContractError {
            throw error
        } catch {
            throw ProviderContractError.schemaChanged(
                provider: provider,
                purpose: purpose,
                contractRevision: schemaRevision
            )
        }
    }
}

struct ProviderContract: Equatable, Sendable {
    let provider: ProviderID
    let schemaRevision: Int
    let endpoints: [ProviderEndpointDescriptor]
}
