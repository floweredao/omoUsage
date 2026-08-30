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

struct ProviderOrderingView: View {
    @Bindable var viewModel: UsageDashboardViewModel
    @Environment(\.appLocalization) private var localization
    @FocusState private var focused: AccountProviderID?

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
                }
                .onMove(perform: viewModel.moveAccountProviders)
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
        case .failed:
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
