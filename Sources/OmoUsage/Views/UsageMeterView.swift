import OmoUsageCore
import SwiftUI

enum UsageMeterVisualTokens {
    static let displaysMenuBarBadge = false
    static let standardFill = VisualRGB(
        red: 0x4C,
        green: 0x85,
        blue: 0x77
    )
    static let extraFill = VisualRGB(
        red: 0xB7,
        green: 0x79,
        blue: 0x3F
    )
    static let trackOpacity = 0.16

    static func fillRGB(for period: UsagePeriod) -> VisualRGB {
        period == .extra ? extraFill : standardFill
    }
}

struct UsageMeterView: View {
    let meter: UsageMeter
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(localization.providerText(meter.title))
                    .font(.system(size: 12.5, weight: .medium))

                Spacer(minLength: 8)

                Text(localization.metricValue(meter.metric))
                    .font(.system(size: 12.5, weight: .semibold))
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
                    .font(.system(size: 11))
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
