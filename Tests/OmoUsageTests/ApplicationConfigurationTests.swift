import AppKit
import Foundation
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
    func settingsWindowCannotResizeZoomOrEnterFullScreen() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        SettingsWindowContract.apply(to: window)

        #expect(!window.styleMask.contains(.resizable))
        #expect(window.collectionBehavior.contains(.fullScreenNone))
        #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
        let before = window.frame
        window.zoom(nil)
        #expect(window.frame == before)
    }

    @Test @MainActor
    func settingsWindowDimsRatherThanHidesMinimizeAndZoom() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: SettingsWindowContract.styleMask,
            backing: .buffered,
            defer: false
        )
        SettingsWindowContract.apply(to: window)

        for type in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            let button = window.standardWindowButton(type)
            #expect(button?.isHidden == false)
            #expect(button?.isEnabled == false)
        }
    }

    @Test @MainActor
    func settingsWindowFitKeepsTheTopEdgeFixed() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 480, height: 400),
            styleMask: SettingsWindowContract.styleMask,
            backing: .buffered,
            defer: false
        )
        let frame = SettingsWindowContract.frame(
            for: window,
            fittingContentHeight: 250
        )
        #expect(frame.maxY == window.frame.maxY)
        #expect(frame.height == window.frame.height - 150)
        #expect(frame.width == window.frame.width)
    }

    @Test
    func settingsPaneHeightFollowsItsFormUpToTheCap() {
        #expect(SettingsWindowContract.maximumPaneContentHeight == 640)
        #expect(
            SettingsWindowContract.preferredContentHeight(
                forFormContentHeight: 219
            ) == 219
        )
        #expect(
            SettingsWindowContract.preferredContentHeight(
                forFormContentHeight: 640
            ) == 640
        )
        #expect(
            SettingsWindowContract.preferredContentHeight(
                forFormContentHeight: 1_180
            ) == 640
        )
    }

    @Test
    func settingsWindowFitAnimatesOnlyVisiblePaneSwitchesWithoutReduceMotion() {
        #expect(
            SettingsWindowContract.animatesFit(
                isInitialFit: false, isVisible: true, reduceMotion: false
            )
        )
        #expect(
            !SettingsWindowContract.animatesFit(
                isInitialFit: false, isVisible: true, reduceMotion: true
            )
        )
        #expect(
            !SettingsWindowContract.animatesFit(
                isInitialFit: true, isVisible: true, reduceMotion: false
            )
        )
        #expect(
            !SettingsWindowContract.animatesFit(
                isInitialFit: false, isVisible: false, reduceMotion: false
            )
        )
    }

    @Test
    func settingsPanesFollowTheFormerSectionOrderWithStableIdentifiers() {
        #expect(SettingsPane.allCases == [
            .general, .display, .webAccess, .dashboardOrder, .accounts
        ])
        #expect(SettingsPane.allCases.map(\.titleKey) == [
            .generalSettings, .displaySettings, .webAccessSettings,
            .dashboardOrder, .providerAuthentication
        ])
        for pane in SettingsPane.allCases {
            #expect(
                SettingsPane(toolbarItemIdentifier: pane.toolbarItemIdentifier)
                    == pane
            )
            #expect(
                NSImage(
                    systemSymbolName: pane.systemImageName,
                    accessibilityDescription: nil
                ) != nil
            )
        }
    }

    @Test @MainActor
    func settingsReopensOnTheLastViewedPane() throws {
        let suite = "OmoUsageSettingsPaneTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SettingsPaneSelection(defaults: defaults).pane == .general)
        SettingsPaneSelection(defaults: defaults).select(.webAccess)
        #expect(SettingsPaneSelection(defaults: defaults).pane == .webAccess)

        defaults.set("removed-pane", forKey: SettingsPaneSelection.defaultsKey)
        #expect(SettingsPaneSelection(defaults: defaults).pane == .general)
    }

    @Test @MainActor
    func settingsToolbarIsNoncustomizableAndMarksTheActivePane() throws {
        let suite = "OmoUsageSettingsToolbarTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selection = SettingsPaneSelection(defaults: defaults)
        selection.select(.display)
        var selected: [SettingsPane] = []
        let controller = SettingsToolbarController(
            selection: selection,
            title: { $0.rawValue },
            onSelect: { selected.append($0) }
        )
        let toolbar = controller.toolbar
        let identifiers = SettingsPane.allCases.map(\.toolbarItemIdentifier)

        #expect(!toolbar.allowsUserCustomization)
        #expect(controller.toolbarSelectableItemIdentifiers(toolbar) == identifiers)
        #expect(toolbar.selectedItemIdentifier == SettingsPane.display.toolbarItemIdentifier)

        let item = try #require(controller.toolbar(
            toolbar,
            itemForItemIdentifier: SettingsPane.accounts.toolbarItemIdentifier,
            willBeInsertedIntoToolbar: true
        ))
        #expect(item.label == "accounts")
        // Every item reserves the widest pane title, so all five share one width.
        #expect(item.possibleLabels == Set(SettingsPane.allCases.map(\.rawValue)))
        controller.selectPane(item)

        #expect(selected == [.accounts])
        #expect(selection.pane == .accounts)
        #expect(toolbar.selectedItemIdentifier == item.itemIdentifier)
    }

    @Test @MainActor
    func applicationMenuOpensSettingsWithCommandComma() {
        let target = NSObject()
        let menu = ApplicationMenuContract.makeMenu(
            settingsTitle: "Settings",
            fileTitle: "File",
            closeTitle: "Close",
            target: target
        )

        let settingsItem = menu.settingsItem
        #expect(settingsItem.title == "Settings\u{2026}")
        #expect(settingsItem.keyEquivalent == ",")
        #expect(
            settingsItem.keyEquivalentModifierMask
                == NSEvent.ModifierFlags.command
        )
        #expect(settingsItem.action == #selector(AppDelegate.openSettings(_:)))
        #expect(settingsItem.target === target)
        #expect(
            NSApplication.shared.mainMenu?.items.first?.submenu?.items.first
                === settingsItem
        )
    }

    @Test @MainActor
    func applicationMenuRoutesCommandWToTheSettingsWindowClose() {
        let target = NSObject()
        let menu = ApplicationMenuContract.makeMenu(
            settingsTitle: "Settings",
            fileTitle: "File",
            closeTitle: "Close",
            target: target
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
