import AppKit
import Testing
@testable import OmoUsage

/// Contract for the side-notch hover preview.
///
/// The failing-first proof for this work is a real-surface RED capture: the
/// packaged dev build was launched as an isolated temporary bundle, the
/// pointer was warped onto the first rail row, and the panel stayed at its
/// 72 pt collapsed width across a sustained hover (never reaching the 400 pt
/// expanded width). These tests lock in the behaviour that replaces it.
@Suite
@MainActor
struct SideNotchHoverPreviewTests {
    private static let accountA = AccountID(
        rawValue: "11111111-1111-1111-1111-111111111111"
    )!
    private static let accountB = AccountID(
        rawValue: "22222222-2222-2222-2222-222222222222"
    )!

    private static func target(
        _ account: AccountID,
        _ provider: ProviderID
    ) -> AccountProviderID {
        AccountProviderID(accountID: account, providerID: provider)
    }

    private static var claudeA: AccountProviderID {
        target(accountA, .claude)
    }

    /// Same provider, different account — the case a bare `ProviderID` cannot
    /// distinguish.
    private static var claudeB: AccountProviderID {
        target(accountB, .claude)
    }

    private static var codexA: AccountProviderID {
        target(accountA, .codex)
    }

    // MARK: - Transient preview

    @Test
    func hoverSelectsTheTransientAccountQualifiedTarget() {
        let state = SideNotchPanelState()

        #expect(state.selection == nil)
        #expect(state.apply(.hover(Self.claudeA)))

        #expect(
            state.selection
                == SideNotchSelection(
                    target: Self.claudeA,
                    kind: .hovered
                )
        )
        #expect(state.selectedTarget == Self.claudeA)
        #expect(!state.isPinned)
    }

    @Test
    func hoverDistinguishesTwoAccountsOnTheSameProvider() {
        let state = SideNotchPanelState()

        state.apply(.hover(Self.claudeA))
        #expect(state.selectedTarget == Self.claudeA)

        // Identical ProviderID, different account: this must retarget.
        #expect(state.apply(.hover(Self.claudeB)))
        #expect(state.selectedTarget == Self.claudeB)
        #expect(state.selectedTarget?.providerID == .claude)
        #expect(Self.claudeA != Self.claudeB)
    }

    @Test
    func hoveringAnotherRowRetargetsTheTransientPreview() {
        let state = SideNotchPanelState()

        state.apply(.hover(Self.claudeA))
        #expect(state.apply(.hover(Self.codexA)))

        #expect(
            state.selection
                == SideNotchSelection(
                    target: Self.codexA,
                    kind: .hovered
                )
        )
    }

    @Test
    func leavingThePanelCollapsesTheTransientPreview() {
        let state = SideNotchPanelState()

        state.apply(.hover(Self.claudeA))
        #expect(state.apply(.exitPanel))

        #expect(state.selection == nil)
    }

    @Test
    func exitingWithNoSelectionIsANoOp() {
        let state = SideNotchPanelState()

        #expect(!state.apply(.exitPanel))
        #expect(state.selection == nil)
    }

    // MARK: - Pinning

    @Test
    func committingPromotesAHoveredRowToPinned() {
        let state = SideNotchPanelState()

        state.apply(.hover(Self.claudeA))
        #expect(state.apply(.commit(Self.claudeA)))

        #expect(
            state.selection
                == SideNotchSelection(
                    target: Self.claudeA,
                    kind: .pinned
                )
        )
        #expect(state.isPinned)
    }

    @Test
    func committingWithoutAPriorHoverPinsDirectly() {
        let state = SideNotchPanelState()

        #expect(state.apply(.commit(Self.codexA)))
        #expect(state.isPinned)
        #expect(state.selectedTarget == Self.codexA)
    }

    @Test
    func committingThePinnedActiveRowCollapsesIt() {
        let state = SideNotchPanelState()

        state.apply(.commit(Self.claudeA))
        #expect(state.apply(.commit(Self.claudeA)))

        #expect(state.selection == nil)
    }

    @Test
    func committingADifferentRowMovesThePin() {
        let state = SideNotchPanelState()

        state.apply(.commit(Self.claudeA))
        #expect(state.apply(.commit(Self.codexA)))

        #expect(
            state.selection
                == SideNotchSelection(
                    target: Self.codexA,
                    kind: .pinned
                )
        )
    }

    @Test
    func aPinnedSelectionIsNotOverwrittenByIncidentalHover() {
        let state = SideNotchPanelState()
        state.apply(.commit(Self.claudeA))

        #expect(!state.apply(.hover(Self.codexA)))
        #expect(!state.apply(.hover(Self.claudeB)))
        #expect(!state.apply(.hover(Self.claudeA)))

        #expect(
            state.selection
                == SideNotchSelection(
                    target: Self.claudeA,
                    kind: .pinned
                )
        )
    }

    @Test
    func aPinnedSelectionSurvivesThePointerLeavingThePanel() {
        let state = SideNotchPanelState()
        state.apply(.commit(Self.claudeA))

        #expect(!state.apply(.exitPanel))

        #expect(state.isPinned)
        #expect(state.selectedTarget == Self.claudeA)
    }

    // MARK: - Escape and reconciliation

    @Test
    func escapeCollapsesBothSelectionKinds() {
        let hovered = SideNotchPanelState()
        hovered.apply(.hover(Self.claudeA))
        #expect(hovered.apply(.collapse))
        #expect(hovered.selection == nil)

        let pinned = SideNotchPanelState()
        pinned.apply(.commit(Self.claudeA))
        #expect(pinned.apply(.collapse))
        #expect(pinned.selection == nil)
    }

    @Test
    func providerDisappearanceReconcilesTheCompositeSelection() {
        let state = SideNotchPanelState()
        state.apply(.commit(Self.claudeA))

        // Still present: keep it.
        #expect(!state.apply(.reconcile([Self.claudeA, Self.codexA])))
        #expect(state.selectedTarget == Self.claudeA)

        // Gone: clear it.
        #expect(state.apply(.reconcile([Self.codexA])))
        #expect(state.selection == nil)
    }

    @Test
    func reconcileClearsWhenOnlyTheAccountChanged() {
        let state = SideNotchPanelState()
        state.apply(.hover(Self.claudeA))

        // Same provider, different account is NOT the same row.
        #expect(state.apply(.reconcile([Self.claudeB])))
        #expect(state.selection == nil)
    }

    // MARK: - Focus safety

    @Test
    func hoverPreviewNeverRequestsKeyActivationOrDismissalMonitor() {
        let hovered = SideNotchSelection(
            target: Self.claudeA,
            kind: .hovered
        )

        let plan = SideNotchActivationPolicy.plan(for: hovered)

        #expect(!plan.makesPanelKey)
        #expect(!plan.startsDismissalMonitor)
        #expect(!plan.startsEscapeMonitor)
        #expect(!plan.activatesApplication)
    }

    @Test
    func onlyAPinnedSelectionActivatesThePanel() {
        let pinned = SideNotchSelection(
            target: Self.claudeA,
            kind: .pinned
        )

        let plan = SideNotchActivationPolicy.plan(for: pinned)

        #expect(plan.makesPanelKey)
        #expect(plan.startsDismissalMonitor)
        #expect(plan.startsEscapeMonitor)
        #expect(plan.activatesApplication)
    }

    @Test
    func acollapsedSelectionRequestsNoActivation() {
        let plan = SideNotchActivationPolicy.plan(for: nil)

        #expect(!plan.makesPanelKey)
        #expect(!plan.startsDismissalMonitor)
        #expect(!plan.startsEscapeMonitor)
        #expect(!plan.activatesApplication)
    }

    @Test
    func explicitKeyboardFocusActivatesOnlyAKnownRailTarget() {
        #expect(
            SideNotchKeyboardFocusPolicy.shouldActivate(
                target: Self.claudeA,
                available: [Self.claudeA, Self.codexA]
            )
        )
        #expect(
            !SideNotchKeyboardFocusPolicy.shouldActivate(
                target: Self.claudeB,
                available: [Self.claudeA, Self.codexA]
            )
        )
    }

    @Test
    func pinnedEscapeMonitorDismissesAndCleansUpDeterministically() {
        let monitor = RecordingSideNotchEscapeMonitor()
        let dismissal = SideNotchEscapeDismissalController(
            monitor: monitor
        )
        var dismissCount = 0

        dismissal.start {
            dismissCount += 1
        }
        dismissal.start {
            dismissCount += 10
        }
        monitor.triggerEscape()

        #expect(monitor.addCount == 1)
        #expect(dismissCount == 1)

        dismissal.stop()
        #expect(monitor.removeCount == 1)
        #expect(!dismissal.isMonitoring)
    }

    /// The controller acts on exactly one decision. When an intent does not
    /// change the selection the decision is "do nothing" — so a pinned panel
    /// cannot re-key itself and yank focus back from the app the user switched
    /// to while the pointer drifts over the rail.
    @Test
    func incidentalHoverOnAPinnedPanelPerformsNoSideEffects() {
        let state = SideNotchPanelState()
        state.apply(.commit(Self.claudeA))

        let changed = state.apply(.hover(Self.codexA))

        #expect(!changed)
        #expect(
            SideNotchActivationPolicy.plan(
                for: state.selection,
                selectionChanged: changed
            ) == nil
        )
    }

    @Test
    func panelExitOnAPinnedPanelPerformsNoSideEffects() {
        let state = SideNotchPanelState()
        state.apply(.commit(Self.claudeA))

        let changed = state.apply(.exitPanel)

        #expect(!changed)
        #expect(
            SideNotchActivationPolicy.plan(
                for: state.selection,
                selectionChanged: changed
            ) == nil
        )
        #expect(state.isPinned)
    }

    @Test
    func rehoveringTheAlreadyPreviewedRowPerformsNoSideEffects() {
        let state = SideNotchPanelState()
        state.apply(.hover(Self.claudeA))

        let changed = state.apply(.hover(Self.claudeA))

        #expect(!changed)
        #expect(
            SideNotchActivationPolicy.plan(
                for: state.selection,
                selectionChanged: changed
            ) == nil
        )
    }

    @Test
    func aRealSelectionChangeStillYieldsAPlan() {
        let state = SideNotchPanelState()
        let changed = state.apply(.hover(Self.claudeA))

        let plan = SideNotchActivationPolicy.plan(
            for: state.selection,
            selectionChanged: changed
        )

        #expect(changed)
        #expect(plan != nil)
        #expect(plan?.makesPanelKey == false)
        #expect(plan?.startsDismissalMonitor == false)
    }

    // MARK: - Hover boundary

    @Test
    func exitReportsAreIgnoredWhileThePointerIsStillOverThePanel() {
        // AppKit emits a synthetic exit as the panel resizes under a
        // stationary cursor; that must not collapse the preview.
        let panelFrame = NSRect(x: 1_520, y: 177, width: 400, height: 752)
        let pointerOnRail = NSPoint(x: 1_884, y: 400)

        #expect(
            !SideNotchHoverBoundaryPolicy.confirmsExit(
                pointer: pointerOnRail,
                panelFrame: panelFrame
            )
        )
    }

    @Test
    func pointerInTheGapAndDetailCardCountsAsInsideThePanel() {
        let panelFrame = NSRect(x: 1_520, y: 177, width: 400, height: 752)

        // Gap between detail card and rail.
        #expect(
            !SideNotchHoverBoundaryPolicy.confirmsExit(
                pointer: NSPoint(x: 1_844, y: 400),
                panelFrame: panelFrame
            )
        )
        // Inside the detail card.
        #expect(
            !SideNotchHoverBoundaryPolicy.confirmsExit(
                pointer: NSPoint(x: 1_600, y: 400),
                panelFrame: panelFrame
            )
        )
    }

    @Test
    func leavingThePanelBoundsConfirmsARealExit() {
        let panelFrame = NSRect(x: 1_520, y: 177, width: 400, height: 752)

        #expect(
            SideNotchHoverBoundaryPolicy.confirmsExit(
                pointer: NSPoint(x: 1_000, y: 400),
                panelFrame: panelFrame
            )
        )
        #expect(
            SideNotchHoverBoundaryPolicy.confirmsExit(
                pointer: NSPoint(x: 1_600, y: 50),
                panelFrame: panelFrame
            )
        )
    }

    @Test
    func everyHoverDrivenStateStaysPassive() {
        let state = SideNotchPanelState()

        for intent in [
            SideNotchSelectionIntent.hover(Self.claudeA),
            .hover(Self.codexA),
            .hover(Self.claudeB),
            .exitPanel
        ] {
            state.apply(intent)
            let plan = SideNotchActivationPolicy.plan(for: state.selection)
            #expect(!plan.makesPanelKey)
            #expect(!plan.startsDismissalMonitor)
            #expect(!plan.startsEscapeMonitor)
        }
    }

    // MARK: - Motion

    @Test
    func hoverTransitionsHonorReduceMotion() {
        // Hover preview and spatial retarget use the same shared policy as
        // every other side-notch geometry change.
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
    }

    @Test
    func fixtureCanForceReduceMotionWithoutChangingProduction() {
        let override = "OMO_USAGE_REDUCE_MOTION_FIXTURE"
        let fixture = "OMO_USAGE_FIXTURE_MODE"

        #expect(
            SideNotchMotionPolicy.reduceMotionEnabled(
                systemValue: false,
                environment: [fixture: "1", override: "1"]
            )
        )
        #expect(
            !SideNotchMotionPolicy.reduceMotionEnabled(
                systemValue: false,
                environment: [override: "1"]
            )
        )
        #expect(
            SideNotchMotionPolicy.reduceMotionEnabled(
                systemValue: true,
                environment: [:]
            )
        )
    }

    @Test
    func retargetReplacesDetailContentWithoutAnimatingOldAndNewText() {
        let accountA = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000a"
        )!
        let accountB = AccountID(
            rawValue: "00000000-0000-0000-0000-00000000000b"
        )!
        let current = SideNotchSelection(
            target: AccountProviderID(
                accountID: accountA,
                providerID: .openrouter
            ),
            kind: .hovered
        )

        #expect(
            !SideNotchMotionPolicy.shouldAnimateSelectionMutation(
                current: current,
                intent: .hover(
                    AccountProviderID(
                        accountID: accountB,
                        providerID: .openrouter
                    )
                ),
                requested: true,
                reduceMotion: false
            )
        )
        #expect(
            SideNotchMotionPolicy.shouldAnimateSelectionMutation(
                current: nil,
                intent: .hover(current.target),
                requested: true,
                reduceMotion: false
            )
        )
        #expect(
            SideNotchMotionPolicy.shouldAnimateSelectionMutation(
                current: current,
                intent: .exitPanel,
                requested: true,
                reduceMotion: false
            )
        )
    }

    @Test
    func accountIdentityDistinguishesDuplicateProviderRows() {
        #expect(
            SideNotchAccountIdentity.badgeText(for: "QA Team") == "T"
        )
        #expect(
            SideNotchAccountIdentity.badgeText(for: "QA Personal") == "P"
        )
        #expect(
            SideNotchAccountIdentity.accessibleName(
                providerName: "OpenRouter",
                accountLabel: "QA Team"
            ) == "OpenRouter, QA Team"
        )
        #expect(
            SideNotchAccountIdentity.accessibleName(
                providerName: "OpenRouter",
                accountLabel: nil
            ) == "OpenRouter"
        )
    }

    // MARK: - Panel contract

    @Test
    func thePanelRemainsASingleNonactivatingFloatingPanel() {
        let panel = SideNotchPanelController.makePanel(
            contentRect: NSRect(x: 0, y: 0, width: 72, height: 240)
        )

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.becomesKeyOnlyIfNeeded)
    }

    @Test
    func aTransientPreviewStillExpandsThePanelGeometry() {
        let state = SideNotchPanelState()
        state.apply(.hover(Self.claudeA))

        let visibleFrame = NSRect(x: 0, y: 0, width: 1_920, height: 1_055)
        let frame = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 3,
            isExpanded: state.selection != nil
        )

        #expect(frame.width == SideNotchPanelLayout.expandedWidth)
        #expect(frame.maxX == visibleFrame.maxX)
    }
}

@MainActor
private final class RecordingSideNotchEscapeMonitor:
    SideNotchEscapeMonitoring
{
    private var handler: (@MainActor () -> Void)?
    private(set) var addCount = 0
    private(set) var removeCount = 0

    func addLocalEscapeMonitor(
        _ handler: @escaping @MainActor () -> Void
    ) -> Any? {
        addCount += 1
        self.handler = handler
        return UUID()
    }

    func removeMonitor(_ token: Any) {
        removeCount += 1
        handler = nil
    }

    func triggerEscape() {
        handler?()
    }
}
