import AppKit
import Testing
@testable import OmoUsage

@Suite
@MainActor
struct SideNotchPanelLayoutTests {
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
    func autoHideScheduleCancelsOnReentryAndIgnoresStaleJob() throws {
        let fixture = try controllerFixture()
        defer { fixture.controller.stop() }

        fixture.controller.pointerEntered()
        #expect(fixture.controller.mode == .revealed)

        fixture.controller.pointerExited()
        #expect(fixture.scheduler.jobs.count == 1)
        #expect(
            fixture.scheduler.jobs[0].delay
                == SideNotchPanelController.autoHideDelay
        )

        fixture.controller.pointerEntered()
        #expect(fixture.scheduler.jobs[0].task.isCancelled)
        fixture.scheduler.fire(0)
        #expect(fixture.controller.mode == .revealed)

        fixture.controller.pointerExited()
        #expect(fixture.scheduler.jobs.count == 2)
        fixture.scheduler.fire(1)
        #expect(fixture.controller.mode == .hidden)
    }

    @Test
    func detailDoesNotAutoHideUntilItCollapses() throws {
        let fixture = try controllerFixture()
        defer { fixture.controller.stop() }

        fixture.controller.pointerEntered()
        fixture.controller.select(.codex, animated: false)
        fixture.controller.pointerExited()

        #expect(fixture.controller.mode == .detail(.codex))
        #expect(fixture.scheduler.jobs.isEmpty)

        fixture.controller.select(nil, animated: false)
        #expect(fixture.controller.mode == .revealed)
        #expect(fixture.scheduler.jobs.count == 1)

        fixture.scheduler.fire(0)
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

    private func controllerFixture() throws -> (
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
