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

    @Test @MainActor
    func applicationMenuRoutesCommandWToTheSettingsWindowClose() {
        let target = NSObject()
        let menu = ApplicationMenuContract.makeMenu(
            fileTitle: "File",
            closeTitle: "Close",
            closeTarget: target
        )

        let closeItem = menu.closeItem
        #expect(closeItem.keyEquivalent == "w")
        #expect(
            closeItem.keyEquivalentModifierMask
                == NSEvent.ModifierFlags.command
        )
        #expect(
            closeItem.action
                == #selector(AppDelegate.closeSettingsWindow(_:))
        )
        #expect(closeItem.target === target)
        #expect(
            menu.fileMenu.item(withTitle: "Close")
                === closeItem
        )
    }
}
