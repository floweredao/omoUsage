import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    exit(2)
}

switch CommandLine.arguments[1] {
case "move":
    guard
        CommandLine.arguments.count == 4,
        let x = Double(CommandLine.arguments[2]),
        let y = Double(CommandLine.arguments[3])
    else {
        exit(2)
    }
    let point = CGPoint(x: x, y: y)
    CGWarpMouseCursorPosition(point)
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left
    )?.post(tap: .cghidEventTap)
case "scroll":
    guard
        CommandLine.arguments.count == 3,
        let amount = Int32(CommandLine.arguments[2])
    else {
        exit(2)
    }
    CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: amount,
        wheel2: 0,
        wheel3: 0
    )?.post(tap: .cghidEventTap)
case "down", "up":
    let type: CGEventType = CommandLine.arguments[1] == "down"
        ? .leftMouseDown
        : .leftMouseUp
    CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero,
        mouseButton: .left
    )?.post(tap: .cghidEventTap)
case "where":
    if let point = CGEvent(source: nil)?.location {
        print("\(Int(point.x)) \(Int(point.y))")
    }
default:
    exit(2)
}
