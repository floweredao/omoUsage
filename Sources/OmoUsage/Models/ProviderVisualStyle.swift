import SwiftUI

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
