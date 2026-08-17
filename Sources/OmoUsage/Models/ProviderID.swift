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
