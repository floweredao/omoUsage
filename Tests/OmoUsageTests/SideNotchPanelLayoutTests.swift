import AppKit
import SwiftUI
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
@MainActor
struct SideNotchPanelLayoutTests {
    @Test(arguments: [56.0, 344.0], [0, 2])
    func footerMenuControlStaysInsideRail(
        panelWidth: Double,
        providerCount: Int
    ) async throws {
        let suite = "SideNotchFooterTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let providers: [ProviderID] = [.codex, .claude]
        let viewModel = UsageDashboardViewModel(
            providers: providers.prefix(providerCount).map {
                FixtureUsageProvider(id: $0, defaults: defaults)
            },
            now: { Date(timeIntervalSince1970: 1_785_675_000) }
        )
        await viewModel.refresh()
        #expect(viewModel.snapshot.providers.count == providerCount)
        let state = SideNotchPanelState()
        state.toggleRevealed()
        if panelWidth == 344, providerCount > 0 {
            state.select(.codex)
        }
        let host = NSHostingView(
            rootView: SideNotchPanelView(
                viewModel: viewModel,
                localization: LocalizationController(
                    store: AppLanguageStore(defaults: defaults)
                ),
                state: state,
                onSelectionIntent: { _, _ in },
                onKeyboardFocusTarget: { _ in },
                onProviderCountChange: { _ in },
                onPointerEntered: { _ in },
                onPointerExited: {},
                onRefresh: {},
                onSettings: {},
                onQuit: {}
            )
            .frame(width: panelWidth, height: 428)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 428),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let menu = try #require(
            descendants(host).compactMap { $0 as? NSPopUpButton }.first
        )
        let rect = host.convert(menu.bounds, from: menu)
        let imageRect = try #require(menu.cell?.imageRect(forBounds: menu.bounds))
        let railCenter = panelWidth - 28
        #expect(abs(host.convert(imageRect, from: menu).midX - railCenter) <= 1)
        #expect(rect.minX >= panelWidth - 56)
        #expect(rect.maxX <= host.bounds.maxX)
        // AppKit excludes the popup's asymmetric bezel inset from alignment.
        let alignmentRect = host.convert(
            menu.alignmentRect(forFrame: menu.frame),
            from: menu.superview
        )
        #expect(abs(alignmentRect.midX - railCenter) <= 1)
    }

    @Test
    func detailHeightMatchesRenderedProviderSection() {
        let claude = ProviderUsage(
            provider: .claude,
            planName: "Max 5x",
            groups: [
                UsageGroup(
                    id: "claude.main",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "claude.session",
                            title: "Session (5 hours)",
                            period: .session,
                            percentRemaining: 65
                        ),
                        UsageMeter(
                            id: "claude.week",
                            title: "Weekly",
                            period: .week,
                            percentRemaining: 45
                        ),
                        UsageMeter(
                            id: "claude.week.model.fable",
                            title: "Fable weekly",
                            period: .week,
                            percentRemaining: 28
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: nil
        )
        let contentWidth = SideNotchPanelLayout.detailWidth
            - SideNotchPanelLayout.detailContentPadding * 2
        let hostingView = NSHostingView(
            rootView:
                ProviderSectionView(usage: claude)
                .frame(width: contentWidth)
        )
        let renderedHeight = hostingView.fittingSize.height
            + SideNotchPanelLayout.detailContentPadding * 2

        #expect(
            abs(
                SideNotchPanelLayout.detailHeight(for: claude)
                    - renderedHeight
            ) <= 1
        )
    }

    @Test
    func detailViewDoesNotInstallScrollView() {
        let usage = capturedTwoProviderUsage()[1]
        let hostingView = NSHostingView(
            rootView:
                SideNotchDetailView(
                    usage: usage,
                    showsAccountLabel: false
                )
                .frame(width: SideNotchPanelLayout.detailWidth)
        )
        hostingView.frame.size = hostingView.fittingSize
        hostingView.layoutSubtreeIfNeeded()

        #expect(
            !containsDescendant(
                ofType: NSScrollView.self,
                in: hostingView
            )
        )
    }

    @Test
    func tallDetailHeightMatchesRenderedProviderSection() {
        let usage = detailUsage(meterCount: 6)
        let contentWidth = SideNotchPanelLayout.detailWidth
            - SideNotchPanelLayout.detailContentPadding * 2
        let hostingView = NSHostingView(
            rootView:
                ProviderSectionView(usage: usage)
                .frame(width: contentWidth)
        )
        let renderedHeight = hostingView.fittingSize.height
            + SideNotchPanelLayout.detailContentPadding * 2

        #expect(
            abs(
                SideNotchPanelLayout.detailHeight(for: usage)
                    - renderedHeight
            ) <= 1
        )
        #expect(renderedHeight > 320)
    }

    @Test
    func accountLabelDetailHeightMatchesRenderedProviderSection() {
        let usage = detailUsage(meterCount: 3)
        let contentWidth = SideNotchPanelLayout.detailWidth
            - SideNotchPanelLayout.detailContentPadding * 2
        let hostingView = NSHostingView(
            rootView:
                ProviderSectionView(
                    usage: usage,
                    showsAccountLabel: true
                )
                .frame(width: contentWidth)
        )
        let renderedHeight = hostingView.fittingSize.height
            + SideNotchPanelLayout.detailContentPadding * 2

        #expect(
            abs(
                SideNotchPanelLayout.detailHeight(
                    for: usage,
                    showsAccountLabel: true
                ) - renderedHeight
            ) <= 1
        )
    }

    @Test
    func koreanDetailHeightMatchesRenderedProviderSection() {
        let codex = ProviderUsage(
            provider: .codex,
            planName: "플러스",
            groups: [
                UsageGroup(
                    id: "codex.main",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "codex.session",
                            title: "세션 (5시간)",
                            period: .session,
                            percentRemaining: 60,
                            resetText: "3시간 후 리셋"
                        ),
                        UsageMeter(
                            id: "codex.week",
                            title: "주간",
                            period: .week,
                            percentRemaining: 88,
                            resetText: "5일 후 리셋"
                        ),
                        UsageMeter(
                            id: "codex.credits",
                            title: "크레딧",
                            period: .extra,
                            metric: .credit(
                                balance: 0,
                                unit: .credits
                            )
                        ),
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: nil
        )
        let contentWidth = SideNotchPanelLayout.detailWidth
            - SideNotchPanelLayout.detailContentPadding * 2
        let hostingView = NSHostingView(
            rootView:
                ProviderSectionView(usage: codex)
                .frame(width: contentWidth)
                .environment(
                    \.appLocalization,
                    LocalizationContext(language: .korean)
                )
        )
        let renderedHeight = hostingView.fittingSize.height
            + SideNotchPanelLayout.detailContentPadding * 2
        let reservedHeight =
            SideNotchPanelLayout.detailHeight(
                for: codex,
                language: .korean
            )

        #expect(reservedHeight >= renderedHeight)
        #expect(reservedHeight - renderedHeight <= 1)
    }

    @Test
    func detailPanelContainsCardMarginsWithoutClipping() {
        let claude = ProviderUsage(
            provider: .claude,
            planName: "Max 5x",
            groups: [
                UsageGroup(
                    id: "claude.main",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "claude.session",
                            title: "Session",
                            period: .session,
                            percentRemaining: 65
                        ),
                        UsageMeter(
                            id: "claude.week",
                            title: "Weekly",
                            period: .week,
                            percentRemaining: 45
                        ),
                        UsageMeter(
                            id: "claude.fable",
                            title: "Fable weekly",
                            period: .week,
                            percentRemaining: 28
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: nil
        )
        let frame = SideNotchPanelLayout.frame(
            in: NSRect(x: 0, y: 25, width: 1_920, height: 1_055),
            providerCount: 2,
            mode: .detail(.claude),
            anchorY: 500,
            presentedContentMinimumHeight:
                SideNotchPanelLayout.requiredPanelHeight(
                    for: claude
                )
        )

        #expect(
            frame.height
                >= SideNotchPanelLayout.requiredPanelHeight(
                    for: claude
                )
        )
    }

    @Test
    func revealedRailStaysNaturalWhileDetailReservesTallestHeight() {
        let usage = ProviderUsage(
            provider: .claude,
            planName: "Max 5x",
            groups: [
                UsageGroup(
                    id: "claude.main",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "claude.session",
                            title: "Session",
                            period: .session,
                            percentRemaining: 65
                        ),
                        UsageMeter(
                            id: "claude.week",
                            title: "Weekly",
                            period: .week,
                            percentRemaining: 45
                        ),
                        UsageMeter(
                            id: "claude.fable",
                            title: "Fable weekly",
                            period: .week,
                            percentRemaining: 28
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: nil
        )
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_055
        )

        let revealed = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: [usage],
            mode: .revealed,
            anchorY: 780
        )
        let detail = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: [usage],
            mode: .detail(.claude),
            anchorY: 780
        )

        #expect(
            revealed.height
                == SideNotchPanelLayout.verticalPadding
                    + SideNotchPanelLayout.providerRowHeight
                    + SideNotchPanelLayout.footerClearance
                    + SideNotchPanelLayout.footerHeight
        )
        #expect(
            detail.height
                == SideNotchPanelLayout.requiredPanelHeight(
                    for: usage
                )
        )
        #expect(detail.height > revealed.height)
        #expect(detail.maxY == revealed.maxY)
        #expect(detail.maxX == revealed.maxX)
    }

    @Test
    func detailTransitionPreservesRailTopEdge() {
        let providers = capturedTwoProviderUsage()
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_055
        )
        let revealed = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .revealed,
            anchorY: 780
        )
        let detail = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .detail(.claude),
            anchorY: 780
        )

        #expect(detail.height > revealed.height)
        #expect(detail.maxY == revealed.maxY)
        #expect(detail.maxX == revealed.maxX)
        #expect(detail.minY >= visibleFrame.minY + 20)
        #expect(detail.maxY <= visibleFrame.maxY - 20)
    }

    @Test
    func revealedRailUsesNaturalHeightInsteadOfTallestDetail() {
        // Mirrors the supplied two-provider capture: a Codex ring above a
        // Claude Code "Max 5x" detail whose three resetting meters and
        // "as of" row make it the tallest provider detail.
        let codex = ProviderUsage(
            provider: .codex,
            planName: "Plus",
            groups: [
                UsageGroup(
                    id: "codex.main",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "codex.session",
                            title: "Session (5 hours)",
                            period: .session,
                            percentRemaining: 32,
                            resetText: "Resets in 2 hr 10 min"
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: nil
        )
        let claude = ProviderUsage(
            provider: .claude,
            planName: "Max 5x",
            groups: [
                UsageGroup(
                    id: "claude.main",
                    title: nil,
                    meters: [
                        UsageMeter(
                            id: "claude.session",
                            title: "Session (5 hours)",
                            period: .session,
                            percentRemaining: 95,
                            resetText: "Resets in 4 hr 44 min"
                        ),
                        UsageMeter(
                            id: "claude.week",
                            title: "Weekly",
                            period: .week,
                            percentRemaining: 18,
                            resetText: "Resets in 1 days"
                        ),
                        UsageMeter(
                            id: "claude.week.model.fable",
                            title: "Fable weekly",
                            period: .week,
                            percentRemaining: 25,
                            resetText: "Resets in 1 days"
                        )
                    ],
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: Date(timeIntervalSince1970: 1_764_590_040)
        )
        let providers = [codex, claude]
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_055
        )
        let pointerAnchorY: CGFloat = 780

        let naturalRailHeight =
            SideNotchPanelLayout.verticalPadding
            + CGFloat(providers.count)
                * SideNotchPanelLayout.providerRowHeight
            + SideNotchPanelLayout.footerClearance
            + SideNotchPanelLayout.footerHeight
        let tallestDetailHeight =
            providers
            .map { SideNotchPanelLayout.requiredPanelHeight(for: $0) }
            .max() ?? 0

        let revealed = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .revealed,
            anchorY: pointerAnchorY
        )
        let detail = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .detail(.claude),
            anchorY: pointerAnchorY
        )

        // Fixture guard: without a detail taller than the rail the
        // criterion below would pass vacuously.
        #expect(tallestDetailHeight > naturalRailHeight)

        // The revealed rail owns its own height: provider rows plus
        // padding and footer, never the tallest detail's reservation.
        #expect(revealed.height == naturalRailHeight)

        // Detail may stay taller, and neither mode leaves the right edge.
        #expect(detail.height >= tallestDetailHeight)
        #expect(
            revealed.width == SideNotchPanelLayout.collapsedWidth
        )
        #expect(detail.width == SideNotchPanelLayout.expandedWidth)
        #expect(revealed.maxX == visibleFrame.maxX)
        #expect(detail.maxX == revealed.maxX)
        #expect(revealed.midY == pointerAnchorY)
    }

    @Test
    func railContentStopsAtNaturalHeightInsideTallerDetailContainer() {
        let providers = capturedTwoProviderUsage()
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_055
        )
        let pointerAnchorY: CGFloat = 780

        let naturalRailHeight = SideNotchPanelLayout.naturalRailHeight(
            providerCount: providers.count
        )
        let revealed = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .revealed,
            anchorY: pointerAnchorY
        )
        let detail = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .detail(.claude),
            anchorY: pointerAnchorY
        )

        #expect(
            naturalRailHeight
                == SideNotchPanelLayout.verticalPadding
                    + CGFloat(providers.count)
                        * SideNotchPanelLayout.providerRowHeight
                    + SideNotchPanelLayout.footerClearance
                    + SideNotchPanelLayout.footerHeight
        )

        // The detail container is legitimately taller than the rail.
        #expect(detail.height > naturalRailHeight)

        // The rail view must not stretch to fill it.
        #expect(
            SideNotchPanelLayout.railContentHeight(
                providerCount: providers.count,
                containerHeight: detail.height
            ) == naturalRailHeight
        )
        #expect(
            SideNotchPanelLayout.railContentHeight(
                providerCount: providers.count,
                containerHeight: revealed.height
            ) == naturalRailHeight
        )

        // The zero-provider checking state still uses the container.
        #expect(
            SideNotchPanelLayout.railContentHeight(
                providerCount: 0,
                containerHeight: detail.height
            ) == detail.height
        )

        // A crowded rail keeps the container height and scrolls inside it.
        let crowdedContainer = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 9,
            mode: .revealed
        ).height
        #expect(
            SideNotchPanelLayout.naturalRailHeight(providerCount: 9)
                > crowdedContainer
        )
        #expect(
            SideNotchPanelLayout.railContentHeight(
                providerCount: 9,
                containerHeight: crowdedContainer
            ) == crowdedContainer
        )
    }

    @Test
    func detailReservesRoomToAlignEachCardWithItsRow() {
        let providers = capturedTwoProviderUsage()
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_055
        )
        let revealed = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .revealed,
            anchorY: 780
        )
        let detail = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .detail(.claude),
            anchorY: 780
        )

        for (index, usage) in providers.enumerated() {
            let rowMidY = SideNotchPanelLayout.verticalPadding / 2
                + CGFloat(index) * SideNotchPanelLayout.providerRowHeight
                + SideNotchPanelLayout.providerRowHeight / 2
            let cardHeight = SideNotchPanelLayout.detailHeight(for: usage)
            #expect(
                SideNotchPanelLayout.detailTop(
                    rowMidY: rowMidY,
                    detailHeight: cardHeight,
                    containerHeight: detail.height
                ) == max(0, rowMidY - cardHeight / 2)
            )
        }
        #expect(detail.maxY == revealed.maxY)

        let lowRevealed = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .revealed,
            anchorY: 120
        )
        let lowDetail = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .detail(.claude),
            anchorY: 120
        )
        #expect(lowDetail.maxX == lowRevealed.maxX)
        #expect(
            lowDetail.height
                >= providers
                .map { SideNotchPanelLayout.requiredPanelHeight(for: $0) }
                .max() ?? 0
        )
        #expect(lowDetail.minY >= visibleFrame.minY + 20)
    }

    @Test
    func crowdedRailStillTopAlignsTheLastRowsTallCard() {
        let small = capturedTwoProviderUsage()[0]
        let tall = capturedTwoProviderUsage()[1]
        let smallProviders: [ProviderID] = [
            .codex, .cursor, .copilot, .antigravity,
            .devin, .grok, .opencode, .openrouter
        ]
        let providers = smallProviders.map {
            ProviderUsage(
                provider: $0,
                planName: small.planName,
                groups: small.groups,
                availability: .available,
                updatedAt: nil
            )
        } + [tall]
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_055
        )
        let revealed = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .revealed,
            anchorY: 780
        )
        let detail = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .detail(.claude),
            anchorY: 780
        )
        let lastRowMidY = SideNotchPanelLayout.verticalPadding / 2
            + CGFloat(providers.count - 1)
                * SideNotchPanelLayout.providerRowHeight
            + SideNotchPanelLayout.providerRowHeight / 2
        let tallHeight = SideNotchPanelLayout.detailHeight(for: tall)

        #expect(revealed.height == SideNotchPanelLayout.maximumPanelHeight)
        #expect(detail.maxY == revealed.maxY)
        #expect(
            SideNotchPanelLayout.detailTop(
                rowMidY: lastRowMidY,
                detailHeight: tallHeight,
                containerHeight: detail.height
            ) == lastRowMidY - tallHeight / 2
        )
        #expect(
            SideNotchPanelLayout.railContentHeight(
                providerCount: providers.count,
                containerHeight: detail.height
            ) == revealed.height
        )
    }

    @Test
    func revealAnchorChangesOnlyForHiddenEdgeEntry() {
        #expect(
            SideNotchRevealAnchorPolicy.anchorY(
                current: nil,
                for: .pointerEntered(
                    mode: .hidden,
                    screenY: 780
                )
            ) == 780
        )
        #expect(
            SideNotchRevealAnchorPolicy.anchorY(
                current: 780,
                for: .pointerEntered(
                    mode: .revealed,
                    screenY: 1_000
                )
            ) == 780
        )
        #expect(
            SideNotchRevealAnchorPolicy.anchorY(
                current: 780,
                for: .programmatic
            ) == nil
        )
    }

    @Test(arguments: [1, 2, 6, 11])
    func programmaticRevealMatchesHoverRevealHeight(providerCount: Int) {
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_055
        )
        let rowGroups = capturedTwoProviderUsage()[0].groups
        let providers = (0..<providerCount).map { index in
            ProviderUsage(
                provider: ProviderID.allCases[
                    index % ProviderID.allCases.count
                ],
                accountLabel: "Account \(index)",
                planName: "Plus",
                groups: rowGroups,
                availability: .available,
                updatedAt: nil
            )
        }
        let pointerY: CGFloat = 780

        let programmatic = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .revealed,
            anchorY: SideNotchRevealAnchorPolicy.anchorY(
                current: pointerY,
                for: .programmatic
            )
        )
        let hover = SideNotchPanelLayout.presentationFrame(
            in: visibleFrame,
            providers: providers,
            mode: .revealed,
            anchorY: SideNotchRevealAnchorPolicy.anchorY(
                current: nil,
                for: .pointerEntered(mode: .hidden, screenY: pointerY)
            )
        )

        #expect(programmatic.height == hover.height)
        #expect(programmatic.width == hover.width)
        #expect(programmatic.maxX == hover.maxX)
        #expect(
            programmatic.height
                == min(
                    SideNotchPanelLayout.maximumPanelHeight,
                    SideNotchPanelLayout.naturalRailHeight(
                        providerCount: providerCount
                    )
                )
        )
        #expect(programmatic.height > SideNotchPanelLayout.minimumHeight)
        #expect(programmatic.midY == visibleFrame.midY)
        #expect(hover.midY == pointerY)
    }

    @Test
    func frameUpdatesDuringAnInFlightRevealRetargetTheAnimation() {
        #expect(
            SideNotchFrameUpdatePolicy.animates(
                requested: false,
                animationInFlight: true,
                mode: .revealed
            )
        )
        #expect(
            SideNotchFrameUpdatePolicy.animates(
                requested: false,
                animationInFlight: true,
                mode: .detail(.codex)
            )
        )
        #expect(
            !SideNotchFrameUpdatePolicy.animates(
                requested: false,
                animationInFlight: false,
                mode: .revealed
            )
        )
        #expect(
            !SideNotchFrameUpdatePolicy.animates(
                requested: false,
                animationInFlight: true,
                mode: .hidden
            )
        )
        #expect(
            SideNotchFrameUpdatePolicy.animates(
                requested: true,
                animationInFlight: false,
                mode: .hidden
            )
        )
    }

    @Test
    func railScrollerKeepsTheOverlayStyle() async throws {
        let suite = "SideNotchRailScrollerTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = UsageDashboardViewModel(
            providers: [ProviderID.codex, .claude].map {
                FixtureUsageProvider(id: $0, defaults: defaults)
            },
            now: { Date(timeIntervalSince1970: 1_785_675_000) }
        )
        await viewModel.refresh()
        #expect(viewModel.snapshot.providers.count == 2)
        let state = SideNotchPanelState()
        state.toggleRevealed()
        let host = NSHostingView(
            rootView: SideNotchPanelView(
                viewModel: viewModel,
                localization: LocalizationController(
                    store: AppLanguageStore(defaults: defaults)
                ),
                state: state,
                onSelectionIntent: { _, _ in },
                onKeyboardFocusTarget: { _ in },
                onProviderCountChange: { _ in },
                onPointerEntered: { _ in },
                onPointerExited: {},
                onRefresh: {},
                onSettings: {},
                onQuit: {}
            )
            .frame(width: 56, height: 196)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 56, height: 196),
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
        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers)
        #expect(scrollView.hasVerticalScroller)

        // The configurator sits inside the rail's scroll view, so a style
        // reset by AppKit is undone by the same object on the same view.
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
    }

    @Test
    func hiddenActivationFrameSpansTheFullVisibleHeight() {
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_000
        )

        let hiddenTrigger = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .hidden
        )

        #expect(
            hiddenTrigger.size
                == NSSize(
                    width: SideNotchPanelLayout.hiddenTrackingWidth,
                    height: visibleFrame.height
                )
        )
        #expect(hiddenTrigger.minY == visibleFrame.minY)
        #expect(hiddenTrigger.maxY == visibleFrame.maxY)
        #expect(hiddenTrigger.maxX == visibleFrame.maxX)
        #expect(SideNotchPanelLayout.hiddenWidth == 6)
        #expect(SideNotchPanelLayout.hiddenTrackingWidth == 8)
    }

    @Test
    func hiddenActivationIncludesTopMiddleAndBottomEdgeInput() {
        let visibleFrame = NSRect(
            x: 100,
            y: 50,
            width: 1_400,
            height: 900
        )
        let hiddenTrigger = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .hidden
        )

        #expect(
            hiddenTrigger.contains(
                NSPoint(x: visibleFrame.maxX - 1, y: visibleFrame.minY + 40)
            )
        )
        #expect(
            hiddenTrigger.contains(
                NSPoint(x: visibleFrame.maxX - 1, y: visibleFrame.maxY - 40)
            )
        )
        #expect(
            hiddenTrigger.contains(
                NSPoint(x: visibleFrame.maxX - 1, y: visibleFrame.midY)
            )
        )
    }

    @Test
    func hiddenActivationGeometryIgnoresRevealAnchor() {
        let visibleFrame = NSRect(
            x: -1_600,
            y: 50,
            width: 1_600,
            height: 900
        )

        let hiddenActivationFrame = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .hidden
        )
        let anchored = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .hidden,
            anchorY: 640
        )
        let clampedBottom = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .hidden,
            anchorY: 60
        )
        let clampedTop = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .hidden,
            anchorY: 940
        )

        #expect(anchored == hiddenActivationFrame)
        #expect(clampedBottom == hiddenActivationFrame)
        #expect(clampedTop == hiddenActivationFrame)
        #expect(hiddenActivationFrame.minY == visibleFrame.minY)
        #expect(hiddenActivationFrame.maxY == visibleFrame.maxY)
        #expect(hiddenActivationFrame.maxX == visibleFrame.maxX)
    }

    @Test
    func revealedRailUsesPointerAnchorWithoutChangingPresentedGeometry() {
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_000
        )
        let pointerY: CGFloat = 780

        let rail = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .revealed,
            anchorY: pointerY
        )
        let detail = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .detail(.claude),
            anchorY: pointerY
        )

        #expect(rail.midY == pointerY)
        #expect(rail.width == SideNotchPanelLayout.collapsedWidth)
        #expect(detail.width == SideNotchPanelLayout.expandedWidth)
        #expect(detail.height == rail.height)
        #expect(detail.minY == rail.minY)
        #expect(detail.maxX == rail.maxX)
    }

    @Test
    func hideAnimationTargetPreservesFullTrackingStripInPlace() {
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_000
        )
        let rail = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .revealed,
            anchorY: 800
        )

        let edgeFrame = SideNotchPanelLayout.hideAnimationTarget(
            in: visibleFrame,
            from: rail
        )

        #expect(edgeFrame.width == SideNotchPanelLayout.hiddenTrackingWidth)
        #expect(edgeFrame.maxX == rail.maxX)
        #expect(edgeFrame.minY == rail.minY)
        #expect(edgeFrame.height == rail.height)
    }

    @Test
    func pointerAtRightEdgeSchedulesRevealAcrossFullVisibleHeight() throws {
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_920,
            height: 1_000
        )
        let rail = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 2,
            mode: .revealed,
            anchorY: visibleFrame.midY
        )

        let target = SideNotchPanelLayout.hideAnimationTarget(
            in: visibleFrame,
            from: rail
        )

        #expect(target.width == SideNotchPanelLayout.hiddenTrackingWidth)
        for y in [target.minY + 1, target.midY, target.maxY - 1] {
            #expect(target.contains(NSPoint(x: target.maxX - 7, y: y)))
        }

        let fixture = try controllerFixture()
        defer { fixture.controller.stop() }

        fixture.controller.pointerEntered()

        #expect(fixture.scheduler.jobs.count == 1)
        #expect(fixture.scheduler.jobs[0].delay == 0.18)

        fixture.scheduler.fire(0)
        #expect(fixture.controller.mode == .revealed)
    }

    @Test
    func compactRailUsesReducedGeometry() {
        let visibleFrame = NSRect(
            x: 0,
            y: 0,
            width: 1_920,
            height: 1_055
        )

        let rail = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 8,
            isExpanded: false
        )
        let detail = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 8,
            isExpanded: true
        )
        let crowdedRail = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 9,
            isExpanded: false
        )

        #expect(rail.width == 56)
        #expect(rail.height <= 540)
        #expect(detail.width == 344)
        #expect(detail.maxX == rail.maxX)
        #expect(SideNotchPanelLayout.providerRowHeight == 58)
        #expect(crowdedRail.height <= 540)
    }

    @Test
    func pinsCollapsedRailToVisibleRightEdge() {
        let visibleFrame = NSRect(
            x: 100,
            y: 50,
            width: 1_400,
            height: 900
        )

        let frame = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 3,
            isExpanded: false
        )

        #expect(frame.width == 56)
        #expect(frame.maxX == visibleFrame.maxX)
        #expect(frame.midY == visibleFrame.midY)
    }

    @Test
    func expandsInwardWithoutMovingTheRightEdge() {
        let visibleFrame = NSRect(
            x: 0,
            y: 0,
            width: 1_920,
            height: 1_055
        )

        let collapsed = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 5,
            isExpanded: false
        )
        let expanded = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 5,
            isExpanded: true
        )

        #expect(expanded.width == 344)
        #expect(expanded.maxX == collapsed.maxX)
        #expect(expanded.minX < collapsed.minX)
    }

    @Test
    func footerClearanceIsIncludedBeforeControls() {
        let visibleFrame = NSRect(
            x: 0,
            y: 0,
            width: 1_920,
            height: 1_080
        )

        let frame = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 7,
            isExpanded: false
        )

        #expect(SideNotchPanelLayout.footerClearance >= 8)
        #expect(
            frame.height
                == SideNotchPanelLayout.verticalPadding
                    + 7 * SideNotchPanelLayout.providerRowHeight
                    + SideNotchPanelLayout.footerClearance
                    + SideNotchPanelLayout.footerHeight
        )
    }

    @Test
    func clampsTheRailInsideShortVisibleFrames() {
        let visibleFrame = NSRect(
            x: 0,
            y: 25,
            width: 1_280,
            height: 620
        )

        let frame = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: ProviderID.allCases.count,
            isExpanded: false
        )

        #expect(frame.minY >= visibleFrame.minY + 20)
        #expect(frame.maxY <= visibleFrame.maxY - 20)
        #expect(frame.height == 540)
    }

    @Test
    func panelUsesAVisibleNonactivatingFloatingContract() {
        let panel = SideNotchPanelController.makePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 72,
                height: 240
            )
        )

        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.isOpaque)
        #expect(!panel.hidesOnDeactivate)
    }

    @Test
    func reduceMotionDisablesRequestedPanelAnimation() {
        #expect(
            SideNotchMotionPolicy.shouldAnimate(
                requested: true,
                reduceMotion: false
            )
        )
        #expect(
            !SideNotchMotionPolicy.shouldAnimate(
                requested: true,
                reduceMotion: true
            )
        )
        #expect(
            !SideNotchMotionPolicy.shouldAnimate(
                requested: false,
                reduceMotion: false
            )
        )
        #expect(SideNotchMotionPolicy.duration == 0.2)
    }

    @Test
    func panelStateTransitionsBetweenHiddenRailAndDetail() {
        let state = SideNotchPanelState()

        #expect(state.mode == .hidden)

        state.toggleRevealed()
        #expect(state.mode == .revealed)

        state.select(.codex)
        #expect(state.mode == .detail(.codex))

        state.select(.codex)
        #expect(state.mode == .revealed)

        state.select(.claude)
        state.reconcile(providers: [.codex])
        #expect(state.mode == .revealed)

        state.transition(to: .hidden)
        state.select(nil)
        #expect(state.mode == .hidden)
    }

    @Test
    func hiddenEdgeCrossingRequiresRevealDwell() throws {
        let fixture = try controllerFixture()
        defer { fixture.controller.stop() }

        fixture.controller.pointerEntered()

        #expect(fixture.controller.mode == .hidden)
        let firstJob = try #require(fixture.scheduler.jobs.first)
        #expect(firstJob.delay == 0.18)

        fixture.controller.pointerExited()
        #expect(firstJob.task.isCancelled)
        fixture.scheduler.fire(0)
        #expect(fixture.controller.mode == .hidden)

        fixture.controller.pointerEntered()
        #expect(fixture.scheduler.jobs.count == 2)
        fixture.scheduler.fire(1)
        #expect(fixture.controller.mode == .revealed)
    }

    @Test
    func autoHideScheduleCancelsOnReentryAndIgnoresStaleJob() throws {
        let fixture = try controllerFixture()
        defer { fixture.controller.stop() }

        fixture.controller.pointerEntered()
        fixture.scheduler.fire(0)
        #expect(fixture.controller.mode == .revealed)

        fixture.controller.pointerExited()
        #expect(fixture.scheduler.jobs.count == 2)
        #expect(
            fixture.scheduler.jobs[1].delay
                == SideNotchPanelController.autoHideDelay
        )

        fixture.controller.pointerEntered()
        #expect(fixture.scheduler.jobs[1].task.isCancelled)
        fixture.scheduler.fire(1)
        #expect(fixture.controller.mode == .revealed)

        fixture.controller.pointerExited()
        #expect(fixture.scheduler.jobs.count == 3)
        fixture.scheduler.fire(2)
        #expect(fixture.controller.mode == .hidden)
    }

    @Test
    func autoHideUsesInjectedAndLiveUpdatedDelay() throws {
        let fixture = try controllerFixture(autoHideDelay: 2)
        defer { fixture.controller.stop() }

        fixture.controller.pointerEntered()
        fixture.scheduler.fire(0)
        fixture.controller.pointerExited()
        #expect(fixture.scheduler.jobs[1].delay == 2)

        fixture.controller.pointerEntered()
        fixture.controller.setAutoHideDelay(1.2)
        fixture.controller.pointerExited()
        #expect(fixture.scheduler.jobs[2].delay == 1.2)
    }

    @Test
    func detailDoesNotAutoHideUntilItCollapses() throws {
        let fixture = try controllerFixture()
        defer { fixture.controller.stop() }

        fixture.controller.pointerEntered()
        fixture.scheduler.fire(0)
        fixture.controller.select(.codex, animated: false)
        fixture.controller.pointerExited()

        #expect(fixture.controller.mode == .detail(.codex))
        #expect(fixture.scheduler.jobs.count == 1)

        fixture.controller.select(nil, animated: false)
        #expect(fixture.controller.mode == .revealed)
        #expect(fixture.scheduler.jobs.count == 2)

        fixture.scheduler.fire(1)
        #expect(fixture.controller.mode == .hidden)
    }

    @Test
    func menuToggleNeverSelectsAProvider() throws {
        let fixture = try controllerFixture()
        defer { fixture.controller.stop() }

        fixture.controller.toggleRevealed()
        #expect(fixture.controller.mode == .revealed)
        #expect(fixture.controller.mode.selectedProvider == nil)

        fixture.controller.toggleRevealed()
        #expect(fixture.controller.mode == .hidden)
    }

    @Test
    func refreshAnimationExistsOnlyForActiveNonReducedMotion() {
        #expect(
            SideNotchRefreshAnimationPolicy.shouldSpin(
                isRefreshing: true,
                reduceMotion: false
            )
        )
        #expect(
            !SideNotchRefreshAnimationPolicy.shouldSpin(
                isRefreshing: false,
                reduceMotion: false
            )
        )
        #expect(
            !SideNotchRefreshAnimationPolicy.shouldSpin(
                isRefreshing: true,
                reduceMotion: true
            )
        )
    }

    /// The supplied capture: a Codex ring above a Claude Code "Max 5x"
    /// detail whose three resetting meters and "as of" row make it the
    /// tallest provider detail.
    private func capturedTwoProviderUsage() -> [ProviderUsage] {
        [
            ProviderUsage(
                provider: .codex,
                planName: "Plus",
                groups: [
                    UsageGroup(
                        id: "codex.main",
                        title: nil,
                        meters: [
                            UsageMeter(
                                id: "codex.session",
                                title: "Session (5 hours)",
                                period: .session,
                                percentRemaining: 32,
                                resetText: "Resets in 2 hr 10 min"
                            )
                        ],
                        creditText: nil
                    )
                ],
                availability: .available,
                updatedAt: nil
            ),
            ProviderUsage(
                provider: .claude,
                planName: "Max 5x",
                groups: [
                    UsageGroup(
                        id: "claude.main",
                        title: nil,
                        meters: [
                            UsageMeter(
                                id: "claude.session",
                                title: "Session (5 hours)",
                                period: .session,
                                percentRemaining: 95,
                                resetText: "Resets in 4 hr 44 min"
                            ),
                            UsageMeter(
                                id: "claude.week",
                                title: "Weekly",
                                period: .week,
                                percentRemaining: 18,
                                resetText: "Resets in 1 days"
                            ),
                            UsageMeter(
                                id: "claude.week.model.fable",
                                title: "Fable weekly",
                                period: .week,
                                percentRemaining: 25,
                                resetText: "Resets in 1 days"
                            )
                        ],
                        creditText: nil
                    )
                ],
                availability: .available,
                updatedAt: Date(timeIntervalSince1970: 1_764_590_040)
            )
        ]
    }

    private func detailUsage(meterCount: Int) -> ProviderUsage {
        ProviderUsage(
            provider: .claude,
            accountLabel: "Work",
            planName: "Max 5x",
            groups: [
                UsageGroup(
                    id: "claude.main",
                    title: nil,
                    meters: (0..<meterCount).map { index in
                        UsageMeter(
                            id: "claude.meter.\(index)",
                            title: "Meter \(index)",
                            period: .week,
                            percentRemaining: 50,
                            resetText: "Resets in 1 day"
                        )
                    },
                    creditText: nil
                )
            ],
            availability: .available,
            updatedAt: nil
        )
    }

    private func controllerFixture(
        autoHideDelay: TimeInterval = 0.8
    ) throws -> (
        controller: SideNotchPanelController,
        scheduler: SideNotchFakeAutoHideScheduler
    ) {
        let suiteName = "SideNotchPanelControllerTests-\(UUID())"
        let defaults = try #require(
            UserDefaults(suiteName: suiteName)
        )
        let scheduler = SideNotchFakeAutoHideScheduler()
        let controller = SideNotchPanelController(
            viewModel: UsageDashboardViewModel(providers: []),
            localization: LocalizationController(
                store: AppLanguageStore(defaults: defaults)
            ),
            autoHideScheduler: scheduler,
            autoHideDelay: autoHideDelay,
            onExpansionChange: { _ in },
            onSettings: {},
            onQuit: {}
        )
        return (controller, scheduler)
    }

    private func containsDescendant<ViewType: NSView>(
        ofType type: ViewType.Type,
        in view: NSView
    ) -> Bool {
        view is ViewType
            || view.subviews.contains {
                containsDescendant(ofType: type, in: $0)
            }
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
}

@MainActor
private final class SideNotchFakeAutoHideTask:
    SideNotchAutoHideTask
{
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class SideNotchFakeAutoHideScheduler:
    SideNotchAutoHideScheduling
{
    struct Job {
        let delay: TimeInterval
        let task: SideNotchFakeAutoHideTask
        let action: @MainActor () -> Void
    }

    private(set) var jobs: [Job] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SideNotchAutoHideTask {
        let task = SideNotchFakeAutoHideTask()
        jobs.append(
            Job(delay: delay, task: task, action: action)
        )
        return task
    }

    func fire(_ index: Int) {
        let job = jobs[index]
        guard !job.task.isCancelled else { return }
        job.action()
    }
}
