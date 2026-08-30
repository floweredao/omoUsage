import SwiftUI

struct PopoverFooterView: View {
    let refreshedAt: Date
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        HStack(spacing: 10) {
            RefreshTimestampView(
                updatedAt: refreshedAt,
                style: .footer
            )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            InteractiveIconButton(
                symbol: "arrow.clockwise",
                accessibilityLabel: localization.text(.refresh),
                isActive: isRefreshing,
                isDisabled: isRefreshing,
                action: onRefresh
            )
            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
            .animation(
                isRefreshing
                    ? .linear(duration: 0.7).repeatForever(
                        autoreverses: false
                    )
                    : .default,
                value: isRefreshing
            )
            .keyboardShortcut("r", modifiers: .command)

            InteractiveIconButton(
                symbol: "gearshape",
                accessibilityLabel: localization.text(.settings),
                action: onSettings
            )
            .keyboardShortcut(",", modifiers: .command)

            InteractiveIconButton(
                symbol: "power",
                accessibilityLabel: localization.text(.quit),
                action: onQuit
            )
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .overlay(alignment: .top) {
            Divider()
        }
    }

}
