import OmoUsageCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProviderOrderingAccessibility {
    static func identityName(
        providerName: String,
        accountLabel: String,
        showsAccountLabel: Bool
    ) -> String {
        showsAccountLabel
            ? "\(providerName), \(accountLabel)"
            : providerName
    }

    static func announcement(
        identityName: String,
        position: String
    ) -> String {
        "\(identityName), \(position)"
    }

    /// A row's spoken value. Neither the position nor the connection
    /// state is visible text, so both ride on the row element.
    static func rowValue(position: String, status: String) -> String {
        "\(position), \(status)"
    }
}

struct ProviderOrderingMovePlan: Equatable {
    let fromOffsets: IndexSet
    let toOffset: Int
}

enum ProviderOrderingDrag {
    static func payload(
        for identity: AccountProviderID
    ) -> String {
        "\(identity.accountID.rawValue)|\(identity.providerID.rawValue)"
    }

    static func identity(
        for payload: String,
        in order: [AccountProviderID]
    ) -> AccountProviderID? {
        order.first { self.payload(for: $0) == payload }
    }

    static func movePlan(
        dragged: AccountProviderID,
        onto target: AccountProviderID,
        in order: [AccountProviderID]
    ) -> ProviderOrderingMovePlan? {
        guard
            dragged != target,
            let sourceIndex = order.firstIndex(of: dragged),
            let targetIndex = order.firstIndex(of: target)
        else {
            return nil
        }
        return ProviderOrderingMovePlan(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset:
                sourceIndex < targetIndex
                    ? targetIndex + 1
                    : targetIndex
        )
    }
}

/// Hover changes only this local session. Persistence belongs to an accepted drop.
struct ProviderOrderingDragSession {
    private(set) var dragged: AccountProviderID?
    private(set) var previewOrder: [AccountProviderID]?
    private var originalOrder: [AccountProviderID] = []

    mutating func begin(dragged: AccountProviderID, in order: [AccountProviderID]) {
        self.dragged = dragged
        originalOrder = order
        previewOrder = order
    }

    @discardableResult
    mutating func hover(onto target: AccountProviderID) -> Bool {
        guard let dragged, var order = previewOrder,
              let plan = ProviderOrderingDrag.movePlan(
                dragged: dragged, onto: target, in: order
              ) else { return false }
        order.move(fromOffsets: plan.fromOffsets, toOffset: plan.toOffset)
        previewOrder = order
        return true
    }

    mutating func finish(
        accepted: Bool,
        in order: [AccountProviderID]
    ) -> ProviderOrderingMovePlan? {
        defer {
            dragged = nil
            previewOrder = nil
            originalOrder = []
        }
        guard accepted, order == originalOrder, let dragged,
              let source = order.firstIndex(of: dragged),
              let destination = previewOrder?.firstIndex(of: dragged),
              source != destination else { return nil }
        return ProviderOrderingMovePlan(
            fromOffsets: IndexSet(integer: source),
            toOffset: source < destination ? destination + 1 : destination
        )
    }
}

enum ProviderOrderingTransfer {
    static let type = UTType.utf8PlainText
}

private struct ProviderOrderingDropDelegate: DropDelegate {
    let isActive: Bool
    let entered: () -> Void
    let dropped: () -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        isActive && info.hasItemsConforming(to: [ProviderOrderingTransfer.type])
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { entered() }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        validateDrop(info: info) && dropped()
    }
}

/// SwiftUI's draggable modifier has no session-ended callback on macOS 15.
/// AppKit owns the session so Escape and drops outside the list always roll back.
private struct ProviderOrderingDragHandle: NSViewRepresentable {
    let identity: AccountProviderID
    let label: String
    let animates: Bool
    let began: () -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> HandleView {
        HandleView()
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.payload = ProviderOrderingDrag.payload(for: identity)
        view.began = began
        view.ended = ended
        view.animatesDrag = animates
        view.image = NSImage(
            systemSymbolName: "line.3.horizontal", accessibilityDescription: label
        )
        view.contentTintColor = .secondaryLabelColor
        view.imageScaling = .scaleNone
        view.toolTip = label
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.handle)
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier("provider-ordering-handle.\(view.payload)")
    }

    final class HandleView: NSImageView, NSDraggingSource {
        var payload = ""
        var animatesDrag = true
        var began: (() -> Void)?
        var ended: (() -> Void)?
        private var mouseDownEvent: NSEvent?
        private var sessionEnded: (() -> Void)?
        private var dragInProgress = false

        override func isAccessibilitySelected() -> Bool { dragInProgress }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownEvent = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent, let image,
                  hypot(event.locationInWindow.x - start.locationInWindow.x,
                        event.locationInWindow.y - start.locationInWindow.y) >= 3
            else { return }
            mouseDownEvent = nil
            let writer = NSPasteboardItem()
            writer.setString(
                payload,
                forType: NSPasteboard.PasteboardType(ProviderOrderingTransfer.type.identifier)
            )
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(bounds, contents: image)
            // Capture callbacks before preview reordering updates the source view.
            sessionEnded = ended
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = animatesDrag
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            dragInProgress = true
            began?()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            dragInProgress = false
            sessionEnded?()
            sessionEnded = nil
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
}

/// The Order pane: the grouped form's rows are the draggable accounts,
/// the instruction is the section footer, and Reset to Default follows as
/// its own row. The window title already names the pane.
struct ProviderOrderingView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    /// The resolved status line for the last action, shown under Reset.
    var feedback: String?
    @Environment(\.appLocalization) private var localization
    @FocusState private var focused: AccountProviderID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = ProviderOrderingDragSession()

    var body: some View {
        Section {
            ForEach(Array(items.enumerated()), id: \.element.id) {
                index, item in
                row(item, index: index)
                    // The dragged row stays in place, dimmed, while its
                    // neighbors preview the new order around it.
                    .opacity(drag.dragged == item.id ? 0.5 : 1)
                    .onDrop(
                        of: [ProviderOrderingTransfer.type],
                        delegate: ProviderOrderingDropDelegate(
                            isActive: drag.dragged != nil,
                            entered: { preview(onto: item.id) },
                            dropped: acceptDrop
                        )
                    )
            }
        } footer: {
            SettingsSectionFooter {
                // Grouped-form rows share no container view, so the list's own
                // description is the stable scroll anchor QA drivers reveal.
                Text(localization.text(.dashboardOrderDescription))
                    .accessibilityIdentifier("provider-ordering-list")
            }
        }

        Section {
            Button(localization.text(.resetToDefault)) {
                viewModel.resetAccountProviderOrder()
            }
            .disabled(viewModel.isAccountProviderOrderDefault)
            .onDisappear { cancelDrag() }
            .onChange(of: viewModel.accountProviderOrder) { cancelDrag() }
            .onChange(of: viewModel.accountProviderOrderingItems.map(\.id)) {
                cancelDrag()
            }
        } footer: {
            SettingsSectionFooter {
                if let feedback {
                    Text(feedback)
                        .accessibilityIdentifier("settings-feedback")
                }
            }
        }
    }

    private var items: [AccountProviderOrderingItem] {
        let persisted = viewModel.accountProviderOrderingItems
        guard let preview = drag.previewOrder else { return persisted }
        let byIdentity = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        return preview.compactMap { byIdentity[$0] }
    }

    private func row(
        _ item: AccountProviderOrderingItem,
        index: Int
    ) -> some View {
        let position = localization.format(.orderPosition, index + 1, items.count)
        let identityName = accessibilityLabel(item)
        return HStack(spacing: 8) {
            ProviderOrderingDragHandle(
                identity: item.id,
                label: localization.text(.dragToReorder),
                animates: !reduceMotion,
                began: { drag.begin(dragged: item.id, in: viewModel.accountProviderOrder) },
                ended: cancelDrag
            )
            .frame(width: 24, height: 28)
            ProviderIcon(provider: item.provider)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                if item.showsAccountLabel {
                    Text(item.accountLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            moveButton(item, offset: -1, symbol: "arrow.up", index: index)
            moveButton(item, offset: 1, symbol: "arrow.down", index: index)
        }
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .focused($focused, equals: item.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-ordering-row.\(ProviderOrderingDrag.payload(for: item.id))")
        .accessibilityLabel(identityName)
        .accessibilityValue(
            ProviderOrderingAccessibility.rowValue(
                position: position,
                status: statusText(item)
            )
        )
        .accessibilityAction(named: localization.format(
            .moveUp, identityName
        )) { move(item, by: -1) }
        .accessibilityAction(named: localization.format(
            .moveDown, identityName
        )) { move(item, by: 1) }
    }

    private func preview(onto target: AccountProviderID) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            _ = drag.hover(onto: target)
        }
    }

    private func acceptDrop() -> Bool {
        guard let dragged = drag.dragged else { return false }
        if let plan = drag.finish(accepted: true, in: viewModel.accountProviderOrder) {
            viewModel.moveAccountProviders(
                fromOffsets: plan.fromOffsets,
                toOffset: plan.toOffset
            )
        }
        focused = dragged
        return true
    }

    private func cancelDrag() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            _ = drag.finish(accepted: false, in: viewModel.accountProviderOrder)
        }
    }

    @ViewBuilder
    private func moveButton(
        _ item: AccountProviderOrderingItem,
        offset: Int,
        symbol: String,
        index: Int
    ) -> some View {
        let label = localization.format(
            offset < 0 ? .moveUp : .moveDown,
            accessibilityLabel(item)
        )
        let button = Button { move(item, by: offset) } label: {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(offset < 0 ? index == 0 : index == items.count - 1)
        .accessibilityLabel(label)
        .help(label)

        if focused == item.id {
            button.keyboardShortcut(
                offset < 0 ? .upArrow : .downArrow,
                modifiers: [.command]
            )
        } else {
            button
        }
    }

    private func move(
        _ item: AccountProviderOrderingItem,
        by offset: Int
    ) {
        guard viewModel.moveAccountProvider(item.id, by: offset) else { return }
        focused = item.id
        let visibleOrder = viewModel.accountProviderOrderingItems.map(\.id)
        guard let index = visibleOrder.firstIndex(of: item.id) else { return }
        let message = localization.format(
            .orderPosition,
            index + 1,
            visibleOrder.count
        )
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement:
                    ProviderOrderingAccessibility.announcement(
                        identityName: accessibilityLabel(item),
                        position: message
                    ),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    private func statusText(
        _ item: AccountProviderOrderingItem
    ) -> String {
        if item.isDisconnected {
            return localization.text(.hiddenFromDashboard)
        }
        switch item.availability {
        case .available:
            return localization.text(.connected)
        case .failed, .schemaChanged:
            return localization.text(.checkFailed)
        case .authenticationRequired, .unavailable:
            return localization.text(.notConnected)
        case nil:
            return localization.text(.checking)
        }
    }

    private func accessibilityLabel(
        _ item: AccountProviderOrderingItem
    ) -> String {
        ProviderOrderingAccessibility.identityName(
            providerName: item.provider.displayName,
            accountLabel: item.accountLabel,
            showsAccountLabel: item.showsAccountLabel
        )
    }
}
