import Foundation

enum DashboardPresentationStyle: String, CaseIterable, Identifiable, Sendable {
    case popover
    case sideNotch

    var id: String { rawValue }
}

struct DashboardPresentationStyleStore {
    static let defaultsKey = "dashboardPresentationStyle"

    let defaults: UserDefaults

    func load() -> DashboardPresentationStyle {
        guard
            let rawValue = defaults.string(forKey: Self.defaultsKey)
        else {
            return .popover
        }
        guard
            let style = DashboardPresentationStyle(rawValue: rawValue)
        else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return .popover
        }
        return style
    }

    func save(_ style: DashboardPresentationStyle) {
        if style == .popover {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(style.rawValue, forKey: Self.defaultsKey)
        }
    }
}
