import OmoUsageCore
import SwiftUI

/// Footer control geometry. Borderless icon targets keep a 28 pt gap, so
/// adjacent controls sit 60 pt apart center to center and a near miss lands
/// on empty space rather than on Quit.
enum PopoverFooterLayout {
    static let hitTargetSize: CGFloat = 32
    static let controlSpacing: CGFloat = 28
    /// Leaves the timestamp 134 pt, enough for a 12-hour English
    /// "Last refreshed 12:36 PM" on one line at 100%.
    static let timestampSpacing: CGFloat = 6

    static var controlCenterDistance: CGFloat {
        hitTargetSize + controlSpacing
    }
}

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
    @Environment(\.dashboardTextScale)
    private var scale

    var body: some View {
        HStack(spacing: PopoverFooterLayout.timestampSpacing * scale) {
            RefreshTimestampView(
                updatedAt: refreshedAt,
                style: .footer
            )
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: PopoverFooterLayout.controlSpacing * scale) {
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
        }
        .padding(.horizontal, 14 * scale)
        .frame(height: DashboardLayout.footerHeight * scale)
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
                hitTargetSize: PopoverFooterLayout.hitTargetSize
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
