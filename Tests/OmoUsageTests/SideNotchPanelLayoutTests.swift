import AppKit
import SwiftUI
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
@MainActor
struct SideNotchPanelLayoutTests {
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
    func presentedRailReservesTallestDetailHeightBeforeSelection() {
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
                == SideNotchPanelLayout.requiredPanelHeight(
                    for: usage
                )
        )
        #expect(detail.height == revealed.height)
        #expect(detail.minY == revealed.minY)
        #expect(detail.maxY == revealed.maxY)
        #expect(detail.maxX == revealed.maxX)
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

    @Test
    func hiddenActivationFrameIsEightBy144AtMidpointFallback() {
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

        #expect(hiddenTrigger.size == NSSize(width: 8, height: 144))
        #expect(SideNotchPanelLayout.hiddenTrackingHeight == 144)
        #expect(hiddenTrigger.maxX == visibleFrame.maxX)
        #expect(hiddenTrigger.midY == visibleFrame.midY)
        #expect(SideNotchPanelLayout.hiddenWidth == 6)
        #expect(SideNotchPanelLayout.hiddenTrackingWidth == 8)
    }

    @Test
    func hiddenActivationExcludesNormalTopAndBottomEdgeInput() {
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
            !hiddenTrigger.contains(
                NSPoint(x: visibleFrame.maxX - 1, y: visibleFrame.minY + 40)
            )
        )
        #expect(
            !hiddenTrigger.contains(
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
    func hiddenActivationAnchorFollowsPointerAndClampsPerScreen() {
        let visibleFrame = NSRect(
            x: -1_600,
            y: 50,
            width: 1_600,
            height: 900
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

        #expect(anchored.midY == 640)
        #expect(anchored.maxX == visibleFrame.maxX)
        #expect(clampedBottom.minY == visibleFrame.minY)
        #expect(clampedTop.maxY == visibleFrame.maxY)
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
    func hideAnimationTargetContractsSidewaysInPlace() {
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

        #expect(edgeFrame.width == SideNotchPanelLayout.hiddenWidth)
        #expect(edgeFrame.maxX == rail.maxX)
        #expect(edgeFrame.minY == rail.minY)
        #expect(edgeFrame.height == rail.height)
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
