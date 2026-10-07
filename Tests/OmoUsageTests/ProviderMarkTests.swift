import CoreGraphics
import Foundation
import Testing
@testable import OmoUsageCore

@Suite
struct ProviderMarkTests {
    private let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test(arguments: [ProviderID.claude, .codex, .antigravity])
    func bundledMarksDecodeAsOneClosedShapeInsideTheirViewBox(
        provider: ProviderID
    ) throws {
        let mark = try bundledMark(for: provider)
        let elements = try #require(mark.shapes.first?.elements)
        let bounds = mark.viewBox.insetBy(dx: -1, dy: -1)

        #expect(mark.viewBox == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(mark.shapes.count == 1)
        #expect(elements.count > 3)
        #expect(points(of: elements[0]).count == 1)
        if case .move = elements[0] {} else {
            Issue.record("a mark must start with a move")
        }
        #expect(elements.last == .close)
        #expect(elements.flatMap(points).allSatisfy(bounds.contains))
    }

    @Test
    func templateMarksTintWhileAntigravityKeepsItsBrandColor() throws {
        #expect(try bundledMark(for: .claude).shapes[0].fill == .currentColor)
        #expect(try bundledMark(for: .codex).shapes[0].fill == .currentColor)
        #expect(
            try bundledMark(for: .antigravity).shapes[0].fill
                == .rgb(VisualRGB(red: 0x42, green: 0x85, blue: 0xF4))
        )
    }

    @Test
    func relativeCommandsAndImplicitRepetitionResolveToAbsolutePoints() throws {
        let elements = try #require(
            SVGPathData.elements("M10,10 l5 0 5 5v5H10z")
        )

        #expect(elements == [
            .move(CGPoint(x: 10, y: 10)),
            .line(CGPoint(x: 15, y: 10)),
            .line(CGPoint(x: 20, y: 15)),
            .line(CGPoint(x: 20, y: 20)),
            .line(CGPoint(x: 10, y: 20)),
            .close
        ])
    }

    @Test
    func smoothCurvesReflectThePreviousControlPoint() throws {
        let elements = try #require(
            SVGPathData.elements("M0 0 C10 10 20 10 30 0 S50 -10 60 0")
        )

        #expect(elements == [
            .move(.zero),
            .curve(
                to: CGPoint(x: 30, y: 0),
                control1: CGPoint(x: 10, y: 10),
                control2: CGPoint(x: 20, y: 10)
            ),
            .curve(
                to: CGPoint(x: 60, y: 0),
                control1: CGPoint(x: 40, y: -10),
                control2: CGPoint(x: 50, y: -10)
            )
        ])
    }

    @Test(arguments: [
        "M0 0 A10 10 0 0 1 10 10",
        "M0 0 L",
        "10 10 L 20 20",
        "M0 0 Z 5 5"
    ])
    func unsupportedPathDataFailsInsteadOfDrawingPartOfAMark(data: String) {
        #expect(SVGPathData.elements(data) == nil)
    }

    @Test
    func unsupportedElementsFailTheWholeMark() {
        let svg = Data(
            """
            <svg viewBox="0 0 10 10"><rect width="10" height="10"/></svg>
            """.utf8
        )

        #expect(ProviderMark(svg: svg) == nil)
    }

    private func bundledMark(for provider: ProviderID) throws -> ProviderMark {
        let url = repositoryRoot
            .appending(path: "Sources/OmoUsage/Resources/ProviderIcons")
            .appending(path: "\(provider.rawValue).svg")
        return try #require(ProviderMark(svg: Data(contentsOf: url)))
    }

    private func points(of element: ProviderMark.Element) -> [CGPoint] {
        switch element {
        case .move(let point), .line(let point):
            [point]
        case .quadCurve(let point, let control):
            [point, control]
        case .curve(let point, let control1, let control2):
            [point, control1, control2]
        case .close:
            []
        }
    }
}
