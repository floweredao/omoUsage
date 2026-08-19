#if os(iOS)
import Foundation
import SwiftUI

@main
struct OmoUsageMobileApp: App {
    @State private var viewModel: MobileUsageViewModel
    @State private var localization: LocalizationController
    private let usesAccessibilityFixture: Bool

    @MainActor
    init() {
        let store = UbiquitousUsageSnapshotStore()
        let fixture = ProcessInfo.processInfo.environment[
            "OMO_USAGE_FIXTURE_MODE"
        ] == "1" ? DashboardSnapshot.mobileFixture : nil
        usesAccessibilityFixture = ProcessInfo.processInfo.environment[
            "OMO_USAGE_ACCESSIBILITY_FIXTURE"
        ] == "1"
        _viewModel = State(
            initialValue: MobileUsageViewModel(
                loadSnapshot: { try store.load() },
                fixtureSnapshot: fixture
            )
        )
        _localization = State(
            initialValue: LocalizationController(
                store: AppLanguageStore(defaults: .standard)
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            mobileView
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSUbiquitousKeyValueStore
                        .didChangeExternallyNotification
                )
            ) { _ in
                viewModel.reload()
            }
        }
    }

    @ViewBuilder
    private var mobileView: some View {
        if usesAccessibilityFixture {
            MobileUsageView(
                viewModel: viewModel,
                localization: localization
            )
            .dynamicTypeSize(.accessibility3)
        } else {
            MobileUsageView(
                viewModel: viewModel,
                localization: localization
            )
        }
    }
}

private extension DashboardSnapshot {
    static var mobileFixture: DashboardSnapshot {
        let now = Date()
        return DashboardSnapshot(
            providers: [
                ProviderUsage(
                    provider: .claude,
                    planName: "Max",
                    groups: [
                        UsageGroup(
                            id: "claude-limits",
                            title: nil,
                            meters: [
                                UsageMeter(
                                    id: "claude-session",
                                    title: "세션 (5시간)",
                                    period: .session,
                                    percentRemaining: 82,
                                    resetsAt: now.addingTimeInterval(7_200)
                                ),
                                UsageMeter(
                                    id: "claude-week",
                                    title: "주간",
                                    period: .week,
                                    percentRemaining: 64,
                                    resetsAt: now.addingTimeInterval(259_200)
                                )
                            ],
                            creditText: nil
                        )
                    ],
                    availability: .available,
                    updatedAt: now
                ),
                ProviderUsage(
                    provider: .codex,
                    planName: "Plus",
                    groups: [
                        UsageGroup(
                            id: "codex-limits",
                            title: nil,
                            meters: [
                                UsageMeter(
                                    id: "codex-session",
                                    title: "세션",
                                    period: .session,
                                    percentRemaining: 47,
                                    resetsAt: now.addingTimeInterval(5_400)
                                ),
                                UsageMeter(
                                    id: "codex-extra",
                                    title: "추가 사용량",
                                    period: .extra,
                                    percentRemaining: 28,
                                    resetText: "이번 달"
                                )
                            ],
                            creditText: nil
                        )
                    ],
                    availability: .available,
                    updatedAt: now
                )
            ],
            refreshedAt: now
        )
    }
}
#endif
