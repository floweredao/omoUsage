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
    }

    @Test
    func settingsPanesAreGroupedFormsWithoutCustomRowChrome() {
        #expect(SettingsFormVisualTokens.usesGroupedFormStyle)
        #expect(!SettingsFormVisualTokens.drawsCustomRowBackgrounds)
        #expect(SettingsFormVisualTokens.usesSemanticSystemColors)
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
        #expect(SideNotchAccountBadgeTokens.haloWidth > 0)
        #expect(SideNotchRailVisualTokens.emptyStateForegroundRole == .primaryDerived)
        #expect(SideNotchRailVisualTokens.emptyStateForeground == Color.primary)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for provider in ProviderID.allCases {
                var ratio = 0.0
                appearance.performAsCurrentDrawingAppearance {
                    guard
                        let backdrop = NSColor(
                            SideNotchNeutralVisualTokens.surface
                        ).usingColorSpace(.sRGB),
                        let plate = NSColor(
                            SideNotchAccountBadgeTokens.fill(for: provider)
                        ).usingColorSpace(.sRGB),
                        let glyph = NSColor(
                            SideNotchAccountBadgeTokens.foreground(
                                for: provider
                            )
                        ).usingColorSpace(.sRGB)
                    else {
                        return
                    }
                    ratio = Self.contrastRatio(
                        Self.composite(plate, over: backdrop),
                        Self.composite(glyph, over: backdrop)
                    )
                }
                #expect(
                    ratio >= 4.5,
                    "\(name.rawValue) \(provider) badge contrast \(ratio)"
                )
            }
        }
    }

    @Test
    func sideNotchRingsFollowTheProviderIconColor() throws {
        #expect(SideNotchUsageRisk.level(percentRemaining: 100) == .comfortable)
        #expect(SideNotchUsageRisk.level(percentRemaining: 50) == .comfortable)
        #expect(SideNotchUsageRisk.level(percentRemaining: 49) == .low)
        #expect(SideNotchUsageRisk.level(percentRemaining: 20) == .low)
        #expect(SideNotchUsageRisk.level(percentRemaining: 19) == .critical)
        #expect(SideNotchUsageRisk.level(percentRemaining: 0) == .critical)
        #expect(SideNotchUsageRisk.level(for: .quotaRemaining(percent: 7)) == .critical)
        #expect(SideNotchUsageRisk.level(for: .count(value: 3, unit: .requests)) == nil)

        // Ring and bar share the badge's color, so one provider is one color.
        for provider in ProviderID.allCases {
            #expect(
                (SideNotchBrandVisualTokens.lightRGB(for: provider) == nil)
                    == (SideNotchBrandVisualTokens.darkRGB(for: provider) == nil)
            )
        }
        for provider in [ProviderID.cursor, .copilot, .grok, .opencode] {
            #expect(
                SideNotchBrandVisualTokens.accent(for: provider)
                    == SideNotchNeutralVisualTokens.ink
            )
        }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for provider in ProviderID.allCases {
                let expected = name == .darkAqua
                    ? SideNotchBrandVisualTokens.darkRGB(for: provider)
                    : SideNotchBrandVisualTokens.lightRGB(for: provider)
                var resolved: NSColor?
                var badge: NSColor?
                var ratio = 0.0
                appearance.performAsCurrentDrawingAppearance {
                    guard
                        let backdrop = NSColor(
                            SideNotchNeutralVisualTokens.surface
                        ).usingColorSpace(.sRGB),
                        let ring = NSColor(
                            SideNotchBrandVisualTokens.accent(for: provider)
                        ).usingColorSpace(.sRGB)
                    else {
                        return
                    }
                    resolved = ring
                    badge = NSColor(
                        SideNotchAccountBadgeTokens.fill(for: provider)
                    ).usingColorSpace(.sRGB)
                    // Rings and bars are graphical objects: 3:1 against
                    // the opaque surface they are drawn on.
                    ratio = Self.contrastRatio(
                        Self.composite(backdrop, over: backdrop),
                        Self.composite(ring, over: backdrop)
                    )
                }
                let color = try #require(resolved)
                // Ring and badge resolve to one color for one provider.
                let plate = try #require(badge)
                #expect(plate.redComponent == color.redComponent)
                #expect(plate.greenComponent == color.greenComponent)
                #expect(plate.blueComponent == color.blueComponent)
                if let expected {
                    #expect(Int((color.redComponent * 255).rounded()) == Int(expected.red))
                    #expect(Int((color.greenComponent * 255).rounded()) == Int(expected.green))
                    #expect(Int((color.blueComponent * 255).rounded()) == Int(expected.blue))
                }
                #expect(
                    ratio >= 3,
                    "\(name.rawValue) \(provider) ring contrast \(ratio)"
                )
            }
        }
    }

    @Test
    func sideNotchKeepsNeutralForSurfaceAndStaleMarks() throws {
        #expect(EnvironmentValues().dashboardPalette == .standard)
        #expect(EnvironmentValues().sideNotchAccentProvider == nil)
        #expect(SideNotchNeutralVisualTokens.ink == Color.primary)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var surface: NSColor?
            var window: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                surface = NSColor(SideNotchNeutralVisualTokens.surface)
                    .usingColorSpace(.sRGB)
                window = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            let resolved = try #require(surface)
            let expected = try #require(
                name == .darkAqua
                    ? NSColor.black.usingColorSpace(.sRGB) : window
            )
            #expect(resolved.redComponent == expected.redComponent)
            #expect(resolved.greenComponent == expected.greenComponent)
            #expect(resolved.blueComponent == expected.blueComponent)
        }
    }

    @Test
    func sideNotchBubbleTailStaysInTheRailGapAndOffTheCorners() {
        #expect(
            SideNotchBubbleTokens.tailLength
                <= SideNotchPanelLayout.detailSpacing
        )
        let corner = SideNotchBubbleTokens.cornerRadius
        let half = SideNotchBubbleTokens.tailHalfHeight
        // Centered on its row when the row is inside the card's span.
        #expect(
            SideNotchBubbleTokens.tailCenterY(
                rowMidY: 140, cardTop: 60, cardHeight: 200
            ) == 80
        )
        // Clamped off the rounded corners at both ends.
        #expect(
            SideNotchBubbleTokens.tailCenterY(
                rowMidY: 0, cardTop: 60, cardHeight: 200
            ) == corner + half
        )
        #expect(
            SideNotchBubbleTokens.tailCenterY(
                rowMidY: 900, cardTop: 60, cardHeight: 200
            ) == 200 - corner - half
        )

        let card = CGRect(x: 0, y: 0, width: 280, height: 200)
        let bubble = SideNotchBubbleShape(
            cornerRadius: corner,
            tailCenterY: 80,
            tailHalfHeight: half,
            tailLength: SideNotchBubbleTokens.tailLength
        ).path(in: card)
        #expect(bubble.contains(CGPoint(x: 280 + 2, y: 80)))
        #expect(!bubble.contains(CGPoint(x: 280 + 2, y: 40)))
        #expect(bubble.boundingRect.maxX <= 280 + SideNotchPanelLayout.detailSpacing)
    }

    @Test
    func sideNotchRailFlowsIntoTheScreenEdgeThroughConcaveFillets() {
        let fillet = SideNotchPanelLayout.notchFilletRadius
        let rail = CGRect(x: 0, y: 0, width: 56, height: 300)
        let path = SideNotchRailShape(
            cornerRadius: SideNotchPanelLayout.railCornerRadius,
            filletRadius: fillet
        ).path(in: rail)
        // The screen-edge column stays filled through the fillet bands...
        #expect(path.contains(CGPoint(x: 55.5, y: fillet - 0.5)))
        #expect(path.contains(CGPoint(x: 55.5, y: 300 - fillet + 0.5)))
        // ...but the fillet band is open away from the edge.
        #expect(!path.contains(CGPoint(x: 28, y: fillet / 2)))
        #expect(!path.contains(CGPoint(x: 56 - fillet + 1, y: 1)))
        #expect(path.contains(CGPoint(x: 28, y: 150)))
        #expect(
            SideNotchPanelLayout.naturalRailHeight(providerCount: 0)
                == fillet * 2
                    + SideNotchPanelLayout.verticalPadding
                    + SideNotchPanelLayout.footerClearance
                    + SideNotchPanelLayout.footerHeight
        )
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
