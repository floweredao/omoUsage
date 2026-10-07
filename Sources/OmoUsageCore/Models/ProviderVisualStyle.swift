import SwiftUI

public struct VisualRGB: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var color: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }
}

/// Stale usage is announced with a symbol and a text label so the state never
/// depends on color alone. The accent reuses the dashboard's amber token.
public enum StaleUsageVisualTokens {
    public static let symbolName = "exclamationmark.triangle.fill"
    public static let usesTextLabel = true
    public static let accent = VisualRGB(red: 0xB7, green: 0x79, blue: 0x3F)
    public static let badgeRowHeight: CGFloat = 19
    public static let badgeSymbolPointSize: CGFloat = 9.5
    public static let badgeFontSize: CGFloat = 11
    public static let badgeSpacing: CGFloat = 4
    public static let badgeHorizontalPadding: CGFloat = 7
    public static let badgeVerticalPadding: CGFloat = 3
    public static let badgeBackgroundOpacity = 0.12
    public static let badgeBorderOpacity = 0.34
}

/// An aged-out mobile snapshot reuses the same amber accent and badge metrics
/// as retained provider usage, with its own clock symbol and text, so the two
/// facts stay visually related yet distinguishable without color alone.
public enum MobileFreshnessVisualTokens {
    public static let symbolName = "clock.badge.exclamationmark"
    public static let usesTextLabel = true
    public static let accent = StaleUsageVisualTokens.accent
    public static let badgeSpacing = StaleUsageVisualTokens.badgeSpacing
    public static let badgeHorizontalPadding =
        StaleUsageVisualTokens.badgeHorizontalPadding
    public static let badgeVerticalPadding =
        StaleUsageVisualTokens.badgeVerticalPadding
    public static let badgeBackgroundOpacity =
        StaleUsageVisualTokens.badgeBackgroundOpacity
    public static let badgeBorderOpacity = StaleUsageVisualTokens.badgeBorderOpacity
}

/// Meter fill and track tokens shared by every native surface, so the
/// popover, Side Notch, and mobile cards draw usage with one palette.
public enum UsageMeterVisualTokens {
    public static let displaysMenuBarBadge = false
    public static let standardFill = VisualRGB(
        red: 0x4C,
        green: 0x85,
        blue: 0x77
    )
    public static let extraFill = VisualRGB(
        red: 0xB7,
        green: 0x79,
        blue: 0x3F
    )
    public static let trackOpacity = 0.16

    public static func fillRGB(for period: UsagePeriod) -> VisualRGB {
        period == .extra ? extraFill : standardFill
    }
}

/// `ProviderIcon` draws a 20 pt tile with a 5 pt corner, a 3 pt artwork
/// inset, an 11 pt heavy rounded monogram, and a 0.12-opacity 1 pt shadow.
/// The ratios let the 32 pt mobile tile keep those proportions while it
/// scales with Dynamic Type up to its cap.
public enum ProviderMarkVisualTokens {
    public static let cornerRadiusRatio = 0.25
    public static let artworkInsetRatio = 0.15
    public static let monogramPointRatio = 0.55
    public static let shadowOpacity = 0.12
    public static let shadowRadius: CGFloat = 1
    public static let shadowOffsetY: CGFloat = 1
    public static let mobileSize: CGFloat = 32
    public static let mobileMaximumSize: CGFloat = 48
}

public struct ProviderVisualStyle {
    public let background: AnyShapeStyle
    public let foreground: Color

    public static func style(for provider: ProviderID) -> ProviderVisualStyle {
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
        case .kiro:
            solid(Color(red: 0.43, green: 0.24, blue: 0.78))
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
