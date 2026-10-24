import OmoUsageCore
import SwiftUI

struct UsageMeterView: View {
    let meter: UsageMeter
    @Environment(\.appLocalization)
    private var localization
    @Environment(\.dashboardTextScale)
    private var scale
    @Environment(\.usageMeterFillStyle)
    private var fillStyle

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
                                    Color.primary.opacity(
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
        switch fillStyle {
        case .period:
            UsageMeterVisualTokens.fillRGB(for: meter.period).color
        case .risk:
            SideNotchRiskVisualTokens.fillRGB(
                for: SideNotchUsageRisk.level(for: meter.metric)
                    ?? .comfortable
            ).color
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

/// What a meter's fill color encodes. The popover colors by period; the
/// Side Notch detail colors by how close the quota is to running out, to
/// match its rail rings.
enum UsageMeterFillStyle: Sendable {
    case period
    case risk
}

extension EnvironmentValues {
    @Entry var usageMeterFillStyle: UsageMeterFillStyle = .period
}
