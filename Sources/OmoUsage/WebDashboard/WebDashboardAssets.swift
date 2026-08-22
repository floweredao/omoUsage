import AppKit
import Foundation

enum WebDashboardAssets {
    private static let indexTemplate: Data = {
        guard
            let url = resourceBundle.url(
                forResource: "index",
                withExtension: "html"
            ),
            let data = try? Data(contentsOf: url)
        else {
            return Data()
        }
        return data
    }()

    static let appIconSVG: Data = {
        guard
            let url = resourceBundle.url(
                forResource: "AppIcon",
                withExtension: "svg"
            ),
            let data = try? Data(contentsOf: url)
        else {
            return Data()
        }
        return data
    }()

    static let appleTouchIconPNG: Data = {
        renderPNG(
            source: appIconSVG,
            pixelSize: 180
        )
    }()

    static func indexHTML(mutationNonce: String) -> Data {
        guard
            let template = String(
                data: indexTemplate,
                encoding: .utf8
            )
        else {
            return Data()
        }
        return Data(
            template.replacingOccurrences(
                of: "__OMO_CSRF_TOKEN__",
                with: mutationNonce
            ).utf8
        )
    }

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    private static func renderPNG(
        source: Data,
        pixelSize: Int
    ) -> Data {
        guard
            let image = NSImage(data: source),
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelSize,
                pixelsHigh: pixelSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(
                bitmapImageRep: bitmap
            )
        else {
            return Data()
        }

        let bounds = NSRect(
            x: 0,
            y: 0,
            width: pixelSize,
            height: pixelSize
        )
        bitmap.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        bounds.fill()
        image.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        return bitmap.representation(
            using: .png,
            properties: [:]
        ) ?? Data()
    }
}
