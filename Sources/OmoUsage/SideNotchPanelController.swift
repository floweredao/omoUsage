import AppKit
import Observation
import QuartzCore
import SwiftUI

enum SideNotchPanelLayout {
    static let hiddenWidth: CGFloat = 6
    static let collapsedWidth: CGFloat = 56
    static let detailWidth: CGFloat = 280
    static let detailSpacing: CGFloat = 8
    static let expandedWidth: CGFloat = 344
    static let providerRowHeight: CGFloat = 58
    static let verticalPadding: CGFloat = 14
    static let footerHeight: CGFloat = 58
    static let detailMaximumHeight: CGFloat = 320
    static let maximumPanelHeight: CGFloat = 540
    static let minimumHeight: CGFloat = 128
    static let screenMargin: CGFloat = 20
    static let railCornerRadius: CGFloat = 20
    static let ringDiameter: CGFloat = 36
    static let providerIconSize: CGFloat = 22

    static func detailHeight(for usage: ProviderUsage) -> CGFloat {
        min(
            detailMaximumHeight,
            DashboardLayout.sectionHeight(usage) + 24
        )
    }

    static func frame(
        in visibleFrame: NSRect,
        providerCount: Int,
        mode: SideNotchPanelMode
    ) -> NSRect {
        let desiredHeight = max(
            minimumHeight,
            verticalPadding
                + CGFloat(providerCount) * providerRowHeight
                + footerHeight
        )
        let maximumHeight = min(
            maximumPanelHeight,
            max(
                minimumHeight,
                visibleFrame.height - screenMargin * 2
            )
        )
        let height = min(desiredHeight, maximumHeight)
        let width: CGFloat = switch mode {
        case .hidden:
            hiddenWidth
        case .revealed:
            collapsedWidth
        case .detail:
            expandedWidth
        }
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

enum SideNotchMotionPolicy {
    static let duration = 0.2

    static func shouldAnimate(
        requested: Bool,
        reduceMotion: Bool
    ) -> Bool {
        requested && !reduceMotion
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

    var selectedProvider: ProviderID? {
        mode.selectedProvider
    }

    func transition(to mode: SideNotchPanelMode) {
        self.mode = mode
    }

    func toggleRevealed() {
        mode = mode == .hidden ? .revealed : .hidden
    }

    func select(_ provider: ProviderID?) {
        guard let provider else {
            if selectedProvider != nil {
                mode = .revealed
            }
            return
        }
        mode = selectedProvider == provider
            ? .revealed
            : .detail(provider)
    }

    func reconcile(providers: [ProviderID]) {
        guard
            let selectedProvider,
            !providers.contains(selectedProvider)
        else {
            return
        }
        mode = .revealed
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
    private let state = SideNotchPanelState()
    private let panel: NSPanel
    private let autoHideScheduler: any SideNotchAutoHideScheduling
    private let onExpansionChange: @MainActor (Bool) -> Void
    private let dismissalController = PopoverDismissalController(
        monitor: AppKitPopoverMouseMonitor()
    )
    private var providerCount = 0
    private var pointerInside = false
    private var autoHideGeneration = 0
    private var autoHideTask: (any SideNotchAutoHideTask)?
    static let autoHideDelay: TimeInterval = 0.8

    init(
        viewModel: UsageDashboardViewModel,
        localization: LocalizationController,
        autoHideScheduler: any SideNotchAutoHideScheduling =
            DispatchSideNotchAutoHideScheduler(),
        onExpansionChange: @escaping @MainActor (Bool) -> Void,
        onSettings: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.viewModel = viewModel
        self.autoHideScheduler = autoHideScheduler
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
                onSelectionChange: { [weak self] provider, animated in
                    self?.select(provider, animated: animated)
                },
                onProviderCountChange: { [weak self] count in
                    self?.providerCount = count
                    self?.reposition(animated: false)
                },
                onPointerEntered: { [weak self] in
                    self?.pointerEntered()
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
        providerCount = viewModel.snapshot.providers.count
        state.transition(to: .hidden)
        reposition(on: preferredScreen, animated: false)
        panel.orderFrontRegardless()
    }

    func collapse(animated: Bool = true) {
        transition(to: .revealed, animated: animated)
        if !pointerInside {
            scheduleAutoHide()
        }
    }

    func hide() {
        cancelAutoHide()
        dismissalController.stop()
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
        cancelAutoHide()
        let nextMode: SideNotchPanelMode =
            state.mode == .hidden ? .revealed : .hidden
        transition(to: nextMode, animated: true)
        if nextMode == .revealed, !pointerInside {
            scheduleAutoHide()
        }
    }

    func pointerEntered() {
        pointerInside = true
        cancelAutoHide()
        if state.mode == .hidden {
            transition(to: .revealed, animated: true)
        }
    }

    func pointerExited() {
        pointerInside = false
        if state.mode == .revealed {
            scheduleAutoHide()
        }
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
            if !pointerInside {
                scheduleAutoHide()
            }
            return
        }

        panel.makeKey()
        dismissalController.start(
            isLocalClickOutside: { [weak panel] eventWindow in
                eventWindow !== panel
            },
            onDismiss: { [weak self] in
                self?.collapse(animated: true)
            }
        )
    }

    private func transition(
        to mode: SideNotchPanelMode,
        animated: Bool
    ) {
        let shouldAnimate = SideNotchMotionPolicy.shouldAnimate(
            requested: animated,
            reduceMotion:
                NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion
        )
        withAnimation(
            shouldAnimate
                ? .easeOut(duration: SideNotchMotionPolicy.duration)
                : nil
        ) {
            state.transition(to: mode)
        }
        onExpansionChange(mode.isPresented)
        reposition(animated: shouldAnimate)
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        guard state.mode == .revealed, !pointerInside else {
            return
        }
        autoHideGeneration += 1
        let generation = autoHideGeneration
        autoHideTask = autoHideScheduler.schedule(
            after: Self.autoHideDelay
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

    private func cancelAutoHide() {
        autoHideGeneration += 1
        autoHideTask?.cancel()
        autoHideTask = nil
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
            mode: state.mode
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
