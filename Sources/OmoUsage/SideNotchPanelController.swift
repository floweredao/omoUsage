import OmoUsageCore
import AppKit
import Observation
import QuartzCore
import SwiftUI

enum SideNotchPanelLayout {
    static let hiddenWidth: CGFloat = 6
    static let hiddenTrackingWidth: CGFloat = 8
    static let collapsedWidth: CGFloat = 56
    static let detailWidth: CGFloat = 280
    static let detailSpacing: CGFloat = 8
    static let expandedWidth: CGFloat = 344
    static let providerRowHeight: CGFloat = 58
    static let verticalPadding: CGFloat = 14
    static let footerClearance: CGFloat = 8
    static let footerHeight: CGFloat = 58
    static let footerControlHeight: CGFloat = 28
    static let detailContentPadding: CGFloat = 14
    static let detailCardMargin: CGFloat = 12
    static let maximumPanelHeight: CGFloat = 540
    static let minimumHeight: CGFloat = 128
    static let screenMargin: CGFloat = 20
    static let railCornerRadius: CGFloat = 20
    static let ringDiameter: CGFloat = 36
    static let providerIconSize: CGFloat = 22
    static let coordinateSpaceName = "SideNotchPanel"

    static func providerRowMidY(at index: Int) -> CGFloat {
        verticalPadding / 2
            + CGFloat(index) * providerRowHeight
            + providerRowHeight / 2
    }

    static func detailTop(
        rowMidY: CGFloat,
        detailHeight: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat {
        let maximumTop = max(
            0,
            containerHeight - detailHeight - detailCardMargin
        )
        return min(max(0, rowMidY - detailHeight / 2), maximumTop)
    }

    static func detailHeight(
        for usage: ProviderUsage,
        showsAccountLabel: Bool = false,
        language _: AppLanguage = .english
    ) -> CGFloat {
        detailSectionHeight(
            for: usage,
            showsAccountLabel: showsAccountLabel
        )
            + detailContentPadding * 2
            + narrowResetTextAllowance(for: usage)
    }

    private static func detailSectionHeight(
        for usage: ProviderUsage,
        showsAccountLabel: Bool
    ) -> CGFloat {
        DashboardLayout.sectionHeight(
            usage,
            showsAccountLabel: showsAccountLabel
        )
    }

    private static func narrowResetTextAllowance(
        for usage: ProviderUsage
    ) -> CGFloat {
        CGFloat(
            usage.groups
                .flatMap(\.meters)
                .filter {
                    $0.resetText != nil || $0.resetsAt != nil
                }
                .count
        )
    }

    static func requiredPanelHeight(
        for usage: ProviderUsage,
        showsAccountLabel: Bool = false,
        language: AppLanguage = .english
    ) -> CGFloat {
        detailHeight(
            for: usage,
            showsAccountLabel: showsAccountLabel,
            language: language
        )
            + detailCardMargin
    }

    /// Rail height for `providerCount` rows: padding, rows, footer
    /// clearance, and footer.
    static func naturalRailHeight(providerCount: Int) -> CGFloat {
        verticalPadding
            + CGFloat(providerCount) * providerRowHeight
            + footerClearance
            + footerHeight
    }

    /// Height the rail view occupies inside `containerHeight`.
    ///
    /// A populated rail never stretches past its natural height, so the
    /// taller detail container cannot open a blank material band between
    /// the last provider row and the footer. The zero-provider checking
    /// state and a rail too crowded for the panel take the container and
    /// scroll inside it.
    static func railContentHeight(
        providerCount: Int,
        containerHeight: CGFloat
    ) -> CGFloat {
        guard providerCount > 0 else { return containerHeight }
        return min(
            naturalRailHeight(providerCount: providerCount),
            containerHeight,
            maximumPanelHeight
        )
    }

    static func presentationFrame(
        in visibleFrame: NSRect,
        providers: [ProviderUsage],
        mode: SideNotchPanelMode,
        anchorY: CGFloat? = nil,
        language: AppLanguage = .english
    ) -> NSRect {
        let providerCounts = Dictionary(
            grouping: providers,
            by: \.provider
        ).mapValues(\.count)
        // Only provider detail reserves card height. The revealed rail keeps
        // its natural provider-row height, so it never opens with a blank
        // material band between the last row and the footer.
        let requiredHeights: [CGFloat] = switch mode {
        case .hidden, .revealed:
            []
        case .detail:
            providers.map {
                requiredPanelHeight(
                    for: $0,
                    showsAccountLabel:
                        DashboardAccountIdentityRule.showsAlias(
                            for: $0,
                            sameProviderCount: providerCounts[
                                $0.provider,
                                default: 0
                            ]
                        ),
                    language: language
                )
            }
        }
        let rowAlignedHeights = requiredHeights.enumerated().map {
            let cardHeight = $0.element - detailCardMargin
            return max(0, providerRowMidY(at: $0.offset) - cardHeight / 2)
                + $0.element
        }
        return frame(
            in: visibleFrame,
            providerCount: providers.count,
            mode: mode,
            anchorY: anchorY,
            presentedContentMinimumHeight:
                requiredHeights.max() ?? 0,
            presentedContentPreferredHeight:
                rowAlignedHeights.max() ?? 0
        )
    }

    static func hideAnimationTarget(
        in visibleFrame: NSRect,
        from currentFrame: NSRect
    ) -> NSRect {
        NSRect(
            x: visibleFrame.maxX - hiddenTrackingWidth,
            y: currentFrame.minY,
            width: hiddenTrackingWidth,
            height: currentFrame.height
        )
    }

    static func frame(
        in visibleFrame: NSRect,
        providerCount: Int,
        mode: SideNotchPanelMode,
        anchorY: CGFloat? = nil,
        presentedContentMinimumHeight: CGFloat = 0,
        presentedContentPreferredHeight: CGFloat = 0
    ) -> NSRect {
        if mode == .hidden {
            return NSRect(
                x: visibleFrame.maxX - hiddenTrackingWidth,
                y: visibleFrame.minY,
                width: hiddenTrackingWidth,
                height: visibleFrame.height
            )
        }

        let railHeight = max(
            minimumHeight,
            naturalRailHeight(providerCount: providerCount)
        )
        let desiredHeight = max(
            railHeight,
            presentedContentMinimumHeight
        )
        let maximumHeight = min(
            maximumPanelHeight,
            max(
                minimumHeight,
                visibleFrame.height - screenMargin * 2
            )
        )
        var height = min(desiredHeight, maximumHeight)
        let width: CGFloat = switch mode {
        case .hidden:
            hiddenWidth
        case .revealed:
            collapsedWidth
        case .detail:
            expandedWidth
        }
        let minimumY = visibleFrame.minY + screenMargin
        let anchor = anchorY ?? visibleFrame.midY
        let proposedY: CGFloat
        switch mode {
        case .hidden:
            proposedY = minimumY
        case .revealed:
            proposedY = anchor - height / 2
        case .detail:
            let revealedHeight = min(railHeight, maximumHeight)
            let maximumRailY =
                visibleFrame.maxY - screenMargin - revealedHeight
            let railY = min(
                max(anchor - revealedHeight / 2, minimumY),
                maximumRailY
            )
            let railTop = railY + revealedHeight
            // Row-aligned cards take extra height only from the space
            // below the rail, so the rail never moves to make room.
            let preferredHeight = max(
                desiredHeight,
                presentedContentPreferredHeight
            )
            height = max(height, min(preferredHeight, railTop - minimumY))
            proposedY = railTop - height
        }
        let y = min(
            max(proposedY, minimumY),
            visibleFrame.maxY - screenMargin - height
        )

        return NSRect(
            x: visibleFrame.maxX - width,
            y: y,
            width: width,
            height: height
        )
    }

    static func frame(
        in visibleFrame: NSRect,
        providerCount: Int,
        isExpanded: Bool
    ) -> NSRect {
        frame(
            in: visibleFrame,
            providerCount: providerCount,
            mode: isExpanded ? .detail(.codex) : .revealed
        )
    }
}

enum SideNotchRevealAnchorIntent: Equatable {
    case pointerEntered(
        mode: SideNotchPanelMode,
        screenY: CGFloat
    )
    case programmatic
}

enum SideNotchRevealAnchorPolicy {
    static func anchorY(
        current: CGFloat?,
        for intent: SideNotchRevealAnchorIntent
    ) -> CGFloat? {
        switch intent {
        case let .pointerEntered(mode, screenY):
            mode == .hidden ? screenY : current
        case .programmatic:
            nil
        }
    }
}

enum SideNotchMotionPolicy {
    static let duration = 0.2

    static func reduceMotionEnabled(
        systemValue: Bool,
        environment: [String: String]
    ) -> Bool {
        systemValue
            || (
                environment["OMO_USAGE_FIXTURE_MODE"] == "1"
                    && environment[
                        "OMO_USAGE_REDUCE_MOTION_FIXTURE"
                    ] == "1"
            )
    }

    static func shouldAnimate(
        requested: Bool,
        reduceMotion: Bool
    ) -> Bool {
        requested && !reduceMotion
    }

    static func shouldAnimateSelectionMutation(
        current _: SideNotchSelection?,
        intent _: SideNotchSelectionIntent,
        requested _: Bool,
        reduceMotion _: Bool
    ) -> Bool {
        // AppKit owns the inward panel-frame animation. Mutating selection
        // outside a SwiftUI animation prevents the HStack from adding a
        // second right-to-left layout animation.
        false
    }
}

/// Whether a side-notch selection is a passive pointer preview or an explicit
/// commitment. Only a pinned selection may activate the panel.
enum SideNotchSelectionKind: Equatable, Sendable {
    case hovered
    case pinned
}

struct SideNotchSelection: Equatable, Sendable {
    let target: AccountProviderID
    let kind: SideNotchSelectionKind
}

/// Every way the side-notch selection can change. Keeping these as data makes
/// the transition table testable without AppKit.
enum SideNotchSelectionIntent: Equatable, Sendable {
    /// Pointer entered a rail row.
    case hover(AccountProviderID)
    /// Pointer left the whole panel, including the detail card and the gap.
    case exitPanel
    /// Click, Return, or Space on a rail row.
    case commit(AccountProviderID)
    /// Escape or a click outside the panel.
    case collapse
    /// Refresh published a new provider set.
    case reconcile([AccountProviderID])
}

/// The side effects a selection is allowed to request from the panel. A hover
/// preview must never make the panel key or arm the outside-click monitor,
/// because both steal focus from the frontmost application.
struct SideNotchActivationPlan: Equatable, Sendable {
    let makesPanelKey: Bool
    let startsDismissalMonitor: Bool
    let startsEscapeMonitor: Bool
    let activatesApplication: Bool
}

enum SideNotchActivationPolicy {
    static func plan(
        for selection: SideNotchSelection?
    ) -> SideNotchActivationPlan {
        switch selection?.kind {
        case .pinned:
            SideNotchActivationPlan(
                makesPanelKey: true,
                startsDismissalMonitor: true,
                startsEscapeMonitor: true,
                activatesApplication: true
            )
        case .hovered, nil:
            SideNotchActivationPlan(
                makesPanelKey: false,
                startsDismissalMonitor: false,
                startsEscapeMonitor: false,
                activatesApplication: false
            )
        }
    }

    /// The single decision the controller acts on. `nil` means "touch nothing":
    /// when an intent did not change the selection there must be no expansion
    /// callback, no reposition, and above all no `makeKey`, because a pinned
    /// panel re-keying itself on an incidental hover would yank focus back from
    /// whatever application the user switched to.
    static func plan(
        for selection: SideNotchSelection?,
        selectionChanged: Bool
    ) -> SideNotchActivationPlan? {
        guard selectionChanged else { return nil }
        return plan(for: selection)
    }
}

enum SideNotchKeyboardFocusPolicy {
    static func shouldActivate(
        target: AccountProviderID,
        available: [AccountProviderID]
    ) -> Bool {
        available.contains(target)
    }
}

@MainActor
protocol SideNotchEscapeMonitoring: AnyObject {
    func addLocalEscapeMonitor(
        _ handler: @escaping @MainActor () -> Void
    ) -> Any?

    func removeMonitor(_ token: Any)
}

@MainActor
final class AppKitSideNotchEscapeMonitor: SideNotchEscapeMonitoring {
    func addLocalEscapeMonitor(
        _ handler: @escaping @MainActor () -> Void
    ) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in
                handler()
            }
            return nil
        }
    }

    func removeMonitor(_ token: Any) {
        NSEvent.removeMonitor(token)
    }
}

@MainActor
final class SideNotchEscapeDismissalController {
    private let monitor: any SideNotchEscapeMonitoring
    private var token: Any?

    init(monitor: any SideNotchEscapeMonitoring) {
        self.monitor = monitor
    }

    var isMonitoring: Bool {
        token != nil
    }

    func start(
        onDismiss: @escaping @MainActor () -> Void
    ) {
        guard !isMonitoring else { return }
        token = monitor.addLocalEscapeMonitor(onDismiss)
    }

    func stop() {
        if let token {
            monitor.removeMonitor(token)
        }
        token = nil
    }
}

/// AppKit synthesizes `mouseExited` while a window resizes underneath a
/// stationary cursor, so a panel-exit report is only trusted when the pointer
/// really is outside the panel. Without this filter the expand animation
/// reports its own exit, collapses, re-enters, and oscillates.
enum SideNotchHoverBoundaryPolicy {
    static func confirmsExit(
        pointer: NSPoint,
        panelFrame: NSRect
    ) -> Bool {
        !NSMouseInRect(pointer, panelFrame, false)
    }
}

enum SideNotchTrackingExitPolicy {
    static func shouldForward(
        eventPointer _: NSPoint,
        livePointer: NSPoint,
        panelFrame: NSRect
    ) -> Bool {
        SideNotchHoverBoundaryPolicy.confirmsExit(
            pointer: livePointer,
            panelFrame: panelFrame
        )
    }
}

enum SideNotchPanelMode: Equatable {
    case hidden
    case revealed
    case detail(ProviderID)

    var selectedProvider: ProviderID? {
        guard case .detail(let provider) = self else {
            return nil
        }
        return provider
    }

    var isPresented: Bool {
        self != .hidden
    }
}

@Observable
@MainActor
final class SideNotchPanelState {
    private(set) var mode: SideNotchPanelMode = .hidden
    private(set) var selection: SideNotchSelection?

    var selectedProvider: ProviderID? {
        mode.selectedProvider
    }

    var selectedTarget: AccountProviderID? {
        selection?.target
    }

    var isPinned: Bool {
        selection?.kind == .pinned
    }

    func transition(to mode: SideNotchPanelMode) {
        self.mode = mode
        if mode == .hidden {
            selection = nil
        }
    }

    func toggleRevealed() {
        if mode == .hidden {
            mode = .revealed
        } else {
            mode = .hidden
            selection = nil
        }
    }

    func select(_ provider: ProviderID?) {
        guard let provider else {
            if selectedProvider != nil {
                mode = .revealed
            }
            selection = nil
            return
        }
        mode = selectedProvider == provider
            ? .revealed
            : .detail(provider)
        selection = nil
    }

    func reconcile(providers: [ProviderID]) {
        guard
            let selectedProvider,
            !providers.contains(selectedProvider)
        else {
            return
        }
        mode = .revealed
        selection = nil
    }

    /// Applies an intent and reports whether the selection actually changed.
    @discardableResult
    func apply(_ intent: SideNotchSelectionIntent) -> Bool {
        let previous = selection
        switch intent {
        case let .hover(target):
            // A pinned selection is never overwritten by incidental hover.
            if !isPinned {
                selection = SideNotchSelection(
                    target: target,
                    kind: .hovered
                )
            }
        case .exitPanel:
            if !isPinned {
                selection = nil
            }
        case let .commit(target):
            selection =
                selection == SideNotchSelection(
                    target: target,
                    kind: .pinned
                )
                ? nil
                : SideNotchSelection(target: target, kind: .pinned)
        case .collapse:
            selection = nil
        case let .reconcile(available):
            if
                let target = selection?.target,
                !available.contains(target)
            {
                selection = nil
            }
        }
        if selection != previous, mode != .hidden {
            mode = selection.map {
                .detail($0.target.providerID)
            } ?? .revealed
        }
        return selection != previous
    }
}

@MainActor
protocol SideNotchAutoHideTask: AnyObject {
    func cancel()
}

@MainActor
protocol SideNotchAutoHideScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SideNotchAutoHideTask
}

@MainActor
private final class DispatchSideNotchAutoHideTask:
    SideNotchAutoHideTask
{
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

@MainActor
struct DispatchSideNotchAutoHideScheduler:
    SideNotchAutoHideScheduling
{
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any SideNotchAutoHideTask {
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                action()
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
        return DispatchSideNotchAutoHideTask(workItem: workItem)
    }
}

final class SideNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SideNotchPanelController: NSObject {
    private let viewModel: UsageDashboardViewModel
    private let localization: LocalizationController
    private let state = SideNotchPanelState()
    private let panel: NSPanel
    private let autoHideScheduler: any SideNotchAutoHideScheduling
    private let onExpansionChange: @MainActor (Bool) -> Void
    private let dismissalController = PopoverDismissalController(
        monitor: AppKitPopoverMouseMonitor()
    )
    private let escapeDismissalController =
        SideNotchEscapeDismissalController(
            monitor: AppKitSideNotchEscapeMonitor()
        )
    private var providerCount = 0
    private var pointerInside = false
    private var pointerAnchorY: CGFloat?
    private var autoHideGeneration = 0
    private var autoHideTask: (any SideNotchAutoHideTask)?
    private var revealGeneration = 0
    private var revealTask: (any SideNotchAutoHideTask)?
    private var transitionGeneration = 0
    private var transitionCompletionTask:
        (any SideNotchAutoHideTask)?
    private var configuredAutoHideDelay: TimeInterval
    static let autoHideDelay =
        SideNotchHideDelay.standard.rawValue
    static let revealDelay: TimeInterval = 0.18

    init(
        viewModel: UsageDashboardViewModel,
        localization: LocalizationController,
        autoHideScheduler: any SideNotchAutoHideScheduling =
            DispatchSideNotchAutoHideScheduler(),
        autoHideDelay: TimeInterval =
            SideNotchHideDelay.standard.rawValue,
        onExpansionChange: @escaping @MainActor (Bool) -> Void,
        onSettings: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.viewModel = viewModel
        self.localization = localization
        self.autoHideScheduler = autoHideScheduler
        configuredAutoHideDelay = autoHideDelay
        self.onExpansionChange = onExpansionChange
        panel = Self.makePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SideNotchPanelLayout.collapsedWidth,
                height: SideNotchPanelLayout.minimumHeight
            )
        )
        super.init()

        panel.contentViewController = NSHostingController(
            rootView: SideNotchPanelView(
                viewModel: viewModel,
                localization: localization,
                state: state,
                onSelectionIntent: { [weak self] intent, animated in
                    self?.apply(intent, animated: animated)
                },
                onKeyboardFocusTarget: { [weak self] target in
                    self?.prepareForKeyboardInteraction(target)
                },
                onProviderCountChange: { [weak self] count in
                    self?.providerCount = count
                    self?.reposition(animated: false)
                },
                onPointerEntered: { [weak self] screenY in
                    self?.pointerEntered(at: screenY)
                },
                onPointerExited: { [weak self] in
                    self?.pointerExited()
                },
                onRefresh: {
                    Task { await viewModel.refresh() }
                },
                onSettings: onSettings,
                onQuit: onQuit
            )
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name:
                NSWorkspace
                .accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    static func makePanel(contentRect: NSRect) -> NSPanel {
        let panel = SideNotchPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
            .auxiliary
        ]
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        AppAppearancePolicy.followSystem(on: panel)
        return panel
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var mode: SideNotchPanelMode {
        state.mode
    }

    func show(preferredScreen: NSScreen? = nil) {
        cancelReveal()
        cancelAutoHide()
        pointerInside = false
        pointerAnchorY = SideNotchRevealAnchorPolicy.anchorY(
            current: pointerAnchorY,
            for: .programmatic
        )
        providerCount = viewModel.snapshot.providers.count
        state.transition(to: .hidden)
        reposition(on: preferredScreen, animated: false)
        panel.orderFrontRegardless()
    }

    func collapse(animated: Bool = true) {
        cancelReveal()
        cancelAutoHide()
        if state.selection != nil {
            apply(.collapse, animated: animated)
        } else {
            transition(to: .revealed, animated: animated)
        }
        if !pointerInside {
            scheduleAutoHide()
        }
    }

    func hide() {
        cancelReveal()
        cancelAutoHide()
        cancelTransitionCompletion()
        dismissalController.stop()
        escapeDismissalController.stop()
        state.apply(.collapse)
        state.transition(to: .hidden)
        onExpansionChange(false)
        panel.orderOut(nil)
    }

    func toggleRevealed(preferredScreen: NSScreen? = nil) {
        guard isVisible else {
            show(preferredScreen: preferredScreen)
            transition(to: .revealed, animated: true)
            return
        }
        cancelReveal()
        cancelAutoHide()
        if state.mode == .hidden {
            pointerAnchorY = SideNotchRevealAnchorPolicy.anchorY(
                current: pointerAnchorY,
                for: .programmatic
            )
        }
        let nextMode: SideNotchPanelMode =
            state.mode == .hidden ? .revealed : .hidden
        transition(to: nextMode, animated: true)
        if nextMode == .revealed, !pointerInside {
            scheduleAutoHide()
        }
    }

    func pointerEntered(at screenY: CGFloat? = nil) {
        pointerInside = true
        if let screenY {
            pointerAnchorY = SideNotchRevealAnchorPolicy.anchorY(
                current: pointerAnchorY,
                for: .pointerEntered(
                    mode: state.mode,
                    screenY: screenY
                )
            )
        }
        cancelAutoHide()
        if state.mode == .hidden {
            scheduleReveal()
        }
    }

    func pointerExited() {
        pointerInside = false
        cancelReveal()
        if state.selection?.kind == .hovered {
            apply(.exitPanel, animated: true)
        }
        if state.mode == .revealed {
            scheduleAutoHide()
        }
    }

    func setAutoHideDelay(_ delay: TimeInterval) {
        configuredAutoHideDelay = delay
    }

    func stop() {
        hide()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func select(
        _ provider: ProviderID?,
        animated: Bool
    ) {
        cancelReveal()
        cancelAutoHide()
        var nextMode = state.mode
        if let provider {
            nextMode = state.selectedProvider == provider
                ? .revealed
                : .detail(provider)
        } else if state.selectedProvider != nil {
            nextMode = .revealed
        }
        transition(to: nextMode, animated: animated)

        guard case .detail = nextMode else {
            dismissalController.stop()
            escapeDismissalController.stop()
            if !pointerInside {
                scheduleAutoHide()
            }
            return
        }
    }

    private func apply(
        _ intent: SideNotchSelectionIntent,
        animated: Bool
    ) {
        guard confirmsPointerExit(for: intent) else { return }
        cancelReveal()
        cancelAutoHide()

        let reduceMotion = SideNotchMotionPolicy.reduceMotionEnabled(
            systemValue:
                NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion,
            environment: ProcessInfo.processInfo.environment
        )
        let shouldAnimateSelection =
            SideNotchMotionPolicy.shouldAnimateSelectionMutation(
                current: state.selection,
                intent: intent,
                requested: animated,
                reduceMotion: reduceMotion
            )
        var selectionChanged = false
        withAnimation(
            shouldAnimateSelection
                ? .easeOut(duration: SideNotchMotionPolicy.duration)
                : nil
        ) {
            selectionChanged = state.apply(intent)
        }

        guard
            let plan = SideNotchActivationPolicy.plan(
                for: state.selection,
                selectionChanged: selectionChanged
            )
        else {
            // No selection change: no expansion callback, no reposition, and
            // no activation. An incidental hover or a synthetic exit must be
            // completely inert.
            return
        }

        cancelTransitionCompletion()
        onExpansionChange(state.mode.isPresented)
        // AppKit snapshots translucent SwiftUI content while animating a
        // window resize. That renders the rail at both the old and new
        // heights during detail collapse, which reads as a vertical jump.
        // Selection changes therefore resize atomically; hidden-edge
        // reveal/hide remains the only panel-frame animation.
        reposition(animated: false)
        activate(plan)
        if state.selection == nil, !pointerInside {
            scheduleAutoHide()
        }
    }

    /// Drops panel-exit reports that AppKit emits while the panel resizes
    /// under a stationary cursor.
    private func confirmsPointerExit(
        for intent: SideNotchSelectionIntent
    ) -> Bool {
        guard intent == .exitPanel else { return true }
        return SideNotchHoverBoundaryPolicy.confirmsExit(
            pointer: NSEvent.mouseLocation,
            panelFrame: panel.frame
        )
    }

    /// The single place that turns a selection into panel side effects. A
    /// hover preview yields a plan with both flags false, so previewing never
    /// makes the panel key and never arms the outside-click monitor — which is
    /// what keeps keyboard focus with the frontmost application.
    private func activate(_ plan: SideNotchActivationPlan) {
        if plan.activatesApplication {
            NSApp.activate(ignoringOtherApps: true)
        }
        if plan.startsEscapeMonitor {
            escapeDismissalController.start { [weak self] in
                self?.apply(.collapse, animated: true)
            }
        } else {
            escapeDismissalController.stop()
        }

        guard plan.startsDismissalMonitor else {
            dismissalController.stop()
            if plan.makesPanelKey {
                panel.makeKey()
            }
            return
        }

        if plan.makesPanelKey {
            panel.makeKey()
        }
        dismissalController.start(
            isLocalClickOutside: { [weak panel] eventWindow in
                eventWindow !== panel
            },
            onDismiss: { [weak self] in
                self?.apply(.collapse, animated: true)
            }
        )
    }

    private func transition(
        to mode: SideNotchPanelMode,
        animated: Bool
    ) {
        let previousMode = state.mode
        let shouldAnimate = SideNotchMotionPolicy.shouldAnimate(
            requested: animated,
            reduceMotion: SideNotchMotionPolicy.reduceMotionEnabled(
                systemValue:
                    NSWorkspace.shared
                    .accessibilityDisplayShouldReduceMotion,
                environment: ProcessInfo.processInfo.environment
            )
        )
        cancelTransitionCompletion()

        if shouldAnimate, previousMode != mode {
            if mode == .hidden {
                transitionSidewaysToHidden(mode)
                return
            }
            if previousMode == .hidden {
                transitionSidewaysFromHidden(to: mode)
                return
            }
        }

        transitionState(to: mode, animated: false)
        reposition(animated: false)
    }

    private func transitionSidewaysToHidden(
        _ mode: SideNotchPanelMode
    ) {
        guard let screen = targetScreen(nil) else { return }
        let edgeFrame = SideNotchPanelLayout.hideAnimationTarget(
            in: screen.visibleFrame,
            from: panel.frame
        )
        transitionState(to: mode, animated: true)
        animatePanel(to: edgeFrame)
        scheduleHiddenTriggerReset()
    }

    private func transitionSidewaysFromHidden(
        to mode: SideNotchPanelMode
    ) {
        guard let screen = targetScreen(nil) else { return }
        let targetFrame = frame(for: mode, on: screen)
        let edgeFrame = SideNotchPanelLayout.hideAnimationTarget(
            in: screen.visibleFrame,
            from: targetFrame
        )
        panel.setFrame(edgeFrame, display: true)
        transitionState(to: mode, animated: true)
        animatePanel(to: targetFrame)
    }

    private func transitionState(
        to mode: SideNotchPanelMode,
        animated: Bool
    ) {
        withAnimation(
            animated
                ? .easeOut(duration: SideNotchMotionPolicy.duration)
                : nil
        ) {
            state.transition(to: mode)
        }
        if state.selection == nil {
            dismissalController.stop()
            escapeDismissalController.stop()
        }
        onExpansionChange(mode.isPresented)
    }

    private func scheduleHiddenTriggerReset() {
        transitionGeneration += 1
        let generation = transitionGeneration
        transitionCompletionTask = autoHideScheduler.schedule(
            after: SideNotchMotionPolicy.duration
        ) { [weak self] in
            guard
                let self,
                self.transitionGeneration == generation,
                self.state.mode == .hidden
            else {
                return
            }
            self.reposition(animated: false)
            self.transitionCompletionTask = nil
        }
    }

    private func cancelTransitionCompletion() {
        transitionGeneration += 1
        transitionCompletionTask?.cancel()
        transitionCompletionTask = nil
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        guard state.mode == .revealed, !pointerInside else {
            return
        }
        autoHideGeneration += 1
        let generation = autoHideGeneration
        autoHideTask = autoHideScheduler.schedule(
            after: configuredAutoHideDelay
        ) { [weak self] in
            guard
                let self,
                self.autoHideGeneration == generation,
                !self.pointerInside,
                self.state.mode == .revealed
            else {
                return
            }
            self.transition(to: .hidden, animated: true)
            self.autoHideTask = nil
        }
    }

    private func scheduleReveal() {
        cancelReveal()
        guard state.mode == .hidden, pointerInside else {
            return
        }
        revealGeneration += 1
        let generation = revealGeneration
        revealTask = autoHideScheduler.schedule(
            after: Self.revealDelay
        ) { [weak self] in
            guard
                let self,
                self.revealGeneration == generation,
                self.pointerInside,
                self.state.mode == .hidden
            else {
                return
            }
            self.transition(to: .revealed, animated: true)
            self.revealTask = nil
        }
    }

    private func cancelReveal() {
        revealGeneration += 1
        revealTask?.cancel()
        revealTask = nil
    }

    private func cancelAutoHide() {
        autoHideGeneration += 1
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private func prepareForKeyboardInteraction(
        _ target: AccountProviderID
    ) {
        let available = viewModel.snapshot.providers.map(\.accountProviderID)
        guard SideNotchKeyboardFocusPolicy.shouldActivate(
            target: target,
            available: available
        ) else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    private func reposition(animated: Bool) {
        reposition(on: nil, animated: animated)
    }

    private func reposition(
        on preferredScreen: NSScreen?,
        animated: Bool
    ) {
        guard let screen = targetScreen(preferredScreen) else { return }
        let frame = frame(for: state.mode, on: screen)
        guard panel.frame != frame else { return }
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        animatePanel(to: frame)
    }

    private func frame(
        for mode: SideNotchPanelMode,
        on screen: NSScreen
    ) -> NSRect {
        SideNotchPanelLayout.presentationFrame(
            in: screen.visibleFrame,
            providers: viewModel.snapshot.providers,
            mode: mode,
            anchorY: pointerAnchorY,
            language: localization.language
        )
    }

    private func animatePanel(to frame: NSRect) {
        let horizontalStartFrame = NSRect(
            x: panel.frame.minX,
            y: frame.minY,
            width: panel.frame.width,
            height: frame.height
        )
        if panel.frame != horizontalStartFrame {
            panel.setFrame(horizontalStartFrame, display: true)
        }
        guard horizontalStartFrame != frame else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = SideNotchMotionPolicy.duration
            context.timingFunction = CAMediaTimingFunction(
                name: .easeOut
            )
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func targetScreen(_ preferredScreen: NSScreen?) -> NSScreen? {
        if let preferredScreen {
            return preferredScreen
        }
        if panel.isVisible, let screen = panel.screen {
            return screen
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first {
            NSMouseInRect(pointer, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    @objc
    private func screenConfigurationDidChange() {
        reposition(animated: false)
    }
}
