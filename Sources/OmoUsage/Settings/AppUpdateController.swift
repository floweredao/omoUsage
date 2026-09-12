import Combine
import Foundation
import Observation
import Sparkle

/// Owns one Sparkle updater for the macOS app, never for Core or mobile.
@Observable
@MainActor
final class AppUpdateController {
    private(set) var canCheckForUpdates = false
    private(set) var isAvailable = false
    let installedVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var availabilityObservation: AnyCancellable?

    init(enabled: Bool = true) {
        let bundle = Bundle.main
        installedVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        guard enabled, bundle.bundleURL.pathExtension == "app" else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        do {
            try controller.updater.start()
        } catch {
            DiagnosticStore.shared.record(error: error, category: .appUpdate)
            return
        }
        self.controller = controller
        isAvailable = true
        // Sparkle's updater and its KVO notifications are main-thread-only.
        availabilityObservation = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
