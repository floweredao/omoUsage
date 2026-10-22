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

/// The popover's own text size. macOS gives menu-bar extras no system text
/// size, so the compact popover scales its whole type, icon, and spacing
/// scale together up to 200% and widens with it instead of clipping.
enum DashboardTextSize:
    Int,
    CaseIterable,
    Identifiable,
    Sendable
{
    case standard = 100
    case large = 125
    case larger = 150
    case largest = 200

    var id: Int { rawValue }

    var scale: CGFloat { CGFloat(rawValue) / 100 }
}

struct DashboardTextSizeStore {
    static let defaultsKey = "dashboardTextSize"

    let defaults: UserDefaults

    func load() -> DashboardTextSize {
        guard
            let stored = defaults.object(forKey: Self.defaultsKey)
                as? NSNumber
        else {
            return .standard
        }
        guard
            let size = DashboardTextSize(rawValue: stored.intValue)
        else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return .standard
        }
        return size
    }

    func save(_ size: DashboardTextSize) {
        if size == .standard {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(size.rawValue, forKey: Self.defaultsKey)
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
