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
        ] == "1" ? DashboardSnapshot.mobileFixture(now: Date()) : nil
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
#endif
