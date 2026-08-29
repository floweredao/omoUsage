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

enum SideNotchHideDelay:
    Double,
    CaseIterable,
    Identifiable,
    Sendable
{
    case short = 0.4
    case standard = 0.8
    case long = 1.2
    case extraLong = 2.0

    var id: Double { rawValue }
}

struct SideNotchHideDelayStore {
    static let defaultsKey = "sideNotchHideDelay"

    let defaults: UserDefaults

    func load() -> SideNotchHideDelay {
        guard
            let stored = defaults.object(forKey: Self.defaultsKey)
                as? NSNumber
        else {
            return .standard
        }
        guard
            let delay = SideNotchHideDelay(
                rawValue: stored.doubleValue
            )
        else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return .standard
        }
        return delay
    }

    func save(_ delay: SideNotchHideDelay) {
        if delay == .standard {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(delay.rawValue, forKey: Self.defaultsKey)
        }
    }
}
