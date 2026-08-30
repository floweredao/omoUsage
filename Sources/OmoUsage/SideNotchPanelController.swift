import AppKit
import Observation
import QuartzCore
import SwiftUI

enum SideNotchPanelLayout {
    static let collapsedWidth: CGFloat = 72
    static let expandedWidth: CGFloat = 400
    static let providerRowHeight: CGFloat = 68
    static let verticalPadding: CGFloat = 24
    static let footerClearance: CGFloat = 8
    static let footerHeight: CGFloat = 48
    static let detailMaximumHeight: CGFloat = 360
    static let minimumHeight: CGFloat = 164
    static let screenMargin: CGFloat = 20

    static func detailHeight(for usage: ProviderUsage) -> CGFloat {
        min(
            detailMaximumHeight,
            DashboardLayout.sectionHeight(usage) + 28
        )
    }

    static func frame(
        in visibleFrame: NSRect,
        providerCount: Int,
        isExpanded: Bool
    ) -> NSRect {
        let desiredHeight = max(
            minimumHeight,
            verticalPadding
                + CGFloat(providerCount) * providerRowHeight
                + footerClearance
                + footerHeight
        )
        let maximumHeight = max(
            minimumHeight,
            visibleFrame.height - screenMargin * 2
        )
        let height = min(desiredHeight, maximumHeight)
        let width = isExpanded ? expandedWidth : collapsedWidth
        let proposedY = visibleFrame.midY - height / 2
        let minimumY = visibleFrame.minY + screenMargin
        let maximumY = visibleFrame.maxY - screenMargin - height
        let y = min(max(proposedY, minimumY), maximumY)

        return NSRect(
            x: visibleFrame.maxX - width,
            y: y,
            width: width,
            height: height
        )
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
        current: SideNotchSelection?,
        intent: SideNotchSelectionIntent,
        requested: Bool,
        reduceMotion: Bool
    ) -> Bool {
        guard shouldAnimate(
            requested: requested,
            reduceMotion: reduceMotion
        ) else {
            return false
        }

        switch intent {
        case .hover:
            return current == nil
        case .exitPanel:
            return current?.kind == .hovered
        case let .commit(target):
            guard let current else { return true }
            return current.kind == .pinned && current.target == target
        case .collapse:
            return current != nil
        case let .reconcile(available):
            guard let current else { return false }
            return !available.contains(current.target)
        }
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

@Observable
@MainActor
final class SideNotchPanelState {
    private(set) var selection: SideNotchSelection?

    var selectedTarget: AccountProviderID? {
        selection?.target
    }

    var isPinned: Bool {
        selection?.kind == .pinned
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
        return selection != previous
    }
}

final class SideNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SideNotchPanelController: NSObject {
    private let viewModel: UsageDashboardViewModel
    private let state = SideNotchPanelState()
    private let panel: NSPanel
    private let onExpansionChange: @MainActor (Bool) -> Void
    private let dismissalController = PopoverDismissalController(
        monitor: AppKitPopoverMouseMonitor()
    )
    private let escapeDismissalController =
        SideNotchEscapeDismissalController(
            monitor: AppKitSideNotchEscapeMonitor()
        )
    private var providerCount = 0

    init(
        viewModel: UsageDashboardViewModel,
        localization: LocalizationController,
        onExpansionChange: @escaping @MainActor (Bool) -> Void,
        onSettings: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.viewModel = viewModel
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

    func show(preferredScreen: NSScreen? = nil) {
        providerCount = viewModel.snapshot.providers.count
        reposition(on: preferredScreen, animated: false)
        panel.orderFrontRegardless()
    }

    func collapse(animated: Bool = true) {
        apply(.collapse, animated: animated)
    }

    func hide() {
        dismissalController.stop()
        escapeDismissalController.stop()
        state.apply(.collapse)
        onExpansionChange(false)
        panel.orderOut(nil)
    }

    func toggleExpanded(preferredScreen: NSScreen? = nil) {
        guard isVisible else {
            show(preferredScreen: preferredScreen)
            return
        }
        if state.selection != nil {
            apply(.collapse, animated: true)
        } else if let firstProvider = viewModel.snapshot.providers.first {
            apply(
                .commit(firstProvider.accountProviderID),
                animated: true
            )
        }
    }

    func stop() {
        hide()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func apply(
        _ intent: SideNotchSelectionIntent,
        animated: Bool
    ) {
        guard confirmsPointerExit(for: intent) else { return }

        let reduceMotion = SideNotchMotionPolicy.reduceMotionEnabled(
            systemValue:
                NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion,
            environment: ProcessInfo.processInfo.environment
        )
        let shouldAnimate = SideNotchMotionPolicy.shouldAnimate(
            requested: animated,
            reduceMotion: reduceMotion
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

        onExpansionChange(state.selection != nil)
        reposition(animated: shouldAnimate)
        activate(plan)
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
        let frame = SideNotchPanelLayout.frame(
            in: screen.visibleFrame,
            providerCount: providerCount,
            isExpanded: state.selection != nil
        )
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
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
