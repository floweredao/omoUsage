import Foundation

public struct AccountID: RawRepresentable, Hashable, Sendable, Codable {
    public static let legacy = AccountID(
        rawValue: "00000000-0000-0000-0000-000000000001"
    )!

    public let rawValue: String

    public init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    public init(_ uuid: UUID = UUID()) {
        rawValue = uuid.uuidString.lowercased()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = AccountID(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid account UUID"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AccountProviderID: Hashable, Codable, Sendable {
    public let accountID: AccountID
    public let providerID: ProviderID

    public init(accountID: AccountID, providerID: ProviderID) {
        self.accountID = accountID
        self.providerID = providerID
    }
}

public enum ProviderID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    case copilot
    case devin
    case grok
    case kiro
    case opencode
    case openrouter
    case zai

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        case .devin: "Devin"
        case .grok: "Grok"
        case .kiro: "Kiro"
        case .opencode: "OpenCode"
        case .openrouter: "OpenRouter"
        case .zai: "Z.ai"
        }
    }

    public var monogram: String {
        switch self {
        case .claude: "C"
        case .codex: "⌘"
        case .cursor: "↗"
        case .antigravity: "A"
        case .copilot: "∞"
        case .devin: "D"
        case .grok: "G"
        case .kiro: "K"
        case .opencode: "O"
        case .openrouter: "R"
        case .zai: "Z"
        }
    }
}
