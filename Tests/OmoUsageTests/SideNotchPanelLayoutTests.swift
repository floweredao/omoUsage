import AppKit
import Testing
@testable import OmoUsage

@Suite
@MainActor
struct SideNotchPanelLayoutTests {
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

        #expect(frame.width == 72)
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

        #expect(expanded.width == 400)
        #expect(expanded.maxX == collapsed.maxX)
        #expect(expanded.minX < collapsed.minX)
    }

    @Test
    func footerClearanceSeparatesControlsFromTheLastUsageLabel() {
        let visibleFrame = NSRect(
            x: 0,
            y: 0,
            width: 1_920,
            height: 1_080
        )

        let frame = SideNotchPanelLayout.frame(
            in: visibleFrame,
            providerCount: 9,
            isExpanded: false
        )

        #expect(SideNotchPanelLayout.footerClearance >= 8)
        #expect(
            frame.height
                == SideNotchPanelLayout.verticalPadding
                    + 9 * SideNotchPanelLayout.providerRowHeight
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
        #expect(frame.height == visibleFrame.height - 40)
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
}
