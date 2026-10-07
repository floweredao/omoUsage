import OmoUsageCore
#if os(iOS)
import SwiftUI

struct MobileUsageView: View {
    @Bindable var viewModel: MobileUsageViewModel
    let localization: LocalizationController

    var body: some View {
        NavigationStack {
            Group {
                if
                    let snapshot = viewModel.snapshot,
                    !snapshot.providers.isEmpty
                {
                    usageContent(snapshot)
                } else {
                    stateContent
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(localization.text(.aiUsage))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.reload()
                    } label: {
                        if viewModel.loadState == .loading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .accessibilityLabel(localization.text(.checkICloud))
                    .accessibilityHint(
                        localization.text(.mobileICloudCheckExplanation)
                    )
                    .disabled(viewModel.loadState == .loading)
                }
            }
        }
        .environment(\.appLocalization, localization.context)
        .task {
            viewModel.reload()
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView(localization.text(.inProgress))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label(
                    localization.text(.mobileNoDataTitle),
                    systemImage: "icloud.slash"
                )
            } description: {
                Text(localization.text(.mobileNoDataDescription))
            } actions: {
                Button(localization.text(.retry)) {
                    viewModel.reload()
                }
                .buttonStyle(.borderedProminent)
            }
        case .failed:
            ContentUnavailableView {
                Label(
                    localization.text(.mobileSyncFailed),
                    systemImage: "exclamationmark.icloud"
                )
            } actions: {
                Button(localization.text(.retry)) {
                    viewModel.reload()
                }
                .buttonStyle(.borderedProminent)
            }
        case .content:
            EmptyView()
        }
    }

    private func usageContent(
        _ snapshot: DashboardSnapshot
    ) -> some View {
        let providerCounts = Dictionary(
            grouping: snapshot.providers,
            by: \.provider
        ).mapValues(\.count)
        return ScrollView {
            LazyVStack(spacing: 12) {
                if let freshness = viewModel.freshnessPresentation {
                    MobileSyncStatusHeader(freshness: freshness)
                }

                ForEach(snapshot.providers) { usage in
                    MobileProviderCard(
                        usage: usage,
                        showsAccountLabel:
                            DashboardAccountIdentityRule.showsAlias(
                                for: usage,
                                sameProviderCount: providerCounts[
                                    usage.provider,
                                    default: 0
                                ]
                            )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            viewModel.reload()
        }
    }
}

private struct MobileProviderCard: View {
    let usage: ProviderUsage
    let showsAccountLabel: Bool
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        let freshness = ProviderFreshnessDisplay.make(
            for: usage,
            includesSuccessRow: false
        )
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    identity
                    Spacer(minLength: 0)
                    if freshness.showsStaleBadge {
                        staleBadge
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    identity
                    if freshness.showsStaleBadge {
                        staleBadge
                    }
                }
            }

            ForEach(usage.groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    if let title = group.title {
                        Text(localization.providerText(title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(group.meters) { meter in
                        MobileUsageMeter(meter: meter)
                    }

                    if let creditText = group.creditText {
                        Text(localization.providerText(creditText))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if freshness.rowCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    if let successAt = freshness.successAt {
                        Text(
                            localization.format(
                                .asOf,
                                MobileClockText.string(from: successAt)
                            )
                        )
                    }
                    if let attemptAt = freshness.attemptAt {
                        Text(
                            localization.format(
                                .lastRefreshAttempt,
                                MobileClockText.string(from: attemptAt)
                            )
                        )
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            MobileProviderMark(provider: usage.provider)

            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        providerName
                        planPill
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        providerName
                        planPill
                    }
                }

                if showsAccountLabel {
                    Text(AccountLabel.sanitized(usage.accountLabel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var providerName: some View {
        Text(usage.provider.displayName)
            .font(.headline)
    }

    @ViewBuilder
    private var planPill: some View {
        if !usage.planName.isEmpty {
            Text(usage.planName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                }
        }
    }

    private var staleBadge: some View {
        MobileFreshnessBadge(
            symbolName: StaleUsageVisualTokens.symbolName,
            text: localization.staleBadgeText(),
            accent: StaleUsageVisualTokens.accent
        )
    }
}

/// The macOS `ProviderIcon` tile at mobile size: the brand background from
/// `ProviderVisualStyle`, the bundled SVG mark when one ships for the
/// provider, and the Core monogram otherwise.
private struct MobileProviderMark: View {
    let provider: ProviderID
    @ScaledMetric(relativeTo: .headline)
    private var scaledSize = ProviderMarkVisualTokens.mobileSize

    var body: some View {
        let style = ProviderVisualStyle.style(for: provider)
        let size = min(scaledSize, ProviderMarkVisualTokens.mobileMaximumSize)
        ZStack {
            RoundedRectangle(
                cornerRadius: size * ProviderMarkVisualTokens.cornerRadiusRatio
            )
            .fill(style.background)
            .shadow(
                color: .black.opacity(ProviderMarkVisualTokens.shadowOpacity),
                radius: ProviderMarkVisualTokens.shadowRadius,
                y: ProviderMarkVisualTokens.shadowOffsetY
            )

            if let mark = MobileProviderMarkStore.mark(for: provider) {
                MobileProviderMarkArtwork(mark: mark)
                    .padding(size * ProviderMarkVisualTokens.artworkInsetRatio)
            } else {
                Text(provider.monogram)
                    .font(
                        .system(
                            size: size
                                * ProviderMarkVisualTokens.monogramPointRatio,
                            weight: .heavy,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(style.foreground)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum MobileProviderMarkStore {
    private static var marks: [ProviderID: ProviderMark?] = [:]

    static func mark(for provider: ProviderID) -> ProviderMark? {
        if let cached = marks[provider] {
            return cached
        }
        let url = Bundle.main.resourceURL?
            .appending(path: "ProviderIcons", directoryHint: .isDirectory)
            .appending(path: "\(provider.rawValue).svg")
        let mark = url
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { ProviderMark(svg: $0) }
        marks.updateValue(mark, forKey: provider)
        return mark
    }
}

private struct MobileProviderMarkArtwork: View {
    let mark: ProviderMark

    var body: some View {
        ZStack {
            ForEach(Array(mark.shapes.enumerated()), id: \.offset) { _, shape in
                MobileProviderMarkPath(
                    elements: shape.elements,
                    viewBox: mark.viewBox
                )
                .fill(fillColor(shape.fill))
            }
        }
    }

    private func fillColor(_ fill: ProviderMark.Fill) -> Color {
        switch fill {
        case .currentColor: .white
        case .rgb(let rgb): rgb.color
        }
    }
}

private struct MobileProviderMarkPath: Shape {
    let elements: [ProviderMark.Element]
    let viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for element in elements {
            switch element {
            case .move(let point):
                path.move(to: point)
            case .line(let point):
                path.addLine(to: point)
            case .quadCurve(let point, let control):
                path.addQuadCurve(to: point, control: control)
            case .curve(let point, let control1, let control2):
                path.addCurve(to: point, control1: control1, control2: control2)
            case .close:
                path.closeSubpath()
            }
        }
        let scale = min(
            rect.width / viewBox.width,
            rect.height / viewBox.height
        )
        let transform = CGAffineTransform(
            translationX: rect.midX - viewBox.midX * scale,
            y: rect.midY - viewBox.midY * scale
        )
        .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}

/// States what mobile actually knows: when the Mac last checked, whether that
/// snapshot has aged out, whether the last iCloud read failed, and that a pull
/// only re-reads iCloud.
private struct MobileSyncStatusHeader: View {
    let freshness: MobileFreshnessPresentation
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        let clockText = MobileClockText.string(
            from: freshness.macLastCheckedAt
        )
        let statusText = freshness.statusText(
            localization,
            clockText: clockText
        )
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    syncLabel
                    Spacer(minLength: 12)
                    Text(statusText)
                }
                VStack(alignment: .leading, spacing: 2) {
                    syncLabel
                    Text(statusText)
                }
            }
            .font(.footnote.weight(.medium))

            if freshness.isStale {
                MobileFreshnessBadge(
                    symbolName: MobileFreshnessVisualTokens.symbolName,
                    text: localization.snapshotAgeBadgeText(),
                    accent: MobileFreshnessVisualTokens.accent
                )
            }

            if freshness.hasSyncIssue {
                Text(localization.text(.mobileRetainedAfterSyncFailure))
                    .font(.caption)
            }

            Text(localization.text(.mobileICloudCheckExplanation))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            freshness.accessibilityLabel(
                localization,
                clockText: clockText
            )
        )
        .accessibilityHint(
            localization.text(.mobileICloudCheckExplanation)
        )
    }

    private var syncLabel: some View {
        Label(
            localization.text(.syncedThroughICloud),
            systemImage: freshness.hasSyncIssue
                ? "exclamationmark.icloud"
                : "icloud.fill"
        )
    }
}

/// One badge primitive for both freshness facts, so retained provider usage
/// and an aged-out snapshot share spacing, shape, and accent tokens while
/// keeping distinct symbols and text.
private struct MobileFreshnessBadge: View {
    let symbolName: String
    let text: String
    let accent: VisualRGB

    var body: some View {
        HStack(spacing: StaleUsageVisualTokens.badgeSpacing) {
            Image(systemName: symbolName)
                .imageScale(.small)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(accent.color)
        .padding(
            .horizontal,
            StaleUsageVisualTokens.badgeHorizontalPadding
        )
        .padding(.vertical, StaleUsageVisualTokens.badgeVerticalPadding)
        .background(
            accent.color.opacity(
                StaleUsageVisualTokens.badgeBackgroundOpacity
            ),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    accent.color.opacity(
                        StaleUsageVisualTokens.badgeBorderOpacity
                    ),
                    lineWidth: 0.5
                )
        }
        .accessibilityElement(children: .combine)
    }
}

enum MobileClockText {
    static func string(from date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

private struct MobileUsageMeter: View {
    let meter: UsageMeter
    @Environment(\.appLocalization)
    private var localization

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    meterTitle
                    Spacer()
                    remainingValue
                }
                VStack(alignment: .leading, spacing: 2) {
                    meterTitle
                    remainingValue
                }
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
                    .frame(height: 6)
                }
            case .spend, .credit, .count, .informational:
                EmptyView()
            }

            if meter.resetText != nil || meter.resetsAt != nil {
                Text(resetDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

    private var meterTitle: some View {
        Text(localization.providerText(meter.title))
            .font(.subheadline.weight(.medium))
    }

    private var remainingValue: some View {
        Text(localization.metricValue(meter.metric))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }

    private var resetAccessibilitySuffix: String {
        meter.resetText != nil || meter.resetsAt != nil
            ? ", \(resetDescription)"
            : ""
    }

    private var resetDescription: String {
        if let resetText = meter.resetText {
            return localization.providerText(resetText)
        }
        guard let resetsAt = meter.resetsAt else {
            return localization.text(.noResetInfo)
        }
        return localization.resetDescription(until: resetsAt)
    }
}
#endif
