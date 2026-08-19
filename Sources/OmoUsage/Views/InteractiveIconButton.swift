import SwiftUI

enum InteractiveControlForegroundRole: Equatable, Sendable {
    case passiveSecondary
}

enum InteractiveControlBackgroundRole: Equatable, Sendable {
    case clear
    case passiveSecondary
}

struct InteractiveControlVisualState: Equatable, Sendable {
    let scale: Double
    let foregroundRole: InteractiveControlForegroundRole
    let backgroundRole: InteractiveControlBackgroundRole
    let backgroundOpacity: Double

    init(
        isHovered: Bool,
        isPressed: Bool,
        reduceMotion: Bool
    ) {
        scale = 1
        foregroundRole = .passiveSecondary
        backgroundOpacity = isPressed ? 0.2 : isHovered ? 0.12 : 0
        backgroundRole = backgroundOpacity == 0
            ? .clear
            : .passiveSecondary
    }
}

struct InteractiveIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.appLocalization)
    private var localization
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(
            InteractiveIconButtonStyle(
                isHovered: isHovered,
                reduceMotion: reduceMotion
            )
        )
        .onHover { hovering in
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.12)
            ) {
                isHovered = hovering
            }
        }
        .disabled(isDisabled)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            isActive ? localization.text(.inProgress) : ""
        )
    }
}

private struct InteractiveIconButtonStyle: ButtonStyle {
    let isHovered: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let state = InteractiveControlVisualState(
            isHovered: isHovered,
            isPressed: configuration.isPressed,
            reduceMotion: reduceMotion
        )
        configuration.label
            .foregroundStyle(foreground(state.foregroundRole))
            .background(
                background(state),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            Color(nsColor: .separatorColor),
                            lineWidth: 0.5
                        )
                }
            }
            .contentShape(Rectangle())
            .animation(
                reduceMotion ? nil : .spring(
                    response: 0.22,
                    dampingFraction: 0.78
                ),
                value: state.backgroundOpacity
            )
            .opacity(configuration.isPressed ? 0.92 : 1)
    }

    private func foreground(
        _ role: InteractiveControlForegroundRole
    ) -> Color {
        switch role {
        case .passiveSecondary:
            Color.secondary
        }
    }

    private func background(
        _ state: InteractiveControlVisualState
    ) -> Color {
        switch state.backgroundRole {
        case .clear:
            .clear
        case .passiveSecondary:
            Color.primary.opacity(state.backgroundOpacity)
        }
    }
}
