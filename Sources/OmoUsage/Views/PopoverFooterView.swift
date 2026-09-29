import OmoUsageCore
import SwiftUI

struct PopoverFooterView: View {
    let refreshedAt: Date
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    @Environment(\.appLocalization)
    private var localization
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            RefreshTimestampView(
                updatedAt: refreshedAt,
                style: .footer
            )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            refreshButton

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

    @ViewBuilder
    private var refreshButton: some View {
        if SideNotchRefreshAnimationPolicy.shouldSpin(
            isRefreshing: isRefreshing,
            reduceMotion: reduceMotion
        ) {
            SpinningRefreshButton(
                accessibilityLabel: localization.text(.refresh),
                hitTargetSize: 32
            )
        } else {
            InteractiveIconButton(
                symbol: "arrow.clockwise",
                accessibilityLabel: localization.text(.refresh),
                isActive: isRefreshing,
                isDisabled: isRefreshing,
                dimsWhenDisabled: false,
                action: onRefresh
            )
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
