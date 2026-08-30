import AppKit
import Testing
@testable import OmoUsage

@Suite
@MainActor
struct DashboardVisualContractTests {
    @Test
    func usageMetersOmitBadgesAndUseTheDashboardPalette() {
        #expect(UsageMeterVisualTokens.displaysMenuBarBadge == false)
        #expect(
            UsageMeterVisualTokens.fillRGB(for: .session)
                == VisualRGB(red: 0x4C, green: 0x85, blue: 0x77)
        )
        #expect(
            UsageMeterVisualTokens.fillRGB(for: .week)
                == VisualRGB(red: 0x4C, green: 0x85, blue: 0x77)
        )
        #expect(
            UsageMeterVisualTokens.fillRGB(for: .extra)
                == VisualRGB(red: 0xB7, green: 0x79, blue: 0x3F)
        )
        #expect(UsageMeterVisualTokens.trackOpacity == 0.16)
        #expect(SettingsRowVisualTokens.usesSemanticSystemColors)
    }

    @Test
    func providerUsageIdentityAndDashboardAliasAreAccountScoped() {
        let account = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000a"
        )!
        let usage = ProviderUsage(
            provider: .openrouter,
            accountID: account,
            accountLabel: "Team",
            planName: "",
            groups: [],
            availability: .available,
            updatedAt: nil
        )

        #expect(
            usage.id
                == AccountProviderID(
                    accountID: account,
                    providerID: .openrouter
                )
        )
        #expect(
            DashboardAccountIdentityRule.showsAlias(
                for: usage,
                sameProviderCount: 1
            )
        )
        #expect(
            DashboardAccountIdentityRule.showsAlias(
                for: ProviderUsage(
                    provider: .openrouter,
                    planName: "",
                    groups: [],
                    availability: .available,
                    updatedAt: nil
                ),
                sameProviderCount: 2
            )
        )
        #expect(
            !DashboardAccountIdentityRule.showsAlias(
                for: ProviderUsage(
                    provider: .openrouter,
                    planName: "",
                    groups: [],
                    availability: .available,
                    updatedAt: nil
                ),
                sameProviderCount: 1
            )
        )
    }

    @Test
    func iconButtonsHaveOnePassiveRestAppearance() {
        let rest = InteractiveControlVisualState(
            isHovered: false,
            isPressed: false,
            reduceMotion: false
        )

        #expect(rest.foregroundRole == .passiveSecondary)
        #expect(rest.backgroundRole == .clear)
        #expect(rest.backgroundOpacity == 0)
    }

    @Test
    func statusItemUsesTheNativeTemplateSymbolContract() {
        #expect(
            StatusItemIconVisualTokens.symbolName
                == "gauge.with.dots.needle.50percent"
        )
        #expect(StatusItemIconVisualTokens.pointSize == 14)
        #expect(StatusItemIconVisualTokens.weight == .medium)
        #expect(StatusItemIconVisualTokens.renderingMode == .monochromeTemplate)
        let image = AppIconFactory.menuBarIcon()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 17, height: 17))
        #expect(
            image.alignmentRect == NSRect(origin: .zero, size: image.size)
        )
    }

    @Test
    func dashboardUsesNativeAnchoredPopoverAndSystemAppearance() {
        #expect(StatusPanelPresentationContract.usesNativePopover)
        #expect(!StatusPanelPresentationContract.drawsCustomPointer)
        #expect(StatusPanelPresentationContract.preferredEdge == .minY)

        let window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        AppAppearancePolicy.followSystem(on: window)
        #expect(window.appearance == nil)
    }

    @Test
    func shownPopoverStopsFollowingTheFullscreenMenuBarWindow() {
        let menuBarWindow = NSPanel(
            contentRect: NSRect(x: 1200, y: 1000, width: 40, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let popoverWindow = NSPanel(
            contentRect: NSRect(x: 1050, y: 780, width: 320, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        menuBarWindow.addChildWindow(popoverWindow, ordered: .above)
        let shownFrame = popoverWindow.frame

        StatusPopoverWindowStabilizer.detachFromMovingAnchor(
            popoverWindow
        )
        menuBarWindow.setFrameOrigin(
            NSPoint(x: menuBarWindow.frame.minX, y: 930)
        )

        #expect(popoverWindow.parent == nil)
        #expect(popoverWindow.frame == shownFrame)
        StatusPopoverWindowStabilizer.stopStabilizing(popoverWindow)
    }

    @Test
    func detachesAgainWhenAnchorReattaches() {
        let menuBarWindow = NSPanel(
            contentRect: NSRect(x: 1200, y: 1000, width: 40, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let popoverWindow = NSPanel(
            contentRect: NSRect(x: 1050, y: 780, width: 320, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        menuBarWindow.addChildWindow(popoverWindow, ordered: .above)
        let shownFrame = popoverWindow.frame

        StatusPopoverWindowStabilizer.detachFromMovingAnchor(
            popoverWindow
        )
        menuBarWindow.addChildWindow(popoverWindow, ordered: .above)
        menuBarWindow.setFrameOrigin(
            NSPoint(x: menuBarWindow.frame.minX, y: 930)
        )
        StatusPopoverWindowStabilizer.detachFromMovingAnchor(
            popoverWindow
        )

        #expect(popoverWindow.parent == nil)
        #expect(popoverWindow.frame == shownFrame)
        StatusPopoverWindowStabilizer.stopStabilizing(popoverWindow)
    }
}
