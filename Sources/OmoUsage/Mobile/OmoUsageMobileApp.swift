import OmoUsageCore
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
        let environment = ProcessInfo.processInfo.environment
        let usesFixture = environment["OMO_USAGE_FIXTURE_MODE"] == "1"
        let fixture = usesFixture
            ? DashboardSnapshot.mobileFixture(
                now: Date().addingTimeInterval(
                    -MobileFixtureEnvironment.snapshotAgeSeconds(environment)
                )
            )
            : nil
        usesAccessibilityFixture = environment[
            "OMO_USAGE_ACCESSIBILITY_FIXTURE"
        ] == "1"
        _viewModel = State(
            initialValue: MobileUsageViewModel(
                loadSnapshot: { try store.load() },
                fixtureSnapshot: fixture,
                simulatesSyncFailure: usesFixture
                    && MobileFixtureEnvironment.simulatesSyncFailure(
                        environment
                    )
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
