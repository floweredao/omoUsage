import Foundation

struct AccountID: RawRepresentable, Hashable, Sendable, Codable {
    static let legacy = AccountID(
        rawValue: "00000000-0000-0000-0000-000000000001"
    )!

    let rawValue: String

    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    init(_ uuid: UUID = UUID()) {
        rawValue = uuid.uuidString.lowercased()
    }

    init(from decoder: any Decoder) throws {
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

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AccountProviderID: Hashable, Codable, Sendable {
    let accountID: AccountID
    let providerID: ProviderID
}

enum ProviderID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    case copilot
    case devin
    case grok
    case opencode
    case openrouter
    case zai

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        case .devin: "Devin"
        case .grok: "Grok"
        case .opencode: "OpenCode"
        case .openrouter: "OpenRouter"
        case .zai: "Z.ai"
        }
    }

    var monogram: String {
        switch self {
        case .claude: "C"
        case .codex: "⌘"
        case .cursor: "↗"
        case .antigravity: "A"
        case .copilot: "∞"
        case .devin: "D"
        case .grok: "G"
        case .opencode: "O"
        case .openrouter: "R"
        case .zai: "Z"
        }
    }
}
