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

                Text(
                    localization.format(
                        .remaining,
                        meter.percentRemaining
                    )
                )
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
            }

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
                        .frame(
                            width: geometry.size.width
                                * Double(meter.percentRemaining) / 100
                        )
                }
            }
            .frame(height: 4)

            Text(resetText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var resetText: String {
        if let resetText = meter.resetText {
            return localization.providerText(resetText)
        }
        guard let resetsAt = meter.resetsAt else {
            return localization.text(.noResetInfo)
        }
        let seconds = max(0, Int(resetsAt.timeIntervalSinceNow))
        if seconds < 3_600 {
            return localization.format(
                .resetMinutes,
                max(1, seconds / 60)
            )
        }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            let minutes = seconds % 3_600 / 60
            return localization.format(
                .resetHoursMinutes,
                hours,
                minutes
            )
        }
        return localization.format(.resetDays, seconds / 86_400)
    }
}
