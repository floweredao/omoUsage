import AppKit
import Testing
@testable import OmoUsage

@Suite
@MainActor
struct AppIconRenderingTests {
    @Test
    func restoredIconUsesOriginalFrostAndRingPalette() throws {
        let icon = try renderedIcon()

        let outside = try color(atSVGX: 40, y: 40, in: icon)
        #expect(outside.alphaComponent < 0.05)

        let background = try color(atSVGX: 200, y: 200, in: icon)
        #expect(background.brightnessComponent > 0.85)
        #expect(background.redComponent > background.blueComponent)

        let center = try color(atSVGX: 512, y: 512, in: icon)
        #expect(center.brightnessComponent > 0.85)

        let outerRing = try color(atSVGX: 212, y: 512, in: icon)
        #expect(outerRing.redComponent > 0.85)
        #expect(outerRing.greenComponent > 0.30)
        #expect(outerRing.greenComponent < 0.65)
        #expect(outerRing.blueComponent < 0.45)

        let middleRing = try color(atSVGX: 307, y: 512, in: icon)
        #expect(middleRing.blueComponent > 0.75)
        #expect(middleRing.redComponent > 0.25)
        #expect(middleRing.redComponent < 0.55)

        let innerRing = try color(atSVGX: 402, y: 512, in: icon)
        #expect(innerRing.blueComponent > 0.80)
        #expect(innerRing.greenComponent > 0.35)
    }

    private func renderedIcon() throws -> NSBitmapImageRep {
        let resourceURL = try #require(
            Bundle.module.url(
                forResource: "AppIcon",
                withExtension: "svg"
            )
        )
        let image = try #require(NSImage(contentsOf: resourceURL))
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1_024,
                pixelsHigh: 1_024,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let context = try #require(
            NSGraphicsContext(bitmapImageRep: bitmap)
        )

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 1_024, height: 1_024).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: 1_024, height: 1_024),
            from: NSRect.zero,
            operation: NSCompositingOperation.sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        return bitmap
    }

    private func color(
        atSVGX x: Int,
        y: Int,
        in bitmap: NSBitmapImageRep
    ) throws -> NSColor {
        let color = try #require(bitmap.colorAt(x: x, y: y))
        return try #require(color.usingColorSpace(.sRGB))
    }
}
