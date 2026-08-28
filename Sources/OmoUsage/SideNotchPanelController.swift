import AppKit
import Observation
import QuartzCore
import SwiftUI

enum SideNotchPanelLayout {
    static let collapsedWidth: CGFloat = 72
    static let expandedWidth: CGFloat = 400
    static let providerRowHeight: CGFloat = 68
    static let verticalPadding: CGFloat = 24
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

    static func shouldAnimate(
        requested: Bool,
        reduceMotion: Bool
    ) -> Bool {
        requested && !reduceMotion
    }
}

@Observable
@MainActor
final class SideNotchPanelState {
    private(set) var selectedProvider: ProviderID?

    func select(_ provider: ProviderID?) {
        selectedProvider = provider
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
                onSelectionChange: { [weak self] provider, animated in
                    self?.select(provider, animated: animated)
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
        select(nil, animated: animated)
    }

    func hide() {
        dismissalController.stop()
        state.select(nil)
        onExpansionChange(false)
        panel.orderOut(nil)
    }

    func toggleExpanded(preferredScreen: NSScreen? = nil) {
        guard isVisible else {
            show(preferredScreen: preferredScreen)
            return
        }
        if state.selectedProvider != nil {
            select(nil, animated: true)
        } else if let firstProvider = viewModel.snapshot.providers.first {
            select(firstProvider.provider, animated: true)
        }
    }

    func stop() {
        hide()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func select(
        _ provider: ProviderID?,
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
            state.select(provider)
        }
        onExpansionChange(provider != nil)
        reposition(animated: shouldAnimate)

        guard provider != nil else {
            dismissalController.stop()
            return
        }

        panel.makeKey()
        dismissalController.start(
            isLocalClickOutside: { [weak panel] eventWindow in
                eventWindow !== panel
            },
            onDismiss: { [weak self] in
                self?.select(nil, animated: true)
            }
        )
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
            isExpanded: state.selectedProvider != nil
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
