import AppKit
import Observation
import OmoUsageCore

/// The Settings window's toolbar panes, in task order. Each pane holds one
/// task group; its title becomes the window title while it is visible.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case accounts
    case display
    case webAccess
    case experimental

    static let legacyDashboardOrderRawValue = "dashboardOrder"

    var id: String { rawValue }

    var titleKey: AppStringKey {
        switch self {
        case .general: .generalSettings
        case .accounts: .providerAuthentication
        case .display: .displaySettings
        case .webAccess: .webAccessSettings
        case .experimental: .experimentalSettings
        }
    }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .display: "macwindow"
        case .webAccess: "globe"
        case .experimental: "flask"
        }
    }

    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("com.omo.usage.settings.\(rawValue)")
    }

    init?(toolbarItemIdentifier: NSToolbarItem.Identifier) {
        guard let pane = Self.allCases.first(where: {
            $0.toolbarItemIdentifier == toolbarItemIdentifier
        }) else { return nil }
        self = pane
    }

    static func restored(from rawValue: String?) -> SettingsPane {
        guard let rawValue else { return .general }
        if rawValue == legacyDashboardOrderRawValue {
            return .display
        }
        return SettingsPane(rawValue: rawValue) ?? .general
    }
}

@MainActor
@Observable
final class SettingsPaneSelection {
    static let defaultsKey = "OmoUsage.settingsPane"

    private(set) var pane: SettingsPane
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pane = SettingsPane.restored(
            from: defaults.string(forKey: Self.defaultsKey)
        )
    }

    func select(_ pane: SettingsPane) {
        self.pane = pane
        defaults.set(pane.rawValue, forKey: Self.defaultsKey)
    }
}

/// A noncustomizable toolbar whose selectable items switch panes and always
/// mark the active one, as Apple's HIG asks of a macOS settings window.
@MainActor
final class SettingsToolbarController: NSObject, NSToolbarDelegate {
    static let toolbarIdentifier = NSToolbar.Identifier(
        "com.omo.usage.settings"
    )

    let toolbar: NSToolbar
    private let selection: SettingsPaneSelection
    private var title: (SettingsPane) -> String
    private let onSelect: (SettingsPane) -> Void

    init(
        selection: SettingsPaneSelection,
        title: @escaping (SettingsPane) -> String,
        onSelect: @escaping (SettingsPane) -> Void
    ) {
        self.selection = selection
        self.title = title
        self.onSelect = onSelect
        toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        super.init()
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier =
            selection.pane.toolbarItemIdentifier
    }

    func relabel(title: @escaping (SettingsPane) -> String) {
        self.title = title
        for item in toolbar.items {
            guard let pane = SettingsPane(
                toolbarItemIdentifier: item.itemIdentifier
            ) else { continue }
            item.label = title(pane)
            item.possibleLabels = allTitles()
            item.image = image(for: pane)
        }
    }

    /// Every pane title in the current language. Each item reserves room for
    /// all of them, so the five toolbar items share the widest label's width.
    func allTitles() -> Set<String> {
        Set(SettingsPane.allCases.map(title))
    }

    func toolbarDefaultItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarAllowedItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(
        _ toolbar: NSToolbar
    ) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(
            toolbarItemIdentifier: itemIdentifier
        ) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = title(pane)
        item.possibleLabels = allTitles()
        item.image = image(for: pane)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc
    func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane(
            toolbarItemIdentifier: sender.itemIdentifier
        ) else { return }
        toolbar.selectedItemIdentifier = sender.itemIdentifier
        guard pane != selection.pane else { return }
        selection.select(pane)
        onSelect(pane)
    }

    private func image(for pane: SettingsPane) -> NSImage? {
        NSImage(
            systemSymbolName: pane.systemImageName,
            accessibilityDescription: nil
        )
    }
}
