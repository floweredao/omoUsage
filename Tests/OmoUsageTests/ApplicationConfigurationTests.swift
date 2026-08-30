import AppKit
import Testing
@testable import OmoUsage

@Suite
struct ApplicationConfigurationTests {
    @Test
    func settingsWindowCannotCreateAMinimizedDockTile() {
        #expect(
            !SettingsWindowContract.styleMask.contains(.miniaturizable)
        )
    }

    @Test @MainActor
    func settingsWindowHidesTheMinimizeAffordance() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: SettingsWindowContract.styleMask,
            backing: .buffered,
            defer: false
        )
        SettingsWindowContract.apply(to: window)

        #expect(
            window.standardWindowButton(.miniaturizeButton)?.isHidden
                == true
        )
    }
}
