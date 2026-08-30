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
            }
            .scrollIndicators(.hidden)
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
