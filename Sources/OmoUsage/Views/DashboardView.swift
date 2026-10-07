import OmoUsageCore
import AppKit
import SwiftUI

struct DashboardView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    let localization: LocalizationController
    let onSettings: () -> Void
    let onQuit: () -> Void
    let onPanelHeightChange: (CGFloat) -> Void

    var body: some View {
        let panelHeight = DashboardLayout.panelHeight(
            for: viewModel.snapshot.providers
        )
        let providerCounts = Dictionary(
            grouping: viewModel.snapshot.providers,
            by: \.provider
        ).mapValues(\.count)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if viewModel.snapshot.providers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(localization.text(
                                viewModel.isRefreshing
                                    ? .dashboardChecking : .dashboardEmptyTitle
                            ))
                                .font(.system(size: 15, weight: .bold))
                            Text(localization.text(.dashboardEmptyDescription))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(localization.text(.openSettings), action: onSettings)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("dashboard-open-settings")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(viewModel.snapshot.providers.enumerated()), id: \.element.id) {
                        index,
                        usage in
                        if index > 0 {
                            Divider()
                                .padding(.vertical, 10)
                        }
                        ProviderSectionView(
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
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(
                    .bottom,
                    DashboardLayout.contentBottomPadding
                )
                .dashboardOverlayScrollers()
            }
            .scrollIndicators(.automatic)
            .frame(
                height: panelHeight - DashboardLayout.footerHeight
            )

            PopoverFooterView(
                refreshedAt: viewModel.snapshot.refreshedAt,
                isRefreshing: viewModel.isRefreshing,
                onRefresh: {
                    Task { await viewModel.refresh() }
                },
                onSettings: onSettings,
                onQuit: onQuit
            )
        }
        .frame(width: 320, height: panelHeight)
        .background(.regularMaterial)
        .environment(\.appLocalization, localization.context)
        .onChange(
            of: viewModel.snapshot.providers,
            initial: true
        ) { _, providers in
            onPanelHeightChange(
                DashboardLayout.panelHeight(for: providers)
            )
        }
    }
}

/// Scroller contract for the two compact dashboard scroll regions: the
/// popover body and the Side Notch rail.
///
/// `scrollIndicators` only decides whether SwiftUI asks for a scroller at
/// all. The scroller's style still follows the system "Show scroll bars"
/// preference, and the legacy style takes a 15 pt gutter out of the 320 pt
/// popover or the 56 pt rail and keeps its knob visible for as long as the
/// content overflows. Both surfaces therefore pin the overlay style: it
/// reserves no width, appears while scrolling, and flashes only when the
/// content overflows. The Settings window keeps the system preference.
enum DashboardScrollerPolicy {
    static let style = NSScroller.Style.overlay

    @MainActor
    static func apply(to scrollView: NSScrollView) {
        if scrollView.scrollerStyle != style {
            scrollView.scrollerStyle = style
        }
        if !scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = true
        }
    }
}

extension View {
    /// Applies `DashboardScrollerPolicy` to the enclosing `ScrollView`.
    /// Attach it to the scroll view's content, so the configurator sits
    /// inside the scroll view's document hierarchy.
    func dashboardOverlayScrollers() -> some View {
        background(DashboardScrollerConfigurator())
    }
}

struct DashboardScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.applyPolicy()
    }

    final class ConfiguratorView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // AppKit resets every scroll view to the preferred style when the
            // preference or the connected pointing device changes, so the
            // policy is applied again once that update has landed.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(preferredScrollerStyleDidChange),
                name: NSScroller.preferredScrollerStyleDidChangeNotification,
                object: nil
            )
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyPolicy()
        }

        func applyPolicy() {
            guard let scrollView = enclosingScrollView else { return }
            DashboardScrollerPolicy.apply(to: scrollView)
        }

        @objc
        private func preferredScrollerStyleDidChange() {
            Task { @MainActor [weak self] in
                self?.applyPolicy()
            }
        }
    }
}
