import SwiftUI

struct VisualRGB: Equatable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var color: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}

/// Stale usage is announced with a symbol and a text label so the state never
/// depends on color alone. The accent reuses the dashboard's amber token.
enum StaleUsageVisualTokens {
    static let symbolName = "exclamationmark.triangle.fill"
    static let usesTextLabel = true
    static let accent = VisualRGB(red: 0xB7, green: 0x79, blue: 0x3F)
    static let badgeRowHeight: CGFloat = 19
    static let badgeSymbolPointSize: CGFloat = 9.5
    static let badgeFontSize: CGFloat = 11
    static let badgeSpacing: CGFloat = 4
    static let badgeHorizontalPadding: CGFloat = 7
    static let badgeVerticalPadding: CGFloat = 3
    static let badgeBackgroundOpacity = 0.12
    static let badgeBorderOpacity = 0.34
}

struct ProviderVisualStyle {
    let background: AnyShapeStyle
    let foreground: Color

    static func style(for provider: ProviderID) -> ProviderVisualStyle {
        switch provider {
        case .claude:
            ProviderVisualStyle(
                background: AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 1, green: 0.43, blue: 0.23),
                            .orange
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
                foreground: .white
            )
        case .codex:
            ProviderVisualStyle(
                background: AnyShapeStyle(
                    LinearGradient(
                        colors: [.indigo, .blue.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
                foreground: .white
            )
        case .cursor:
            solid(.black.opacity(0.9))
        case .antigravity:
            solid(.white.opacity(0.94), foreground: .black)
        case .copilot:
            solid(.black.opacity(0.86))
        case .devin:
            ProviderVisualStyle(
                background: AnyShapeStyle(
                    LinearGradient(
                        colors: [.purple, .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
                foreground: .white
            )
        case .grok:
            solid(.black.opacity(0.9))
        case .opencode:
            solid(Color(red: 0.18, green: 0.2, blue: 0.23))
        case .openrouter:
            ProviderVisualStyle(
                background: AnyShapeStyle(
                    LinearGradient(
                        colors: [.pink, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
                foreground: .white
            )
        case .zai:
            ProviderVisualStyle(
                background: AnyShapeStyle(
                    LinearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                ),
                foreground: .white
            )
        }
    }

    private static func solid(
        _ color: Color,
        foreground: Color = .white
    ) -> ProviderVisualStyle {
        ProviderVisualStyle(
            background: AnyShapeStyle(color),
            foreground: foreground
        )
    }
}
