import OmoUsageCore
import SwiftUI

struct UsageMeterView: View {
    let meter: UsageMeter
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(localization.providerText(meter.title))
                    .font(
                        .system(
                            size: DashboardTypographyTokens.meterLabel,
                            weight: .medium
                        )
                    )

                Spacer(minLength: 8)

                Text(localization.metricValue(meter.metric))
                    .font(
                        .system(
                            size: DashboardTypographyTokens.meterValue,
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
                                .fill(
                                    UsageMeterVisualTokens.fillRGB(
                                        for: meter.period
                                    ).color
                                )
                                .frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(height: 4)
                }
            case .spend, .credit, .count, .informational:
                EmptyView()
            }

            if meter.resetText != nil || meter.resetsAt != nil {
                Text(resetText)
                    .font(.system(size: DashboardTypographyTokens.metadata))
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
