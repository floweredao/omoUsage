// Native account-settings QA. No production imports, live credentials, polling,
// or fixed delays. State transitions are observed through AXObserver before input.
import AppKit
import ApplicationServices
import Foundation

struct QAError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw QAError(message) }
}

struct Arguments {
    var action = ""
    var scenario = ""
    var phase = "exercise"
    var pid: pid_t = 0
    var root = ""
    var evidence = ""
    var timeout: TimeInterval = 20
    init() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let key = args.removeFirst()
            try require(!args.isEmpty, "missing value for \(key)")
            let value = args.removeFirst()
            switch key {
            case "--action": action = value
            case "--scenario": scenario = value
            case "--phase": phase = value
            case "--pid": pid = pid_t(value) ?? 0
            case "--fixture-root": root = value
            case "--evidence-dir": evidence = value
            case "--timeout": timeout = Double(value) ?? 0
            default: throw QAError("unknown argument \(key)")
            }
        }
        try require(timeout > 0 && timeout.isFinite, "invalid timeout")
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success
        ? result : nil
}
func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    var result = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    // AppKit can expose an NSPopover beneath its status item rather than
    // AXWindows. Include that live subtree when walking the application.
    if string(element, kAXRoleAttribute) == kAXApplicationRole,
       let bar = attribute(element, "AXExtrasMenuBar"),
       CFGetTypeID(bar) == AXUIElementGetTypeID() {
        let menuBar = bar as! AXUIElement
        if !result.contains(where: { CFEqual($0, menuBar) }) {
            result.append(menuBar)
        }
    }
    return result
}
func elements(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 50 else { return [] }
    return [root] + children(root).flatMap { elements($0, depth: depth + 1) }
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute),
          let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(),
          CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

/// One timer is a failure deadline, never a cadence. Predicates are evaluated
/// after subscribed AX events (and once after the trigger to cover synchronous
/// actions), not by a timer or a polling run-loop.
final class AXGate {
    let app: AXUIElement
    let timeout: TimeInterval
    private var observer: AXObserver!
    private var activationObserver: NSObjectProtocol?
    private var subscriptions: [(AXUIElement, String)] = []
    private var keys = Set<String>()
    private var predicate: (() throws -> Bool)?
    private var result: Result<Void, Error>?
    private(set) var revision = 0
    private var notifications = Set<String>()

    init(pid: pid_t, timeout: TimeInterval) throws {
        self.app = AXUIElementCreateApplication(pid)
        self.timeout = timeout
        let status = AXObserverCreate(pid, { _, _, notification, context in
            guard let context else { return }
            let gate = Unmanaged<AXGate>.fromOpaque(context).takeUnretainedValue()
            gate.revision += 1
            gate.notifications.insert(notification as String)
            gate.evaluate()
        }, &observer)
        try require(status == .success, "AXObserverCreate failed: \(status.rawValue)")
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let target = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  target.processIdentifier == pid else { return }
            self.notifications.insert("NSWorkspace.didActivateApplication")
            self.evaluate()
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        for (element, notification) in subscriptions {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func subscribe() throws {
        for element in elements(app) {
            let role = string(element, kAXRoleAttribute)
            var names = [kAXValueChangedNotification, kAXUIElementDestroyedNotification, kAXMovedNotification]
            if CFEqual(element, app) {
                names += [kAXApplicationActivatedNotification, kAXFocusedWindowChangedNotification,
                          kAXMainWindowChangedNotification]
            }
            if CFEqual(element, app) || role == kAXWindowRole || role == kAXScrollAreaRole {
                names += [kAXLayoutChangedNotification, kAXCreatedNotification,
                          kAXWindowCreatedNotification, kAXFocusedUIElementChangedNotification,
                          kAXMovedNotification, kAXResizedNotification,
                          kAXMenuOpenedNotification, kAXMenuClosedNotification]
            }
            for name in names {
                let key = "\(CFHash(element)):\(name)"
                guard keys.insert(key).inserted else { continue }
                let status = AXObserverAddNotification(
                    observer, element, name as CFString,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                if status == .success { subscriptions.append((element, name)) }
                else if status != .notificationUnsupported && status != .notImplemented
                    && status != .notificationAlreadyRegistered && status != .invalidUIElement {
                    throw QAError("AX subscription \(name) failed: \(status.rawValue)")
                }
            }
        }
        try require(!subscriptions.isEmpty, "target exposes no supported AX notifications")
    }

    private func evaluate() {
        guard let predicate, result == nil else { return }
        do {
            if try predicate() { result = .success(()); CFRunLoopStop(CFRunLoopGetCurrent()) }
        } catch {
            result = .failure(error)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    func wait(_ description: String, trigger: () throws -> Void = {},
              until predicate: @escaping () throws -> Bool) throws {
        try subscribe() // Must precede trigger, including mouse-down and key events.
        self.predicate = predicate
        self.result = nil
        notifications.removeAll()
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.result = .failure(QAError("timeout: \(description); AX events=\(self.notifications.sorted())"))
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        RunLoop.current.add(timer, forMode: .common)
        defer { timer.invalidate(); self.predicate = nil }
        try trigger()
        evaluate()
        if result == nil { CFRunLoopRun() }
        guard let result else { throw QAError("AX run loop stopped without result: \(description)") }
        try result.get()
    }
}

/// Bounded event trace for native ordering failures; observes without altering input.
final class MouseTrace {
    private var tap: CFMachPort!
    private var source: CFRunLoopSource!
    private var remaining = 12

    init() throws {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let trace = Unmanaged<MouseTrace>.fromOpaque(context).takeUnretainedValue()
                    if trace.remaining > 0 {
                        trace.remaining -= 1
                        let message = "MOUSE delivered type=\(type.rawValue) point=\(event.location) cursor=\(String(describing: CGEvent(source: nil)?.location)) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID)) targetPID=\(event.getIntegerValueField(.eventTargetUnixProcessID)) window=\(event.getIntegerValueField(.mouseEventWindowUnderMousePointer)) handlerWindow=\(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))\n"
                        FileHandle.standardOutput.write(Data(message.utf8))
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        try require(tap != nil, "cannot observe delivered ordering mouse events")
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }
}

final class Driver {
    let args: Arguments
    let gate: AXGate
    private var mouseHeld = false
    private var lastPoint = CGPoint.zero
    private var mouseTrace: MouseTrace?
    private let mouseSource: CGEventSource
    let root: URL
    let evidence: URL

    init(_ args: Arguments) throws {
        try require(args.pid > 0, "missing --pid")
        try require(AXIsProcessTrusted(), "Accessibility denied; grant terminal/automation host in System Settings > Privacy & Security > Accessibility")
        try require(CGPreflightScreenCaptureAccess(), "Screen Recording denied; grant terminal/automation host in System Settings > Privacy & Security > Screen Recording")
        try validateRoot(args.root)
        self.args = args
        guard let mouseSource = CGEventSource(stateID: .hidSystemState) else {
            throw QAError("cannot create ordering mouse event source")
        }
        self.mouseSource = mouseSource
        mouseSource.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateRemoteMouseDrag
        )
        root = URL(fileURLWithPath: args.root)
        evidence = URL(fileURLWithPath: args.evidence)
        gate = try AXGate(pid: args.pid, timeout: args.timeout)
        AXUIElementSetMessagingTimeout(gate.app, Float(args.timeout))
    }

    deinit { releaseMouse() }

    func find(_ id: String) -> AXUIElement? {
        elements(gate.app).first { string($0, kAXIdentifierAttribute) == id }
    }
    func get(_ id: String) throws -> AXUIElement {
        guard let element = find(id) else { throw QAError("missing AX identifier: \(id)") }
        return element
    }
    func value(_ id: String) throws -> String { string(try get(id), kAXValueAttribute) }
    func enabled(_ id: String) throws -> Bool {
        guard let flag = attribute(try get(id), kAXEnabledAttribute) as? Bool else {
            throw QAError("missing AXEnabled: \(id)")
        }
        return flag
    }
    func press(_ id: String) throws {
        let target = try get(id)
        try require(try enabled(id), "disabled control: \(id)")
        let status = AXUIElementPerformAction(target, kAXPressAction as CFString)
        try require(status == .success, "AXPress \(id): \(status.rawValue)")
    }
    func set(_ id: String, to value: String) throws {
        let target = try get(id)
        try require(AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                    "cannot focus \(id)")
        try gate.wait("\(id) value changed", trigger: {
            let status = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, value as CFString)
            try require(status == .success, "AXSetValue \(id): \(status.rawValue)")
        }, until: { try self.value(id) == value })
    }
    func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
                throw QAError("cannot construct key event")
            }
            event.flags = flags
            event.postToPid(args.pid)
        }
    }
    func mouse(_ type: CGEventType, at point: CGPoint) throws {
        guard let event = CGEvent(mouseEventSource: mouseSource, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else {
            throw QAError("cannot construct mouse event")
        }
        if type == .leftMouseDown { mouseHeld = true }
        if type == .leftMouseUp { mouseHeld = false }
        lastPoint = point
        event.post(tap: .cghidEventTap)
    }
    func releaseMouse() {
        if mouseHeld {
            CGEvent(mouseEventSource: mouseSource, mouseType: .leftMouseUp,
                    mouseCursorPosition: lastPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
            mouseHeld = false
        }
    }
    func click(_ id: String) throws {
        try reveal(id)
        guard let rect = frame(try get(id)) else { throw QAError("no frame: \(id)") }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        try mouse(.leftMouseDown, at: point)
        try mouse(.leftMouseUp, at: point)
    }

    func window() throws -> [String: Any] {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let accessibleWindows = elements(gate.app)
            .filter {
                let role = string($0, kAXRoleAttribute)
                return role == kAXWindowRole || role == "AXPopover"
            }
            .compactMap(frame)
        guard let target = entries.first(where: {
            guard ($0[kCGWindowOwnerPID as String] as? pid_t) == args.pid,
                  let bounds = $0[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.height > 100
            else { return false }
            // AppKit creates a full-screen drag-image window. Capture the real
            // accessible window beneath it, never that transparent overlay.
            return accessibleWindows.contains {
                abs($0.minX - rect.minX) < 2 && abs($0.minY - rect.minY) < 2
                    && abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2
            }
        }) else { throw QAError("no visible fixture window") }
        return target
    }

    func windowBounds() throws -> CGRect {
        guard let bounds = try window()[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else {
            throw QAError("missing window bounds")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    func ancestors(_ element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var node = element
        for _ in 0..<50 {
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = parent as! AXUIElement
            result.append(node)
        }
        return result
    }
    func isVisible(_ element: AXUIElement) throws -> Bool {
        guard let rect = frame(element), rect.width > 0, rect.height > 0 else { return false }
        var visible = try windowBounds()
        for parent in ancestors(element) where string(parent, kAXRoleAttribute) == kAXScrollAreaRole {
            if let bounds = frame(parent) { visible = visible.intersection(bounds) }
        }
        return visible.contains(rect)
    }
    func scrollLayout(_ scroll: AXUIElement) -> [String] {
        elements(scroll).map { "\(string($0, kAXIdentifierAttribute)):\(String(describing: frame($0)))" }
    }

    /// Bounded spatial exploration, not a time-based retry. Every scroll input
    /// awaits the scroll area's actual value/geometry transition. Unrelated AX
    /// events cannot satisfy this wait. Topmost-window bounds distinguish the
    /// dashboard popover from the settings window still open underneath it.
    func reveal(_ id: String) throws {
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == args.pid,
                    "fixture is not frontmost before revealing \(id)")
        for direction in [Int32(-1), Int32(1)] {
            for _ in 0..<30 {
                if let target = find(id), try isVisible(target) { return }
                let visible = try windowBounds()
                guard let scroll = elements(gate.app).first(where: {
                    guard string($0, kAXRoleAttribute) == kAXScrollAreaRole, let rect = frame($0) else { return false }
                    return visible.insetBy(dx: -1, dy: -1).contains(rect)
                }), let rect = frame(scroll) else { throw QAError("no visible scroll area while finding \(id)") }
                let bars = elements(scroll).filter {
                    string($0, kAXRoleAttribute) == kAXScrollBarRole
                        && string($0, kAXOrientationAttribute) == kAXVerticalOrientationValue
                }
                if let position = bars.first.flatMap({ attribute($0, kAXValueAttribute) as? Double }),
                   (direction > 0 && position <= 0) || (direction < 0 && position >= 1) { break }
                let before = bars.map { String(describing: attribute($0, kAXValueAttribute)) }
                let layout = scrollLayout(scroll)
                try gate.wait("scroll area changes while revealing \(id)", trigger: {
                    try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == self.args.pid,
                                "fixture lost foreground before scroll input")
                    let point = CGPoint(x: rect.midX, y: rect.midY)
                    var hit: AXUIElement?
                    let hitStatus = AXUIElementCopyElementAtPosition(
                        AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit
                    )
                    guard hitStatus == .success, let hit else { throw QAError("scroll hit-test failed") }
                    try require(([hit] + self.ancestors(hit)).contains { CFEqual($0, scroll) },
                                "scroll center is covered by another window or outside the target scroll area")
                    try require(CGWarpMouseCursorPosition(point) == .success, "cannot position scroll cursor")
                    guard let event = CGEvent(scrollWheelEvent2Source: self.mouseSource, units: .pixel,
                                              wheelCount: 1, wheel1: direction * 240, wheel2: 0, wheel3: 0) else {
                        throw QAError("cannot construct scroll event")
                    }
                    event.location = point
                    print("SCROLL fixturePID=\(self.args.pid) point=\(point) direction=\(direction) targetHit=verified")
                    event.post(tap: .cghidEventTap)
                }, until: {
                    bars.map { String(describing: attribute($0, kAXValueAttribute)) } != before || self.scrollLayout(scroll) != layout
                })
            }
        }
        throw QAError("could not reveal AX identifier \(id)")
    }

    func screenshot(_ name: String) throws {
        let entry = try window()
        guard let id = entry[kCGWindowNumber as String] as? Int else { throw QAError("missing CGWindowID") }
        let output = evidence.appendingPathComponent("\(args.phase)-\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(id)", output.path]
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "screencapture failed: \(name)")
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        try require((attributes[.size] as? Int ?? 0) > 0, "empty screenshot: \(name)")
        print("SCREENSHOT \(output.lastPathComponent)")
    }
    func dump(_ name: String) throws {
        let text = elements(gate.app).map { element in
            [kAXIdentifierAttribute, kAXRoleAttribute, kAXTitleAttribute,
             kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .map { "\($0)=\(String(describing: attribute(element, $0)))" }.joined(separator: " ")
        }.joined(separator: "\n")
        try text.write(to: evidence.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func pass(_ name: String) { print("PASS \(name)") }
}

let primary = "00000000-0000-0000-0000-000000000001"
let secondary = "00000000-0000-0000-0000-000000000002"

func validateRoot(_ path: String) throws {
    try require(path.hasPrefix("/tmp/omousage-companion-qa-") && !path.contains(".."), "fixture root must be an isolated /tmp/omousage-companion-qa-* directory")
    let url = URL(fileURLWithPath: path)
    try require(url.deletingLastPathComponent().path == "/tmp", "fixture root must be a direct child of /tmp")
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    try require(values.isDirectory == true && values.isSymbolicLink != true, "fixture root is not a real directory")
}

func preflight() throws {
    let ax = AXIsProcessTrusted()
    let screen = CGPreflightScreenCaptureAccess()
    print("accessibility=\(ax)")
    print("screenCapture=\(screen)")
    try require(ax && screen, "grant Accessibility and Screen Recording to the terminal/automation host before running native QA")
}

extension Driver {
    func accountID(_ prefix: String, _ provider: String = "codex", _ account: String = primary) -> String {
        "\(prefix)-\(provider)-\(account)"
    }
    func text(_ id: String) throws -> String {
        let element = try get(id)
        return [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .map { string(element, $0) }
            .first { !$0.isEmpty } ?? ""
    }
    func changed(_ description: String, pressing id: String,
                 until condition: @escaping () throws -> Bool) throws {
        try reveal(id)
        try gate.wait(description, trigger: { try self.press(id) }, until: condition)
    }
    func assertRole(_ provider: String, _ account: String, primary isPrimary: Bool) throws {
        let role = accountID(isPrimary ? "account-role-primary" : "account-role-additional", provider, account)
        try reveal(role)
        try require(find(accountID("account-row", provider, account)) != nil, "role has no account row")
        try require(!(try text(role)).isEmpty, "account role is visually empty")
        try require(find(accountID(isPrimary ? "account-role-additional" : "account-role-primary", provider, account)) == nil,
                    "conflicting account role")
        try require(find(accountID("remove-account", provider, account)) == nil || !isPrimary,
                    "primary account incorrectly offers remove-account")
        pass("explicit-\(isPrimary ? "primary" : "additional")-role-\(provider)-\(account)")
    }
    func registry() throws -> [String: Any] { try json(root.appendingPathComponent("accounts.json")) }
    func savedOrder() throws -> [String] {
        guard let rows = try registry()["displayOrder"] as? [[String: String]] else { throw QAError("missing registry displayOrder") }
        return try rows.map {
            guard let provider = $0["providerID"], let account = $0["accountID"] else { throw QAError("malformed registry order identity") }
            return "\(provider)-\(account)"
        }
    }
    func savedAlias(_ account: String) throws -> String {
        guard let accounts = try registry()["accounts"] as? [[String: Any]],
              let row = accounts.first(where: { $0["id"] as? String == account }) else { throw QAError("missing registry account") }
        if let labels = row["providerLabels"] as? [String: String], let label = labels["codex"] { return label }
        guard let label = row["label"] as? String else { throw QAError("missing registry label") }
        return label
    }
    func isSavedDisconnected(_ provider: String, _ account: String = primary) throws -> Bool {
        guard let identities = try registry()["disconnected"] as? [[String: String]] else { throw QAError("missing registry disconnected state") }
        return identities.contains { $0["providerID"] == provider && $0["accountID"] == account }
    }

    func runScenario() throws {
        try require(["exercise", "verify"].contains(args.phase), "invalid phase")
        try require(try json(root.appendingPathComponent("account-settings-ready.json"))["version"] as? Int == 1,
                    "fixture is not ready")
        try gate.wait("native settings window", until: {
            elements(self.gate.app).contains { string($0, kAXRoleAttribute) == kAXScrollAreaRole }
        })
        if args.scenario == "connections" {
            try dump("\(args.phase)-connection-contract-ax-tree.txt")
            try require(find("disconnect-codex") == nil,
                        "provider aggregate Disconnect remains: codex")
            try require(find(accountID("account-connection-status")) != nil,
                        "primary account has no connection status")
        }
        guard let settings = elements(gate.app).first(where: {
            string($0, kAXRoleAttribute) == kAXWindowRole
                && elements($0).contains { string($0, kAXRoleAttribute) == kAXScrollAreaRole }
        }) else { throw QAError("missing native settings window") }
        // Activation is asynchronous. An existing AX tree is not evidence that
        // the window receives HID input. Subscribe before activation and raise.
        try gate.wait("fixture foreground and focused settings window", trigger: {
            let activation = AXUIElementSetAttributeValue(
                self.gate.app, kAXFrontmostAttribute as CFString, kCFBooleanTrue
            )
            try require(activation == .success, "cannot activate fixture through AX: \(activation.rawValue)")
            let status = AXUIElementPerformAction(settings, kAXRaiseAction as CFString)
            try require(status == .success, "cannot raise settings window: \(status.rawValue)")
        }, until: {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == self.args.pid,
                  attribute(self.gate.app, kAXFrontmostAttribute) as? Bool == true,
                  let focused = attribute(self.gate.app, kAXFocusedWindowAttribute) else { return false }
            return CFEqual(focused, settings)
        })
        pass("fixture-foreground-and-settings-focused")
        switch args.scenario {
        case "ordering":
            mouseTrace = try MouseTrace()
            try ordering()
        case "tiers": try tiers()
        case "gating": try gating()
        case "accounts": try accounts()
        case "aliases": try aliases()
        case "identity": try identity()
        case "polish": try polish()
        case "connections": try connections()
        default: throw QAError("unknown scenario \(args.scenario)")
        }
        pass("scenario=\(args.scenario) phase=\(args.phase)")
    }

    func orderingRow(_ provider: String, _ account: String) -> String {
        "provider-ordering-row.\(account)|\(provider)"
    }
    func orderingHandle(_ provider: String, _ account: String) -> String {
        "provider-ordering-handle.\(account)|\(provider)"
    }
    func visibleOrder() throws -> [String] {
        let prefix = "provider-ordering-row."
        let rows = try elements(gate.app).filter { string($0, kAXIdentifierAttribute).hasPrefix(prefix) }.map { row in
            let payload = String(string(row, kAXIdentifierAttribute).dropFirst(prefix.count)).split(separator: "|")
            guard payload.count == 2, let rect = frame(row) else { throw QAError("malformed ordering row AX contract") }
            return (rect.minY, "\(payload[1])-\(payload[0])")
        }
        return rows.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
    func dragPreview(source: String, target: String, expected: [String]) throws {
        try reveal(source)
        try reveal(target)
        guard let from = frame(try get(source)), let to = frame(try get(target)) else {
            throw QAError("ordering source/target frame missing")
        }
        let origin = CGPoint(x: from.midX, y: from.midY)
        let destination = CGPoint(x: to.midX, y: to.midY)
        print("DRAG fixturePID=\(args.pid) frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == args.pid,
                    "fixture lost foreground before drag")
        for (name, id, rect, point) in [("source", source, from, origin), ("target", target, to, destination)] {
            var hit: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(
                AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit
            )
            let hitDescription = hit.map {
                "id=\(string($0, kAXIdentifierAttribute)) role=\(string($0, kAXRoleAttribute)) frame=\(String(describing: frame($0))) ancestors=\(ancestors($0).map { string($0, kAXIdentifierAttribute) })"
            } ?? "nil"
            print("DRAG \(name) id=\(id) frame=\(rect) point=\(point) hitStatus=\(status.rawValue) hit=\(hitDescription) window=\(try windowBounds())")
            guard status == .success, let hit else { throw QAError("drag \(name) hit-test failed") }
            try require(([hit] + ancestors(hit)).contains { string($0, kAXIdentifierAttribute) == id },
                        "drag \(name) center does not hit the expected AX element")
        }
        try gate.wait("native dragging source session began", trigger: {
            try self.mouse(.leftMouseDown, at: origin)
            try self.mouse(.leftMouseDragged, at: CGPoint(x: origin.x + 5, y: origin.y))
        }, until: { attribute(try self.get(source), kAXSelectedAttribute) as? Bool == true })
        print("PASS native-drag-source-began")
        try gate.wait("live visual order BEFORE mouse release", trigger: {
            try self.mouse(.leftMouseDragged, at: destination)
        }, until: { try self.visibleOrder() == expected })
        try require(mouseHeld && CGEventSource.buttonState(.combinedSessionState, button: .left),
                    "live-order assertion did not occur while physical mouse button was held")
        pass("live-visual-order-changed-before-mouse-release")
    }
    func ordering() throws {
        try reveal("provider-ordering-list")
        let expectedURL = root.appendingPathComponent("expected-order.json")
        if args.phase == "verify" {
            guard let expected = try json(expectedURL)["order"] as? [String] else { throw QAError("missing expected committed order") }
            try require(try savedOrder() == expected && visibleOrder() == expected, "final ordering did not survive relaunch")
            try screenshot("persisted-order-after-relaunch")
            pass("final-drag-and-keyboard-order-persisted")
            return
        }
        let original = try savedOrder()
        try require(original.count == 4 && (try visibleOrder()) == original, "fixture order not fully visible before drag")
        let first = "codex-\(primary)"
        let second = "codex-\(secondary)"
        try require(Array(original.prefix(2)) == [first, second], "unexpected fixture ordering seed")
        var moved = original
        moved.swapAt(0, 1)
        try screenshot("order-before-drag")
        try dragPreview(source: orderingHandle("codex", primary), target: orderingRow("codex", secondary), expected: moved)
        try require(try savedOrder() == original, "hover persisted order before release")
        try screenshot("live-order-mouse-still-held")
        try gate.wait("drop commits preview", trigger: {
            try self.mouse(.leftMouseUp, at: self.lastPoint)
        }, until: { try self.savedOrder() == moved && self.visibleOrder() == moved })
        pass("released-drag-commits-final-order")
        try screenshot("committed-drop")

        try dragPreview(source: orderingHandle("codex", primary), target: orderingRow("codex", secondary), expected: original)
        try require(try savedOrder() == moved, "second hover persisted before cancellation")
        try screenshot("cancel-preview-mouse-held")
        try gate.wait("Escape rolls back preview without persisting", trigger: { try self.key(53) }, until: {
            try self.visibleOrder() == moved && self.savedOrder() == moved
        })
        releaseMouse()
        try screenshot("cancel-restores-saved-order")
        pass("escape-cancel-preserves-saved-order")

        let row = orderingRow("codex", primary)
        try reveal(row)
        try require(AXUIElementSetAttributeValue(try get(row), kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                    "ordering row cannot receive keyboard focus")
        var keyboardOrder = moved
        keyboardOrder.swapAt(1, 2)
        try gate.wait("Command-Down keyboard reorder", trigger: { try self.key(125, flags: .maskCommand) }, until: {
            try self.savedOrder() == keyboardOrder && self.visibleOrder() == keyboardOrder
        })
        try writeJSON(["order": keyboardOrder], expectedURL)
        try screenshot("keyboard-order")
        pass("existing-keyboard-reorder-works")
    }

    func assertConnection(_ account: String, connected: Bool) throws {
        let status = accountID("account-connection-status", "codex", account)
        let action = accountID(connected ? "account-disconnect" : "account-reconnect", "codex", account)
        try reveal(status)
        try require(try text(status) == (connected ? "Connected" : "Not Connected"),
                    "incorrect account connection status: \(account)")
        try require(try enabled(action), "account connection action disabled: \(account)")
        for prefix in [connected ? "account-reconnect" : "account-disconnect", "account-connect", "account-retry-connection"] {
            try require(find(accountID(prefix, "codex", account)) == nil,
                        "conflicting account connection action: \(prefix)-\(account)")
        }
        let rowID = accountID("account-row", "codex", account)
        guard let rowBounds = frame(try get(rowID)) else { throw QAError("account row bounds missing") }
        for id in [status, action] {
            let element = try get(id)
            try require(ancestors(element).contains { string($0, kAXIdentifierAttribute) == rowID },
                        "connection control not grouped in its account row: \(id)")
            guard let bounds = frame(element) else { throw QAError("connection control bounds missing: \(id)") }
            try require(rowBounds.insetBy(dx: -1, dy: -1).contains(bounds) && isVisible(element),
                        "connection status/action clipped or outside its account row: \(id)")
            print("BOUNDS \(id)=\(bounds) row=\(rowBounds) window=\(try windowBounds())")
        }
        pass("independent-connection-\(account)-\(connected ? "connected" : "disconnected")")
    }

    func assertConnectionRegistry(disconnected accounts: [String]) throws {
        guard let identities = try registry()["disconnected"] as? [[String: String]] else {
            throw QAError("missing disconnected registry state")
        }
        try require(identities.count == accounts.count && accounts.allSatisfy { account in
            identities.contains { $0["providerID"] == "codex" && $0["accountID"] == account }
        }, "connection action changed a sibling or another provider's persisted state")
    }

    func assertConnectionOrder(disconnected accounts: [String], screenshot name: String) throws {
        try reveal("provider-ordering-list")
        let expected = ["codex-\(primary)", "codex-\(secondary)", "openrouter-\(primary)", "claude-\(primary)"]
        let visible = expected.filter { identity in
            !accounts.contains { identity == "codex-\($0)" }
        }
        try require(try savedOrder() == expected && visibleOrder() == visible,
                    "ordering must hide disconnected accounts without changing stored order")
        for account in [primary, secondary] {
            let id = orderingRow("codex", account)
            if accounts.contains(account) {
                try require(find(id) == nil, "disconnected account remains in Dashboard Order")
                continue
            }
            try reveal(id)
            let labels = elements(try get(id)).flatMap { element in
                [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].map { string(element, $0) }
            }
            try require(labels.contains("Connected") && !labels.contains("Hidden from dashboard"),
                        "ordering connection status incorrect for \(account): expected Connected")
        }
        try screenshot(name)
        pass("account-scoped-order-visibility-\(name)")
    }

    func captureConnections(_ name: String, primaryConnected: Bool, secondaryConnected: Bool) throws {
        try assertConnection(primary, connected: primaryConnected)
        try assertConnection(secondary, connected: secondaryConnected)
        for account in [primary, secondary] {
            try require(try isVisible(get(accountID("account-connection-status", "codex", account))),
                        "both account statuses must be visible in grouped-row evidence")
        }
        try screenshot(name)
    }

    func connections() throws {
        // Existing identifiers work on the RED build. Capture its current rows
        // BEFORE looking for any new status or account-level control contract.
        try reveal(accountID("account-role-primary"))
        try screenshot("connections-baseline-before-contract")
        try dump("\(args.phase)-connections-baseline-ax-tree.txt")
        for provider in ["codex", "openrouter", "claude"] {
            try require(find("disconnect-\(provider)") == nil,
                        "provider aggregate Disconnect remains: \(provider)")
        }
        if args.phase == "verify" {
            try assertConnectionRegistry(disconnected: [primary])
            try captureConnections("connections-persisted-grouped-rows", primaryConnected: false, secondaryConnected: true)
            try require(find("begin-add-account-codex") == nil, "disconnected primary regained Add Account after relaunch")
            try assertConnectionOrder(disconnected: [primary], screenshot: "connections-persisted-order")
            pass("primary-disconnect-persists-with-connected-sibling")
            guard let settings = elements(gate.app).first(where: {
                string($0, kAXRoleAttribute) == kAXWindowRole
            }) else { throw QAError("missing settings window for minimum-width check") }
            var size = CGSize(width: 440, height: 652)
            guard let value = AXValueCreate(.cgSize, &size) else {
                throw QAError("cannot construct minimum window size")
            }
            try gate.wait("settings reaches minimum width", trigger: {
                try require(
                    AXUIElementSetAttributeValue(settings, kAXSizeAttribute as CFString, value) == .success,
                    "cannot resize native settings"
                )
            }, until: { frame(settings)?.width == 440 })
            try captureConnections("connections-minimum-width", primaryConnected: false, secondaryConnected: true)
            pass("minimum-width-account-groups")
            return
        }
        try assertConnectionRegistry(disconnected: [])
        try captureConnections("connections-initial-grouped-rows", primaryConnected: true, secondaryConnected: true)
        try require(try enabled("begin-add-account-codex"), "connected primary lacks enabled Add Account")
        try assertConnectionOrder(disconnected: [], screenshot: "connections-initial-order")

        try changed("disconnect only additional Codex", pressing: accountID("account-disconnect", "codex", secondary), until: {
            try self.find(self.accountID("account-reconnect", "codex", secondary)) != nil
                && self.text(self.accountID("account-connection-status", "codex", secondary)) == "Not Connected"
                && self.isSavedDisconnected("codex", secondary)
        })
        try assertConnectionRegistry(disconnected: [secondary])
        try captureConnections("connections-additional-disconnected", primaryConnected: true, secondaryConnected: false)
        try require(try enabled("begin-add-account-codex"), "additional disconnect gated connected primary Add Account")
        try assertConnectionOrder(disconnected: [secondary], screenshot: "connections-additional-hidden-order")

        try changed("reconnect only additional Codex", pressing: accountID("account-reconnect", "codex", secondary), until: {
            try self.find(self.accountID("account-disconnect", "codex", secondary)) != nil
                && self.text(self.accountID("account-connection-status", "codex", secondary)) == "Connected"
                && !self.isSavedDisconnected("codex", secondary)
        })
        try assertConnectionRegistry(disconnected: [])
        try captureConnections("connections-additional-restored", primaryConnected: true, secondaryConnected: true)
        try assertConnectionOrder(disconnected: [], screenshot: "connections-restored-order")

        // Leave exactly this state on disk for the shell's real app relaunch.
        try changed("disconnect only primary Codex", pressing: accountID("account-disconnect"), until: {
            try self.find(self.accountID("account-reconnect")) != nil
                && self.text(self.accountID("account-connection-status")) == "Not Connected"
                && self.isSavedDisconnected("codex") && self.find("begin-add-account-codex") == nil
        })
        try assertConnectionRegistry(disconnected: [primary])
        try captureConnections("connections-final-grouped-rows", primaryConnected: false, secondaryConnected: true)
        try require(find("begin-add-account-codex") == nil, "connected sibling incorrectly exposes primary Add Account")
        try assertConnectionOrder(disconnected: [primary], screenshot: "connections-final-order")
    }

    func accounts() throws {
        try assertRole("codex", primary, primary: true)
        try assertRole("codex", secondary, primary: false)
        try reveal(accountID("account-role-primary"))
        try screenshot("codex-primary-and-additional-roles")
        try assertRole("openrouter", primary, primary: true)
        try require(!elements(gate.app).contains { string($0, kAXIdentifierAttribute).hasPrefix("account-role-additional-openrouter-") },
                    "single-account provider has an additional-account role")
        try screenshot("single-primary-role")
        if args.phase == "exercise" {
            try changed("disconnect primary", pressing: accountID("account-disconnect"), until: {
                try self.find(self.accountID("account-reconnect")) != nil && self.isSavedDisconnected("codex")
            })
        } else { try require(try isSavedDisconnected("codex"), "disconnected primary did not persist") }
        try assertRole("codex", primary, primary: true)
        try screenshot("disconnected-primary-role")
    }

    func rename(_ account: String, to alias: String) throws {
        let field = accountID("alias-field", "codex", account)
        let saved = accountID("account-name", "codex", account)
        try changed("alias editor opens", pressing: accountID("edit-alias", "codex", account), until: { self.find(field) != nil })
        try reveal(field)
        try set(field, to: alias)
        try changed("alias committed to UI and registry", pressing: accountID("save-alias", "codex", account), until: {
            try self.find(field) == nil && self.text(saved) == alias && self.savedAlias(account) == alias
        })
        pass("alias-committed-\(account)")
    }
    func aliases() throws {
        let desired = [(primary, "QA Primary"), (secondary, "QA Work")]
        if args.phase == "exercise" {
            for (account, name) in desired { try rename(account, to: name) }
            let field = accountID("alias-field")
            try changed("blank edit opens", pressing: accountID("edit-alias"), until: { self.find(field) != nil })
            try set(field, to: "   ")
            try require(try !enabled(accountID("save-alias")), "blank alias Save must be disabled")
            try require(try savedAlias(primary) == "QA Primary", "blank draft replaced persisted alias")
            try screenshot("blank-alias-rejected")
            try changed("blank alias cancelled", pressing: accountID("cancel-alias"), until: { self.find(field) == nil })
            pass("blank-edit-cannot-replace-saved-alias")
        }
        for (account, name) in desired {
            let id = accountID("account-name", "codex", account)
            try reveal(id)
            try require(try text(id) == name && savedAlias(account) == name, "alias did not persist for \(account)")
            try require(find(accountID("edit-alias", "codex", account)) != nil, "saved alias no longer editable")
            try screenshot("alias-\(account)")
        }
        pass("both-account-aliases-persisted")
    }

    func menuOption(_ title: String) -> AXUIElement? {
        elements(gate.app).first {
            string($0, kAXRoleAttribute) == kAXMenuItemRole && string($0, kAXTitleAttribute) == title
        }
    }
    func chooseTier(_ account: String, _ title: String) throws {
        let id = "codex-tier-\(account)"
        try changed("tier menu opens", pressing: id, until: { self.menuOption(title) != nil })
        try gate.wait("account tier selection", trigger: {
            guard let option = self.menuOption(title) else { throw QAError("missing tier menu option: \(title)") }
            try require(AXUIElementPerformAction(option, kAXPressAction as CFString) == .success, "tier menu selection failed")
        }, until: { try self.value(id) == title })
    }
    func tiers() throws {
        let main = "codex-tier-\(primary)"
        let extra = "codex-tier-\(secondary)"
        try reveal(main)
        if args.phase == "exercise" {
            try require(try value(main) == "Pro 20x", "primary legacy tier preference was not preserved")
            try reveal(extra)
            try require(try value(extra) == "Automatic", "new account inherited primary tier")
            try chooseTier(primary, "Pro 5x")
            try chooseTier(secondary, "Pro 20x")
            try chooseTier(primary, "Automatic")
            try reveal(extra)
            try require(try value(extra) == "Pro 20x", "changing primary tier changed added-account tier")
            try chooseTier(primary, "Pro 5x")
            pass("independent-tier-changes-and-automatic-default")
        }
        try reveal(main)
        try require(try value(main) == "Pro 5x", "primary tier did not persist")
        try screenshot("primary-tier")
        try reveal(extra)
        try require(try value(extra) == "Pro 20x", "additional tier did not persist")
        try screenshot("additional-tier")
        try dashboardPlans()
    }

    func dashboardPlans() throws {
        guard let barValue = attribute(gate.app, "AXExtrasMenuBar"), CFGetTypeID(barValue) == AXUIElementGetTypeID(),
              let item = children(barValue as! AXUIElement).first else { throw QAError("status item missing") }
        let mainID = "dashboard-provider-codex-Default Account"
        let extraID = "dashboard-provider-codex-Work"
        try gate.wait("dashboard primary provider", trigger: {
            try require(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success, "status item press failed")
        }, until: { self.find(mainID) != nil })
        for (id, plan) in [(mainID, "Pro 5x"), (extraID, "Pro 20x")] {
            try reveal(id)
            try gate.wait("actual account provider plan \(plan)", until: {
                guard let element = self.find(id) else { return false }
                return elements(element).contains { child in
                    [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains { key in
                        string(child, key) == plan
                    }
                }
            })
            try screenshot("dashboard-\(plan.replacingOccurrences(of: " ", with: "-"))")
        }
        pass("real-provider-plans-reflect-independent-tiers")
    }

    func polish() throws {
        try screenshot("settings-sections")
        guard let bar = attribute(gate.app, "AXExtrasMenuBar"),
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let item = children(bar as! AXUIElement).first else {
            throw QAError("status item missing")
        }
        func openDashboard(until predicate: @escaping () throws -> Bool) throws {
            try gate.wait("dashboard presentation", trigger: {
                try require(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success,
                            "status item press failed")
            }, until: predicate)
        }
        if args.phase == "exercise" {
            let alias = "개발팀 장기 프로젝트 계정 Work Production"
            try rename(secondary, to: alias)
            let provider = "dashboard-provider-codex-\(alias)"
            try openDashboard { self.find(provider) != nil }
            try reveal(provider)
            try screenshot("multi-account-popover")
            try gate.wait("close dashboard", trigger: { try self.key(53) },
                          until: { self.find(provider) == nil })
            let identities = try registry()["displayOrder"] as? [[String: String]] ?? []
            try require(!identities.isEmpty, "fixture has no account identities")
            for identity in identities {
                guard let provider = identity["providerID"], let account = identity["accountID"] else {
                    throw QAError("malformed fixture identity")
                }
                let disconnect = accountID("account-disconnect", provider, account)
                try changed("disconnect fixture account", pressing: disconnect, until: {
                    try self.isSavedDisconnected(provider, account)
                })
            }
        }
        try openDashboard { self.find("dashboard-open-settings") != nil }
        try require(try isVisible(get("dashboard-open-settings")), "empty-state action is clipped")
        try screenshot("empty-popover")
        try gate.wait("empty-state settings action", trigger: {
            try self.press("dashboard-open-settings")
        }, until: { self.find("dashboard-open-settings") == nil })
        try require(elements(gate.app).contains { string($0, kAXRoleAttribute) == kAXScrollAreaRole },
                    "settings action did not expose settings")
        pass("empty-state-settings-action-and-relaunch")
    }

    func gating() throws {
        if args.phase == "verify" {
            // This state is preseeded while the app is stopped. Header
            // Disconnect can disconnect every sibling and miss this regression.
            try reveal(accountID("account-role-primary"))
            let disconnected = try registry()["disconnected"] as? [[String: String]]
            try require(disconnected == [["providerID": "codex", "accountID": primary]],
                        "regression fixture must disconnect ONLY primary Codex")
            try require(find("begin-add-account-codex") == nil, "available sibling incorrectly enables primary Add Account")
            try reveal("codex-tier-\(secondary)")
            try require(try enabled("codex-tier-\(secondary)") && value("codex-tier-\(secondary)") == "Automatic",
                        "connected additional account lost independent tier")
            try screenshot("primary-disconnected-extra-tier-intact")
            guard let bar = attribute(gate.app, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
                  let item = children(bar as! AXUIElement).first else { throw QAError("status item missing") }
            let extraID = "dashboard-provider-codex-Work"
            try gate.wait("additional Codex still connected", trigger: {
                try require(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success, "status item press failed")
            }, until: { self.find(extraID) != nil })
            try reveal(extraID)
            try require(elements(try get(extraID)).contains { child in
                [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains { string(child, $0) == "Pro" }
            }, "additional account lacks connected provider usage")
            try screenshot("disconnected-primary-connected-extra-dashboard")
            pass("only-primary-disconnected-gates-add-account-with-connected-sibling")
            return
        }
        let before = try registry()["accounts"] as? [[String: Any]]
        try reveal("begin-add-account-codex")
        try require(try enabled("begin-add-account-codex"), "connected primary Add Account disabled")
        try screenshot("connected-add-account-visible")
        try changed("addition form opens", pressing: "begin-add-account-codex", until: { self.find("account-alias-codex") != nil })
        try set("account-alias-codex", to: "QA Pending")
        try changed("pending companion addition", pressing: "add-account-codex", until: { self.find("account-waiting-codex") != nil })
        try reveal("check-again-codex")
        try require(try enabled("check-again-codex") && enabled("cancel-addition-codex"), "pending completion/cancel controls unreachable")
        try require(find("begin-add-account-codex") == nil, "pending addition exposes duplicate Add Account")
        // Check Again is synchronous for the unchanged fixture credential; its
        // postcondition is checked after the actual AX action, not a delay.
        try gate.wait("unchanged credential remains pending", trigger: { try self.press("check-again-codex") }, until: {
            try self.find("account-waiting-codex") != nil && self.enabled("cancel-addition-codex")
        })
        try screenshot("pending-controls-reachable")
        try changed("cancel returns to connected account form", pressing: "cancel-addition-codex", until: {
            self.find("account-waiting-codex") == nil && self.find("add-account-codex") != nil
        })
        try changed("close form restores connected Add Account", pressing: "close-add-account-codex", until: {
            self.find("begin-add-account-codex") != nil
        })
        let after = try registry()["accounts"] as? [[String: Any]]
        try require(NSDictionary(dictionary: ["accounts": before ?? []]).isEqual(to: ["accounts": after ?? []]), "cancel persisted an account")
        pass("pending-check-and-cancel-remain-reachable")
        try changed("primary account disconnect gates Add Account", pressing: accountID("account-disconnect"), until: {
            try self.find(self.accountID("account-reconnect")) != nil
                && self.isSavedDisconnected("codex") && self.find("begin-add-account-codex") == nil
        })
        try assertConnectionRegistry(disconnected: [primary])
        pass("primary-account-disconnect-gates-add-account")
    }

    func identity() throws {
        for account in [primary, secondary] {
            let id = accountID("account-identity", "codex", account)
            try reveal(id)
            let expected = account == primary ? "p***y@e***e.com" : "s***y@e***e.com"
            // SwiftUI exposes the localized accessibility label as AXValue,
            // including its role prefix, rather than as AXDescription.
            let identityToken = try text(id).split(whereSeparator: \.isWhitespace).last
            try require(identityToken == Substring(expected), "masked fixture identity does not match the reliable account")
            try assertNoRawIdentity()
            try screenshot("masked-identity-\(account)")
        }
        for provider in ["openrouter", "claude"] {
            try reveal(accountID("account-name", provider))
            try require(find(accountID("account-identity", provider)) == nil, "missing/invalid \(provider) identity was fabricated")
            try assertNoRawIdentity()
            try screenshot("absent-identity-\(provider)")
        }
        pass("masked-reliable-identities-and-absent-invalid-identities")
    }
    func assertNoRawIdentity() throws {
        let forbidden = ["primary@example.com", "secondary@example.com", "invalid-fixture-identity"]
        for element in elements(gate.app) {
            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
                let value = String(describing: attribute(element, key))
                try require(!forbidden.contains(where: value.contains), "raw fixture identity exposed through \(key)")
            }
        }
        let registryText = try String(contentsOf: root.appendingPathComponent("accounts.json"), encoding: .utf8)
        try require(!forbidden.contains(where: registryText.contains), "raw identity leaked into account registry")
    }
}

func json(_ url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw QAError("expected JSON object in \(url.lastPathComponent)")
    }
    return object
}
func writeJSON(_ object: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func seed(_ args: Arguments) throws {
    try validateRoot(args.root)
    let root = URL(fileURLWithPath: args.root)
    try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("accounts.json").path), "refusing to overwrite an existing fixture")
    let refs = [("codex", primary), ("codex", secondary), ("openrouter", primary), ("claude", primary)].map {
        ["providerID": $0.0, "accountID": $0.1]
    }
    try writeJSON([
        "version": 3, "migrationVersion": 1,
        "accounts": [["id": primary, "label": "Default Account"], ["id": secondary, "label": "Work"]],
        "displayOrder": refs, "providerReferences": refs, "disconnected": []
    ], root.appendingPathComponent("accounts.json"))
    let keychain = root.appendingPathComponent("keychain")
    try FileManager.default.createDirectory(at: keychain, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    for (provider, account, token, email) in [
        ("codex", primary, "qa-codex-token-a", "primary@example.com"),
        ("codex", secondary, "qa-codex-token-b", "secondary@example.com"),
        ("claude", primary, "qa-claude-token", "invalid-fixture-identity")
    ] {
        let item = "com.omo.usage.provider-api-keys.v1|\(provider)/\(account)"
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ".", with: "_")
        try writeJSON(["version": 1, "provider": provider, "accessToken": token,
                       "accountReference": token, "source": "file", "email": email,
                       "planName": "Pro"], keychain.appendingPathComponent(item))
    }
    try Data("qa-codex-token-a".utf8).write(to: root.appendingPathComponent("credential-codex.token"))
    let suite = "CompanionAccountQA-\(root.lastPathComponent)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw QAError("cannot create fixture defaults") }
    defaults.set("english", forKey: "OmoUsage.appLanguage")
    defaults.set(true, forKey: "OmoUsage.appLanguageExplicitlySelected")
    defaults.set(["codex", "openrouter", "claude", "cursor", "antigravity", "copilot", "devin", "grok", "opencode", "zai"], forKey: "providerDisplayOrder")
    defaults.set("20x", forKey: "codexPlanMultiplier")
    try require(defaults.synchronize(), "fixture defaults did not synchronize")
    print("PASS seed-isolated-registry-and-secret-snapshots")
}

func awaitReady(_ args: Arguments) throws {
    try validateRoot(args.root)
    let root = URL(fileURLWithPath: args.root)
    let ready = root.appendingPathComponent("account-settings-ready.json")
    let fd = open(root.path, O_EVTONLY)
    try require(fd >= 0, "cannot watch fixture directory")
    let signal = DispatchSemaphore(value: 0)
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .global())
    source.setEventHandler {
        if FileManager.default.fileExists(atPath: ready.path) { signal.signal() }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    defer { source.cancel() }
    if !FileManager.default.fileExists(atPath: ready.path) {
        try require(signal.wait(timeout: .now() + args.timeout) == .success, "fixture readiness receipt missing; --app-path must be an integrated --qa-fixtures build")
    }
    try require(try json(ready)["version"] as? Int == 1, "unsupported fixture readiness contract")
    print("PASS fixture-ready-v1")
}

func terminate(_ args: Arguments) throws {
    try require(args.pid > 1, "invalid owned PID")
    let signal = DispatchSemaphore(value: 0)
    let source = DispatchSource.makeProcessSource(identifier: args.pid, eventMask: .exit, queue: .global())
    source.setEventHandler { signal.signal() }
    source.resume() // Subscribe to this exact child's exit before sending TERM.
    defer { source.cancel() }
    if kill(args.pid, SIGTERM) == -1 {
        try require(errno == ESRCH, "cannot terminate owned PID \(args.pid): \(errno)")
        return
    }
    if signal.wait(timeout: .now() + args.timeout) != .success {
        let status = kill(args.pid, SIGKILL)
        try require(status == 0 || errno == ESRCH, "cannot kill owned PID \(args.pid)")
        throw QAError("owned PID \(args.pid) required SIGKILL after graceful-exit deadline")
    }
    print("PASS owned-process-exit pid=\(args.pid)")
}

func main() throws {
    let args = try Arguments()
    switch args.action {
    case "preflight": try preflight()
    case "seed": try seed(args)
    case "seed-primary-disconnected":
        try validateRoot(args.root)
        let root = URL(fileURLWithPath: args.root)
        var registry = try json(root.appendingPathComponent("accounts.json"))
        registry["disconnected"] = [["providerID": "codex", "accountID": primary]]
        try writeJSON(registry, root.appendingPathComponent("accounts.json"))
        try writeJSON(registry, root.appendingPathComponent("accounts.json.bak"))
        print("PASS preseed-only-legacy-codex-disconnected")
    case "await-ready": try awaitReady(args)
    case "terminate": try terminate(args)
    case "run":
        let driver = try Driver(args)
        do {
            try driver.runScenario()
            try driver.dump("\(args.phase)-ax-tree.txt")
        } catch {
            driver.releaseMouse()
            do { try driver.dump("failure-ax-tree.txt"); try driver.screenshot("failure") }
            catch { fputs("Evidence capture failed: \(error)\n", stderr) }
            throw error
        }
    default: throw QAError("unsupported --action \(args.action)")
    }
}

do { try main() }
catch {
    FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
    exit(1)
}
