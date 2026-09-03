import AppKit
import SwiftUI
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

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
    func tailscaleQRCodeKeepsScannableQuietZone() {
        #expect(
            TailscaleQRCodeVisualTokens.quietZoneModules >= 4
        )
        #expect(TailscaleQRCodeVisualTokens.moduleScale >= 1)
    }

    @Test
    func providerMetadataUsesPrimaryDerivedForegroundOverDimmedMaterial() {
        // The side-notch panel never becomes key, so system secondary text
        // renders there in its permanently dimmed form. Meter reset lines
        // and the freshness timestamps beside them share one
        // primary-derived foreground at a pinned alpha.
        #expect(ProviderMetadataVisualTokens.role == .primaryDerived)
        #expect(ProviderMetadataVisualTokens.role != .systemSecondary)
        #expect(ProviderMetadataVisualTokens.opacity == 1)
        #expect(
            ProviderMetadataVisualTokens.foreground == Color.primary
        )
        #expect(
            ProviderMetadataVisualTokens.foreground != Color.secondary
        )

        // Measured QA: nothing below full primary clears 4.5:1 on the
        // dimmed baseline, so the floor is full strength.
        #expect(ProviderMetadataVisualTokens.minimumOpacity == 1)
        #expect(
            ProviderMetadataVisualTokens.opacity
                >= ProviderMetadataVisualTokens.minimumOpacity
        )
        #expect(ProviderMetadataVisualTokens.opacity > 0)
        #expect(ProviderMetadataVisualTokens.opacity <= 1)
    }

    @Test
    func sideNotchDetailUsesRestrainedDownwardElevation() throws {
        // The captured recipe was black 0.16 / radius 10 / y 4: a blur two
        // and a half times the offset, so it read as an omnidirectional
        // bloom that lightened the dark backdrop instead of a lit edge.
        #expect(SideNotchDetailElevationTokens.shadowOpacity == 0.12)
        #expect(SideNotchDetailElevationTokens.shadowOpacity < 0.16)
        #expect(SideNotchDetailElevationTokens.shadowRadius == 4)
        #expect(SideNotchDetailElevationTokens.shadowRadius < 10)
        #expect(SideNotchDetailElevationTokens.shadowOffsetY == 2)
        #expect(SideNotchDetailElevationTokens.shadowOffsetY > 0)
        #expect(SideNotchDetailElevationTokens.shadowOffsetY < 4)

        // Blur never swamps the offset, so elevation stays directional.
        #expect(
            SideNotchDetailElevationTokens.shadowRadius
                <= SideNotchDetailElevationTokens.shadowOffsetY * 2
        )

        // Dark in both appearances: the card can only darken its backdrop,
        // never glow against it.
        let shadow = try #require(
            NSColor(SideNotchDetailElevationTokens.shadowColor)
                .usingColorSpace(.sRGB)
        )
        #expect(shadow.brightnessComponent <= 0.05)
        #expect(shadow.redComponent <= 0.05)
        #expect(shadow.greenComponent <= 0.05)
        #expect(shadow.blueComponent <= 0.05)
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
    func dashboardProviderAccessibilityIdentifierIsAccountScoped() {
        let usage = ProviderUsage(
            provider: .codex,
            accountID: AccountID(
                rawValue: "00000000-0000-0000-0000-00000000000b"
            )!,
            accountLabel: "QA-Second",
            planName: "",
            groups: [],
            availability: .available,
            updatedAt: nil
        )

        #expect(
            DashboardProviderSectionAccessibility.identifier(for: usage)
                == "dashboard-provider-codex-QA-Second"
        )
    }

    @Test
    func staleUsageKeepsItsMetersAndGainsANonColorOnlyBadge() {
        let stale = ProviderUsage(
            provider: .codex,
            planName: "Pro",
            groups: [
                UsageGroup(
                    id: "codex",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "codex.week",
                            title: "주간",
                            period: .week,
                            percentRemaining: 73
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_785_675_000),
            lastRefreshAttemptAt: Date(
                timeIntervalSince1970: 1_785_675_600
            ),
            refreshFailure: .network
        )
        let display = DashboardLayout.freshnessDisplay(for: stale)

        #expect(stale.availability == .available)
        #expect(!stale.groups.isEmpty)
        #expect(display.showsStaleBadge)
        #expect(display.successAt != display.attemptAt)
        #expect(StaleUsageVisualTokens.usesTextLabel)
        #expect(!StaleUsageVisualTokens.symbolName.isEmpty)
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
