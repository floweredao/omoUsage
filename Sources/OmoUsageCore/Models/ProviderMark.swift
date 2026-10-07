import CoreGraphics
import Foundation

/// The vector artwork of a bundled provider mark, decoded from the SVG that
/// ships beside the macOS app. UIKit cannot decode SVG files at runtime, so
/// the mobile tile draws these elements itself and stays identical to
/// `ProviderIcon`.
public struct ProviderMark: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    public enum Fill: Equatable, Sendable {
        /// `currentColor`: the surface tints the shape like a template image.
        case currentColor
        case rgb(VisualRGB)
    }

    public struct Shape: Equatable, Sendable {
        public let elements: [Element]
        public let fill: Fill

        public init(elements: [Element], fill: Fill) {
            self.elements = elements
            self.fill = fill
        }
    }

    public let viewBox: CGRect
    public let shapes: [Shape]

    /// Decodes an SVG made of filled `path` elements inside a `viewBox`. Any
    /// other element, an arc segment, or a malformed value fails the whole
    /// mark so a caller falls back to the monogram instead of drawing part of
    /// the artwork.
    public init?(svg data: Data) {
        let reader = SVGReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        guard
            reader.isSupported,
            let viewBox = reader.viewBox,
            !reader.shapes.isEmpty
        else {
            return nil
        }
        self.viewBox = viewBox
        shapes = reader.shapes
    }
}

private final class SVGReader: NSObject, XMLParserDelegate {
    private(set) var viewBox: CGRect?
    private(set) var shapes: [ProviderMark.Shape] = []
    private(set) var isSupported = true

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "svg":
            viewBox = attributes["viewBox"].flatMap(Self.rect)
        case "path":
            if
                let fill = Self.fill(attributes["fill"]),
                let elements = SVGPathData.elements(attributes["d"] ?? "")
            {
                shapes.append(
                    ProviderMark.Shape(elements: elements, fill: fill)
                )
                return
            }
            isSupported = false
            parser.abortParsing()
        default:
            isSupported = false
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        isSupported = false
    }

    private static func rect(_ value: String) -> CGRect? {
        let numbers = value
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else {
            return nil
        }
        return CGRect(
            x: numbers[0],
            y: numbers[1],
            width: numbers[2],
            height: numbers[3]
        )
    }

    private static func fill(_ value: String?) -> ProviderMark.Fill? {
        guard let value else {
            // SVG fills black when the attribute is absent.
            return .rgb(VisualRGB(red: 0, green: 0, blue: 0))
        }
        if value == "currentColor" {
            return .currentColor
        }
        guard value.hasPrefix("#") else {
            return nil
        }
        let hex = value.dropFirst()
        let digits = hex.count == 3 ? hex.flatMap { [$0, $0] } : Array(hex)
        guard
            digits.count == 6,
            let number = UInt32(String(digits), radix: 16)
        else {
            return nil
        }
        return .rgb(
            VisualRGB(
                red: UInt8(number >> 16 & 0xFF),
                green: UInt8(number >> 8 & 0xFF),
                blue: UInt8(number & 0xFF)
            )
        )
    }
}

/// Reads SVG path data (`M L H V C S Q T Z`, absolute or relative, with
/// implicit command repetition). Arcs and malformed data yield `nil`.
enum SVGPathData {
    static func elements(_ data: String) -> [ProviderMark.Element]? {
        let scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ","))
        var elements: [ProviderMark.Element] = []
        var command: Character?
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var cubicControl: CGPoint?
        var quadraticControl: CGPoint?

        func number() -> CGFloat? {
            scanner.scanDouble().map { CGFloat($0) }
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative
                ? CGPoint(x: current.x + x, y: current.y + y)
                : CGPoint(x: x, y: y)
        }
        func reflected(_ control: CGPoint?) -> CGPoint {
            guard let control else { return current }
            return CGPoint(
                x: 2 * current.x - control.x,
                y: 2 * current.y - control.y
            )
        }

        while !scanner.isAtEnd {
            let index = scanner.currentIndex
            if let letter = scanner.scanCharacter(), letter.isLetter {
                command = letter
            } else {
                scanner.currentIndex = index
            }
            guard let active = command else { return nil }
            let relative = active.isLowercase
            var nextCubicControl: CGPoint?
            var nextQuadraticControl: CGPoint?
            switch active.uppercased() {
            case "M":
                guard let point = point(relative: relative) else { return nil }
                elements.append(.move(point))
                current = point
                subpathStart = point
                command = relative ? "l" : "L"
            case "L":
                guard let point = point(relative: relative) else { return nil }
                elements.append(.line(point))
                current = point
            case "H":
                guard let x = number() else { return nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                elements.append(.line(current))
            case "V":
                guard let y = number() else { return nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                elements.append(.line(current))
            case "C":
                guard
                    let control1 = point(relative: relative),
                    let control2 = point(relative: relative),
                    let point = point(relative: relative)
                else { return nil }
                elements.append(
                    .curve(to: point, control1: control1, control2: control2)
                )
                nextCubicControl = control2
                current = point
            case "S":
                let control1 = reflected(cubicControl)
                guard
                    let control2 = point(relative: relative),
                    let point = point(relative: relative)
                else { return nil }
                elements.append(
                    .curve(to: point, control1: control1, control2: control2)
                )
                nextCubicControl = control2
                current = point
            case "Q":
                guard
                    let control = point(relative: relative),
                    let point = point(relative: relative)
                else { return nil }
                elements.append(.quadCurve(to: point, control: control))
                nextQuadraticControl = control
                current = point
            case "T":
                let control = reflected(quadraticControl)
                guard let point = point(relative: relative) else { return nil }
                elements.append(.quadCurve(to: point, control: control))
                nextQuadraticControl = control
                current = point
            case "Z":
                elements.append(.close)
                current = subpathStart
                command = nil
            default:
                return nil
            }
            cubicControl = nextCubicControl
            quadraticControl = nextQuadraticControl
        }
        return elements
    }
}
