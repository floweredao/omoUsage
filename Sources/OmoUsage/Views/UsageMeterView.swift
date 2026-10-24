import OmoUsageCore
import SwiftUI

struct UsageMeterView: View {
    let meter: UsageMeter
    @Environment(\.appLocalization)
    private var localization
    @Environment(\.dashboardTextScale)
    private var scale
    @Environment(\.dashboardPalette)
    private var palette
    @Environment(\.sideNotchAccentProvider)
    private var accentProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * scale) {
            HStack(spacing: 6 * scale) {
                Text(localization.providerText(meter.title))
                    .font(
                        .system(
                            size: DashboardTypographyTokens.meterLabel
                                * scale,
                            weight: .medium
                        )
                    )

                Spacer(minLength: 8 * scale)

                Text(localization.metricValue(meter.metric))
                    .font(
                        .system(
                            size: DashboardTypographyTokens.meterValue
                                * scale,
                            weight: .semibold
                        )
                    )
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
            }

            switch meter.metric.kind {
            case .quotaRemaining:
                if let fraction = meter.metric.progressFraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(
                                    trackColor.opacity(
                                        UsageMeterVisualTokens.trackOpacity
                                    )
                                )
                            Capsule()
                                .fill(fillColor)
                                .frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(height: 4 * scale)
                }
            case .spend, .credit, .count, .informational:
                EmptyView()
            }

            if meter.resetText != nil || meter.resetsAt != nil {
                Text(resetText)
                    .font(
                        .system(
                            size: DashboardTypographyTokens.metadata * scale
                        )
                    )
                    .foregroundStyle(
                        ProviderMetadataVisualTokens.foreground
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            localization.metricAccessibilityLabel(
                title: meter.title,
                metric: meter.metric
            ) + resetAccessibilitySuffix
        )
    }

    private var fillColor: Color {
        switch palette {
        case .standard:
            UsageMeterVisualTokens.fillRGB(for: meter.period).color
        case .sideNotch:
            accentProvider.map(SideNotchBrandVisualTokens.accent(for:))
                ?? SideNotchNeutralVisualTokens.ink
        }
    }

    private var trackColor: Color {
        switch palette {
        case .standard: Color.primary
        case .sideNotch: fillColor
        }
    }

    private var resetAccessibilitySuffix: String {
        meter.resetText != nil || meter.resetsAt != nil
            ? ", \(resetText)"
            : ""
    }

    private var resetText: String {
        if let resetText = meter.resetText {
            return localization.providerText(resetText)
        }
        guard let resetsAt = meter.resetsAt else {
            return localization.text(.noResetInfo)
        }
        return localization.resetDescription(until: resetsAt)
    }
}

/// The palette a dashboard surface draws with. The popover keeps brand
/// tiles, period meter fills, and the amber stale accent. The Side Notch
/// draws each provider's rail ring and detail bars in its icon's brand color
/// (`sideNotchAccentProvider`) and its stale marks in one neutral ink.
enum DashboardPalette: Sendable {
    case standard
    case sideNotch
}

extension EnvironmentValues {
    @Entry var dashboardPalette: DashboardPalette = .standard
    @Entry var sideNotchAccentProvider: ProviderID? = nil
}
