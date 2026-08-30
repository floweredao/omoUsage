import AppKit
import SwiftUI

enum ProviderOrderingLayout {
    static let rowHeight: CGFloat = 60
    static let verticalRowInset: CGFloat = 0

    static func listHeight(itemCount: Int) -> CGFloat {
        rowHeight * CGFloat(max(1, itemCount))
    }
}

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

struct ProviderOrderingView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    @Environment(\.appLocalization) private var localization
    @FocusState private var focused: AccountProviderID?
    @State private var dropTarget: AccountProviderID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localization.text(.dashboardOrder))
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button(localization.text(.resetToDefault)) {
                    viewModel.resetAccountProviderOrder()
                }
                .controlSize(.small)
                .disabled(viewModel.isAccountProviderOrderDefault)
            }

            List {
                ForEach(Array(items.enumerated()), id: \.element.id) {
                    index, item in
                    row(item, index: index)
                        .listRowInsets(
                            EdgeInsets(
                                top: ProviderOrderingLayout.verticalRowInset,
                                leading: 8,
                                bottom:
                                    ProviderOrderingLayout.verticalRowInset,
                                trailing: 8
                            )
                        )
                        .listRowSeparator(.hidden)
                        .background(
                            Color.accentColor.opacity(
                                dropTarget == item.id ? 0.10 : 0
                            ),
                            in: RoundedRectangle(
                                cornerRadius: 8,
                                style: .continuous
                            )
                        )
                        .dropDestination(for: String.self) {
                            payloads,
                            _ in
                            handleDrop(
                                payloads: payloads,
                                onto: item.id
                            )
                        } isTargeted: { isTargeted in
                            dropTarget = isTargeted ? item.id : nil
                        }
                }
            }
            .listStyle(.plain)
            .scrollDisabled(true)
            .environment(
                \.defaultMinListRowHeight,
                ProviderOrderingLayout.rowHeight
            )
            .contentMargins(.vertical, 0, for: .scrollContent)
            .frame(
                height: ProviderOrderingLayout.listHeight(
                    itemCount: items.count
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SettingsRowVisualTokens.border, lineWidth: 0.5)
            }
        }
    }

    private var items: [AccountProviderOrderingItem] {
        viewModel.accountProviderOrderingItems
    }

    private func row(
        _ item: AccountProviderOrderingItem,
        index: Int
    ) -> some View {
        let position = localization.format(.orderPosition, index + 1, items.count)
        let identityName = accessibilityLabel(item)
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help(localization.text(.dragToReorder))
                .draggable(
                    ProviderOrderingDrag.payload(for: item.id)
                )
            ProviderIcon(provider: item.provider)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.provider.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                if item.showsAccountLabel {
                    Text(item.accountLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(statusText(item))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(position)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            moveButton(item, offset: -1, symbol: "arrow.up", index: index)
            moveButton(item, offset: 1, symbol: "arrow.down", index: index)
        }
        .frame(height: ProviderOrderingLayout.rowHeight)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused, equals: item.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(identityName)
        .accessibilityValue(position)
        .accessibilityAction(named: localization.format(
            .moveUp, identityName
        )) { move(item, by: -1) }
        .accessibilityAction(named: localization.format(
            .moveDown, identityName
        )) { move(item, by: 1) }
    }

    private func handleDrop(
        payloads: [String],
        onto target: AccountProviderID
    ) -> Bool {
        defer { dropTarget = nil }
        guard
            let payload = payloads.first,
            let dragged = ProviderOrderingDrag.identity(
                for: payload,
                in: viewModel.accountProviderOrder
            ),
            let plan = ProviderOrderingDrag.movePlan(
                dragged: dragged,
                onto: target,
                in: viewModel.accountProviderOrder
            )
        else {
            return false
        }
        viewModel.moveAccountProviders(
            fromOffsets: plan.fromOffsets,
            toOffset: plan.toOffset
        )
        focused = dragged
        return true
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
        guard let index = viewModel.accountProviderOrder.firstIndex(of: item.id)
        else { return }
        let message = localization.format(
            .orderPosition,
            index + 1,
            viewModel.accountProviderOrder.count
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
