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
    func providerSectionsFollowTheDesignTypeScale() {
        #expect(DashboardTypographyTokens.providerName == 15)
        #expect(DashboardTypographyTokens.planPill == 10.5)
        #expect(DashboardTypographyTokens.meterLabel == 12)
        #expect(DashboardTypographyTokens.meterValue == 12.5)
        #expect(DashboardTypographyTokens.metadata == 11)

        // Values outrank their labels, and labels outrank the reset and
        // freshness metadata beneath them.
        #expect(
            DashboardTypographyTokens.meterValue
                > DashboardTypographyTokens.meterLabel
        )
        #expect(
            DashboardTypographyTokens.meterLabel
                > DashboardTypographyTokens.metadata
        )
    }

    @Test
    func compactSurfacesKeepOverlayScrollers() {
        let scrollView = NSScrollView()
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false

        DashboardScrollerPolicy.apply(to: scrollView)

        #expect(DashboardScrollerPolicy.style == .overlay)
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers)
    }

    @Test
    func popoverBodyScrollerUsesTheOverlayStyle() async throws {
        let suite = "DashboardPopoverScrollerTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = UsageDashboardViewModel(
            providers: [ProviderID.claude, .codex].map {
                FixtureUsageProvider(id: $0, defaults: defaults)
            },
            now: { Date(timeIntervalSince1970: 1_785_675_000) }
        )
        await viewModel.refresh()
        #expect(viewModel.snapshot.providers.count == 2)
        let panelHeight = DashboardLayout.panelHeight(
            for: viewModel.snapshot.providers
        )
        let host = NSHostingView(
            rootView: DashboardView(
                viewModel: viewModel,
                localization: LocalizationController(
                    store: AppLanguageStore(defaults: defaults)
                ),
                onSettings: {},
                onQuit: {},
                onPanelHeightChange: { _ in }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 320,
                height: panelHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        let scrollView = try #require(
            firstDescendant(ofType: NSScrollView.self, in: host)
        )
        #expect(scrollView.scrollerStyle == DashboardScrollerPolicy.style)
        #expect(scrollView.autohidesScrollers)
        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.frame.width == 320)
        #expect(scrollView.contentSize.width == scrollView.frame.width)

        // The configurator sits inside the popover body's scroll view, so a
        // legacy style reset by AppKit is undone on that same view and the
        // content keeps the full 320 pt width.
        let configurator = try #require(
            firstDescendant(
                ofType: DashboardScrollerConfigurator.ConfiguratorView.self,
                in: host
            )
        )
        #expect(configurator.enclosingScrollView === scrollView)
        scrollView.scrollerStyle = .legacy
        configurator.applyPolicy()
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.contentSize.width == scrollView.frame.width)
    }

    @Test
    func sideNotchAccountBadgeIsLegibleOnTheDimmedRail() throws {
        #expect(SideNotchAccountBadgeTokens.fontSize >= 9)
        #expect(SideNotchAccountBadgeTokens.fontWeight == .semibold)
        #expect(SideNotchAccountBadgeTokens.diameter >= 16)
        #expect(
            SideNotchAccountBadgeTokens.diameter
                > SideNotchAccountBadgeTokens.fontSize
        )
        #expect(SideNotchRailVisualTokens.emptyStateForegroundRole == .primaryDerived)
        #expect(SideNotchRailVisualTokens.emptyStateForeground == Color.primary)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var ratio = 0.0
            appearance.performAsCurrentDrawingAppearance {
                guard
                    let backdrop = NSColor.windowBackgroundColor
                        .usingColorSpace(.sRGB),
                    let plate = NSColor(SideNotchAccountBadgeTokens.fill)
                        .usingColorSpace(.sRGB),
                    let glyph = NSColor(SideNotchAccountBadgeTokens.foreground)
                        .usingColorSpace(.sRGB)
                else {
                    return
                }
                ratio = Self.contrastRatio(
                    Self.composite(plate, over: backdrop),
                    Self.composite(glyph, over: backdrop)
                )
            }
            #expect(ratio >= 4.5, "\(name.rawValue) badge contrast \(ratio)")
        }
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

    private func firstDescendant<ViewType: NSView>(
        ofType type: ViewType.Type,
        in view: NSView
    ) -> ViewType? {
        if let match = view as? ViewType {
            return match
        }
        for subview in view.subviews {
            if let match = firstDescendant(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private static func composite(
        _ color: NSColor,
        over backdrop: NSColor
    ) -> (red: Double, green: Double, blue: Double) {
        let alpha = color.alphaComponent
        func blend(_ top: CGFloat, _ bottom: CGFloat) -> Double {
            Double(top * alpha + bottom * (1 - alpha))
        }
        return (
            blend(color.redComponent, backdrop.redComponent),
            blend(color.greenComponent, backdrop.greenComponent),
            blend(color.blueComponent, backdrop.blueComponent)
        )
    }

    private static func contrastRatio(
        _ first: (red: Double, green: Double, blue: Double),
        _ second: (red: Double, green: Double, blue: Double)
    ) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        func luminance(
            _ color: (red: Double, green: Double, blue: Double)
        ) -> Double {
            0.2126 * linear(color.red)
                + 0.7152 * linear(color.green)
                + 0.0722 * linear(color.blue)
        }
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
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
