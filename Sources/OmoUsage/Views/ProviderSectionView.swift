import OmoUsageCore
import SwiftUI

/// How a provider metadata row derives its foreground.
///
/// The side-notch panel is a nonactivating panel, so it never becomes key.
/// System `.secondary` text therefore renders there permanently in its
/// inactive, dimmed form over vibrant material and loses stem definition,
/// while a primary-derived alpha keeps the same hierarchy at a legible
/// weight in both the active and dimmed states.
enum ProviderMetadataForegroundRole: Equatable, Sendable {
    case systemSecondary
    case primaryDerived
}

/// The provider metadata seam: meter reset lines and the freshness
/// timestamp lines rendered beside them. Both stay subordinate to the
/// value row's full primary and share one foreground so the seam cannot
/// drift apart.
enum ProviderMetadataVisualTokens {
    static let role = ProviderMetadataForegroundRole.primaryDerived
    static let opacity = 0.78
    static let minimumOpacity = 0.72

    static var foreground: Color {
        switch role {
        case .systemSecondary:
            Color.secondary
        case .primaryDerived:
            Color.primary.opacity(opacity)
        }
    }
}

struct ProviderSectionView: View {
    let usage: ProviderUsage
    var showsAccountLabel = false
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ProviderIcon(provider: usage.provider)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(usage.provider.displayName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                    if showsAccountLabel {
                        Text(AccountLabel.sanitized(usage.accountLabel))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if !usage.planName.isEmpty {
                    Text(usage.planName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    Color(nsColor: .separatorColor),
                                    lineWidth: 0.5
                                )
                        }
                }
            }

            if let label = localization.availabilityText(
                usage.availability
            ) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                let freshness = DashboardLayout.freshnessDisplay(for: usage)

                if freshness.showsStaleBadge {
                    StaleUsageBadge()
                }

                ForEach(usage.groups) { group in
                    UsageGroupView(group: group)
                }

                if let successAt = freshness.successAt {
                    RefreshTimestampView(
                        updatedAt: successAt,
                        style: .provider
                    )
                        .font(.system(size: 11))
                        .foregroundStyle(
                            ProviderMetadataVisualTokens.foreground
                        )
                }

                if let attemptAt = freshness.attemptAt {
                    RefreshTimestampView(
                        updatedAt: attemptAt,
                        style: .footer
                    )
                        .font(.system(size: 11))
                        .foregroundStyle(
                            ProviderMetadataVisualTokens.foreground
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct StaleUsageBadge: View {
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        HStack(spacing: StaleUsageVisualTokens.badgeSpacing) {
            Image(systemName: StaleUsageVisualTokens.symbolName)
                .font(
                    .system(
                        size: StaleUsageVisualTokens.badgeSymbolPointSize,
                        weight: .bold
                    )
                )
            Text(localization.staleBadgeText())
                .font(
                    .system(
                        size: StaleUsageVisualTokens.badgeFontSize,
                        weight: .semibold
                    )
                )
        }
        .foregroundStyle(StaleUsageVisualTokens.accent.color)
        .padding(
            .horizontal,
            StaleUsageVisualTokens.badgeHorizontalPadding
        )
        .padding(.vertical, StaleUsageVisualTokens.badgeVerticalPadding)
        .background(
            StaleUsageVisualTokens.accent.color.opacity(
                StaleUsageVisualTokens.badgeBackgroundOpacity
            ),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    StaleUsageVisualTokens.accent.color.opacity(
                        StaleUsageVisualTokens.badgeBorderOpacity
                    ),
                    lineWidth: 0.5
                )
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UsageGroupView: View {
    let group: UsageGroup
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title = group.title {
                Text(localization.providerText(title))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }

            ForEach(group.meters) { meter in
                UsageMeterView(meter: meter)
            }

            if let creditText = group.creditText {
                Text(localization.providerText(creditText))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }
        }
    }
}
