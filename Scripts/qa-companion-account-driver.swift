// Accessibility driver for Scripts/qa-companion-account-add.sh.
//
// Drives the packaged OmoUsage settings UI through the macOS
// Accessibility API. Every wait is a bounded state wait: it polls the
// requested element until the deadline and then fails loudly. Nothing
// here fabricates success — a missing permission exits with code 3 and a
// concrete instruction.

import AppKit
import ApplicationServices
import Foundation

struct DriverArguments {
    var action = ""
    var pid: pid_t = 0
    var identifier = ""
    var value = ""
    var file = ""
    var timeout: TimeInterval = 20
    var prefersHighestLayer = false
    var scrolls = false
}

enum DriverExit: Int32 {
    case usage = 64
    case failed = 1
    case permission = 3
}

func fail(_ message: String, _ code: DriverExit) -> Never {
    FileHandle.standardError.write(Data("qa-driver: \(message)\n".utf8))
    exit(code.rawValue)
}

func parseArguments() -> DriverArguments {
    var arguments = DriverArguments()
    var index = 1
    let raw = CommandLine.arguments
    while index < raw.count {
        let flag = raw[index]
        func next() -> String {
            guard index + 1 < raw.count else {
                fail("missing value for \(flag)", .usage)
            }
            index += 1
            return raw[index]
        }
        switch flag {
        case "--action": arguments.action = next()
        case "--pid":
            guard let value = pid_t(next()) else {
                fail("invalid --pid", .usage)
            }
            arguments.pid = value
        case "--identifier": arguments.identifier = next()
        case "--value": arguments.value = next()
        case "--file": arguments.file = next()
        case "--timeout":
            guard let value = TimeInterval(next()), value > 0 else {
                fail("invalid --timeout", .usage)
            }
            arguments.timeout = value
        case "--highest-layer": arguments.prefersHighestLayer = true
        case "--scroll": arguments.scrolls = true
        default: fail("unknown argument \(flag)", .usage)
        }
        index += 1
    }
    guard !arguments.action.isEmpty else { fail("missing --action", .usage) }
    guard arguments.pid > 0 else { fail("missing --pid", .usage) }
    return arguments
}

func requireAccessibilityTrust() {
    guard AXIsProcessTrusted() else {
        fail(
            """
            this process is not trusted for Accessibility control. \
            Grant Accessibility to the terminal or automation host running \
            this script in System Settings > Privacy & Security > \
            Accessibility, then rerun. No UI evidence was produced.
            """,
            .permission
        )
    }
}

func attribute(
    _ element: AXUIElement,
    _ name: String
) -> CFTypeRef? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
        element,
        name as CFString,
        &value
    )
    return status == .success ? value : nil
}

func children(of element: AXUIElement) -> [AXUIElement] {
    guard
        let value = attribute(element, kAXChildrenAttribute as String),
        let elements = value as? [AXUIElement]
    else {
        return []
    }
    return elements
}

func identifier(of element: AXUIElement) -> String? {
    attribute(element, kAXIdentifierAttribute as String) as? String
}

func describe(_ element: AXUIElement) -> String {
    let role = attribute(element, kAXRoleAttribute as String) as? String
    let title = attribute(element, kAXTitleAttribute as String) as? String
    let value = attribute(element, kAXValueAttribute as String) as? String
    return [
        identifier(of: element).map { "id=\($0)" },
        role.map { "role=\($0)" },
        title.map { "title=\($0)" },
        value.map { "value=\($0)" }
    ]
    .compactMap { $0 }
    .joined(separator: " ")
}

func walk(
    _ element: AXUIElement,
    depth: Int = 0,
    visit: (AXUIElement, Int) -> Bool
) -> Bool {
    guard depth < 60 else { return false }
    if visit(element, depth) { return true }
    for child in children(of: element) {
        if walk(child, depth: depth + 1, visit: visit) { return true }
    }
    return false
}

func findElement(
    application: AXUIElement,
    identifier target: String
) -> AXUIElement? {
    // Driver query syntax, NOT a production AX identifier. Added accounts get
    // random UUIDs, so find the stable saved-name element by its fixture alias.
    let labelQueryPrefix = "query:account-label:codex:"
    let accountLabel = target.hasPrefix(labelQueryPrefix)
        ? String(target.dropFirst(labelQueryPrefix.count)) : nil
    var found: AXUIElement?
    _ = walk(application) { element, _ in
        let id = identifier(of: element) ?? ""
        if let accountLabel {
            guard id.hasPrefix("account-name-codex-"),
                  [kAXValueAttribute, kAXTitleAttribute].contains(where: {
                      attribute(element, $0) as? String == accountLabel
                  }) else { return false }
        } else {
            guard id == target else { return false }
        }
        found = element
        return true
    }
    return found
}

/// Bounded state wait: polls until the predicate holds or the deadline
/// passes. There is no unconditional sleep anywhere in this driver.
func waitUntil(
    timeout: TimeInterval,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return predicate()
}

func windowEntry(
    pid: pid_t,
    prefersHighestLayer: Bool
) -> [String: Any]? {
    guard
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
    else {
        return nil
    }
    let owned = info.filter { entry in
        (entry[kCGWindowOwnerPID as String] as? pid_t) == pid
            && ((entry[kCGWindowBounds as String] as? [String: Any])?[
                "Height"
            ] as? Double ?? 0) > 80
    }
    let sorted = owned.sorted { first, second in
        let firstLayer = first[kCGWindowLayer as String] as? Int ?? 0
        let secondLayer = second[kCGWindowLayer as String] as? Int ?? 0
        return prefersHighestLayer
            ? firstLayer > secondLayer
            : firstLayer < secondLayer
    }
    return sorted.first
}

func windowIdentifier(
    pid: pid_t,
    prefersHighestLayer: Bool
) -> CGWindowID? {
    windowEntry(pid: pid, prefersHighestLayer: prefersHighestLayer)?[
        kCGWindowNumber as String
    ] as? CGWindowID
}

func windowCenter(
    pid: pid_t,
    prefersHighestLayer: Bool = false
) -> CGPoint? {
    guard
        let bounds = windowEntry(pid: pid, prefersHighestLayer: prefersHighestLayer)?[
            kCGWindowBounds as String
        ] as? [String: Any],
        let x = bounds["X"] as? Double,
        let y = bounds["Y"] as? Double,
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double
    else {
        return nil
    }
    return CGPoint(x: x + width / 2, y: y + height / 2)
}

/// Scrolls the settings list one step. The list is lazy, so an element
/// that is off-screen does not exist in the accessibility tree at all and
/// no amount of waiting can reveal it.
func scrollStep(at point: CGPoint, lines: Int32) {
    CGWarpMouseCursorPosition(point)
    CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: lines,
        wheel2: 0,
        wheel3: 0
    )?.post(tap: .cghidEventTap)
}

func windowFrame(
    pid: pid_t,
    prefersHighestLayer: Bool = false
) -> CGRect? {
    guard
        let bounds = windowEntry(pid: pid, prefersHighestLayer: prefersHighestLayer)?[
            kCGWindowBounds as String
        ] as? [String: Any],
        let x = bounds["X"] as? Double,
        let y = bounds["Y"] as? Double,
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double
    else {
        return nil
    }
    return CGRect(x: x, y: y, width: width, height: height)
}

func elementFrame(_ element: AXUIElement) -> CGRect? {
    guard
        let positionValue = attribute(element, kAXPositionAttribute as String),
        let sizeValue = attribute(element, kAXSizeAttribute as String),
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
        return nil
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    // swiftlint:disable force_cast
    guard
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else {
        return nil
    }
    // swiftlint:enable force_cast
    return CGRect(origin: origin, size: size)
}

func ancestor(
    of element: AXUIElement,
    withRole expectedRole: String
) -> AXUIElement? {
    var current: AXUIElement? = element
    for _ in 0..<60 {
        guard let candidate = current else { return nil }
        if attribute(candidate, kAXRoleAttribute as String) as? String
            == expectedRole {
            return candidate
        }
        guard
            let value = attribute(candidate, kAXParentAttribute as String),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        // swiftlint:disable:next force_cast
        current = (value as! AXUIElement)
    }
    return nil
}

func containingWindow(of element: AXUIElement) -> AXUIElement? {
    if
        let popover = ancestor(of: element, withRole: "AXPopover"),
        elementFrame(popover) != nil
    {
        return popover
    }
    if
        let value = attribute(element, kAXWindowAttribute as String),
        CFGetTypeID(value) == AXUIElementGetTypeID()
    {
        // swiftlint:disable:next force_cast
        let window = value as! AXUIElement
        if elementFrame(window) != nil { return window }
    }
    return nil
}

func scrollableAncestor(of element: AXUIElement) -> AXUIElement? {
    ancestor(of: element, withRole: kAXScrollAreaRole as String)
}

var sweepCounter = 0
var sweepDirection: Int32 = -3

/// Bounded search: polls for the element and, when scrolling is allowed,
/// sweeps the lazy list from the top downwards until the deadline.
func locate(
    application: AXUIElement,
    pid: pid_t,
    identifier target: String,
    timeout: TimeInterval,
    scrolls: Bool,
    prefersHighestLayer: Bool = false
) -> AXUIElement? {
    var element: AXUIElement?
    let found = waitUntil(timeout: timeout) {
        element = findElement(application: application, identifier: target)
        if element != nil { return true }
        guard
            scrolls,
            let center = windowCenter(
                pid: pid,
                prefersHighestLayer: prefersHighestLayer
            )
        else {
            return false
        }
        let origin = CGEvent(source: nil)?.location
        scrollStep(at: center, lines: sweepDirection)
        sweepCounter += 1
        if sweepCounter % 12 == 0 {
            sweepDirection = -sweepDirection
        }
        if let origin { CGWarpMouseCursorPosition(origin) }
        element = findElement(application: application, identifier: target)
        return element != nil
    }
    return found ? element : nil
}

func isCompanionFixtureFile(_ path: String) -> Bool {
    path.hasPrefix("/tmp/omousage-companion-qa-")
}

func fixtureFileValue(at path: String) -> String? {
    guard isCompanionFixtureFile(path) else { return nil }
    return try? String(
        contentsOfFile: path,
        encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
}

func reactivateTargetApplication(pid: pid_t, timeout: TimeInterval) {
    guard let target = NSRunningApplication(processIdentifier: pid) else {
        fail("target application process \(pid) is unavailable", .failed)
    }
    guard let finder = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.apple.finder"
    }) else {
        fail("Finder is unavailable to drive target deactivation", .failed)
    }
    guard finder.activate(options: []) else {
        fail("Finder could not be activated to deactivate the target", .failed)
    }
    guard waitUntil(timeout: timeout, { !target.isActive }) else {
        fail("target application did not leave active state", .failed)
    }
    guard target.activate(options: []) else {
        fail("target application could not be reactivated", .failed)
    }
    guard waitUntil(timeout: timeout, { target.isActive }) else {
        fail("target application did not return to active state", .failed)
    }
}

let arguments = parseArguments()
let application = AXUIElementCreateApplication(arguments.pid)

switch arguments.action {
case "window-id":
    var identifier: CGWindowID?
    guard
        waitUntil(timeout: arguments.timeout, {
            identifier = windowIdentifier(
                pid: arguments.pid,
                prefersHighestLayer: arguments.prefersHighestLayer
            )
            return identifier != nil
        }),
        let identifier
    else {
        fail(
            "no on-screen window for pid \(arguments.pid) within "
                + "\(arguments.timeout)s",
            .failed
        )
    }
    print(identifier)

case "wait-file-value":
    guard !arguments.file.isEmpty else {
        fail("missing --file", .usage)
    }
    guard isCompanionFixtureFile(arguments.file) else {
        fail("fixture file must be confined to the companion QA root", .usage)
    }
    guard
        waitUntil(timeout: arguments.timeout, {
            (fixtureFileValue(at: arguments.file) ?? "0") == arguments.value
        })
    else {
        fail(
            "fixture file \(arguments.file) did not reach \(arguments.value)",
            .failed
        )
    }
    print(arguments.value)

case "wait":
    requireAccessibilityTrust()
    guard
        locate(
            application: application,
            pid: arguments.pid,
            identifier: arguments.identifier,
            timeout: arguments.timeout,
            scrolls: arguments.scrolls,
            prefersHighestLayer: arguments.prefersHighestLayer
        ) != nil
    else {
        fail(
            "element \(arguments.identifier) never appeared within "
                + "\(arguments.timeout)s",
            .failed
        )
    }

case "wait-absent":
    requireAccessibilityTrust()
    guard
        waitUntil(timeout: arguments.timeout, {
            findElement(
                application: application,
                identifier: arguments.identifier
            ) == nil
        })
    else {
        fail(
            "element \(arguments.identifier) was still present after "
                + "\(arguments.timeout)s",
            .failed
        )
    }

case "press":
    requireAccessibilityTrust()
    guard
        let element = locate(
            application: application,
            pid: arguments.pid,
            identifier: arguments.identifier,
            timeout: arguments.timeout,
            scrolls: arguments.scrolls
        )
    else {
        fail("element \(arguments.identifier) not found", .failed)
    }
    let status = AXUIElementPerformAction(
        element,
        kAXPressAction as CFString
    )
    guard status == .success else {
        fail(
            "press on \(arguments.identifier) failed with AX status "
                + "\(status.rawValue)",
            .failed
        )
    }

case "set-value":
    requireAccessibilityTrust()
    guard
        let element = locate(
            application: application,
            pid: arguments.pid,
            identifier: arguments.identifier,
            timeout: arguments.timeout,
            scrolls: arguments.scrolls
        )
    else {
        fail("element \(arguments.identifier) not found", .failed)
    }
    AXUIElementSetAttributeValue(
        element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    let status = AXUIElementSetAttributeValue(
        element,
        kAXValueAttribute as CFString,
        arguments.value as CFString
    )
    guard status == .success else {
        fail(
            "set-value on \(arguments.identifier) failed with AX status "
                + "\(status.rawValue)",
            .failed
        )
    }
    guard
        waitUntil(timeout: arguments.timeout, {
            (attribute(element, kAXValueAttribute as String) as? String)
                == arguments.value
        })
    else {
        fail(
            "set-value on \(arguments.identifier) did not stick",
            .failed
        )
    }

case "scroll-to":
    requireAccessibilityTrust()
    guard
        let element = locate(
            application: application,
            pid: arguments.pid,
            identifier: arguments.identifier,
            timeout: arguments.timeout,
            scrolls: true,
            prefersHighestLayer: arguments.prefersHighestLayer
        )
    else {
        fail("element \(arguments.identifier) not found", .failed)
    }
    guard
        let owningWindow = containingWindow(of: element),
        let window = elementFrame(owningWindow),
        let scrollArea = scrollableAncestor(of: element),
        let visible = elementFrame(scrollArea)
    else {
        fail(
            "element \(arguments.identifier) has no owning AX scroll area",
            .failed
        )
    }
    guard
        waitUntil(timeout: arguments.timeout, {
            guard let frame = elementFrame(element) else { return false }
            if visible.contains(frame.origin)
                && visible.contains(
                    CGPoint(x: frame.midX, y: frame.maxY)
                )
            {
                return true
            }
            let lines: Int32 = frame.midY < visible.midY ? 3 : -3
            let origin = CGEvent(source: nil)?.location
            scrollStep(
                at: CGPoint(x: visible.midX, y: visible.midY),
                lines: lines
            )
            if let origin { CGWarpMouseCursorPosition(origin) }
            return false
        })
    else {
        let targetFrame = elementFrame(element)?.debugDescription ?? "none"
        fail(
            "could not bring \(arguments.identifier) fully into view "
                + "(target=\(targetFrame), window=\(window.debugDescription))",
            .failed
        )
    }

case "value":
    requireAccessibilityTrust()
    guard
        let element = locate(
            application: application,
            pid: arguments.pid,
            identifier: arguments.identifier,
            timeout: arguments.timeout,
            scrolls: arguments.scrolls
        ),
        let value = attribute(element, kAXValueAttribute as String) as? String
    else {
        fail("no value for \(arguments.identifier)", .failed)
    }
    print(value)

case "reactivate":
    requireAccessibilityTrust()
    reactivateTargetApplication(
        pid: arguments.pid,
        timeout: arguments.timeout
    )
    print("target-left-active-and-reactivated")

case "menubar-press":
    requireAccessibilityTrust()
    var target: AXUIElement?
    guard
        waitUntil(timeout: arguments.timeout, {
            guard
                let extras = attribute(application, "AXExtrasMenuBar"),
                CFGetTypeID(extras) == AXUIElementGetTypeID()
            else {
                return false
            }
            // swiftlint:disable:next force_cast
            let bar = extras as! AXUIElement
            target = children(of: bar).first
            return target != nil
        }),
        let item = target
    else {
        fail("status item was not reachable through AXExtrasMenuBar", .failed)
    }
    let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard status == .success else {
        fail(
            "status item press failed with AX status \(status.rawValue)",
            .failed
        )
    }

case "dump":
    requireAccessibilityTrust()
    _ = walk(application) { element, depth in
        let description = describe(element)
        if !description.isEmpty {
            print(String(repeating: " ", count: depth) + description)
        }
        return false
    }

default:
    fail("unknown --action \(arguments.action)", .usage)
}
