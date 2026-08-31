import OmoUsageCore
import AppKit
import Foundation

enum WebDashboardAssets {
    private static let indexTemplate: Data = {
        guard
            let url = bundledResourceURL(
                name: "index",
                extension: "html"
            ),
            let data = try? Data(contentsOf: url)
        else {
            return Data()
        }
        return data
    }()

    static let appIconSVG: Data = {
        guard
            let url = bundledResourceURL(
                name: "AppIcon",
                extension: "svg"
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

    static let providerIconSVGs: [ProviderID: Data] = {
        Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.compactMap {
                provider in
                providerIconSVG(for: provider).map {
                    (provider, $0)
                }
            }
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

    private static func bundledResourceURL(
        name: String,
        extension fileExtension: String
    ) -> URL? {
        #if SWIFT_PACKAGE
        resourceURL(
            name: name,
            extension: fileExtension,
            mainBundle: .main,
            packageBundle: { Bundle.module }
        )
        #else
        resourceURL(
            name: name,
            extension: fileExtension,
            mainBundle: .main,
            packageBundle: { nil }
        )
        #endif
    }

    private static func providerIconSVG(
        for provider: ProviderID
    ) -> Data? {
        let fileName = "\(provider.rawValue).svg"
        let packaged = Bundle.main.resourceURL?
            .appending(
                path: "ProviderIcons",
                directoryHint: .isDirectory
            )
            .appending(path: fileName)
        if
            let packaged,
            FileManager.default.fileExists(atPath: packaged.path)
        {
            return try? Data(contentsOf: packaged)
        }
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return nil
        }
        #if SWIFT_PACKAGE
        guard
            let url = Bundle.module.url(
                forResource: provider.rawValue,
                withExtension: "svg"
            )
        else {
            return nil
        }
        return try? Data(contentsOf: url)
        #else
        return nil
        #endif
    }

    static func resourceURL(
        name: String,
        extension fileExtension: String,
        mainBundle: Bundle,
        packageBundle: () -> Bundle?
    ) -> URL? {
        let packaged = mainBundle.resourceURL?
            .appending(path: "\(name).\(fileExtension)")
        if
            let packaged,
            FileManager.default.fileExists(atPath: packaged.path)
        {
            return packaged
        }
        guard mainBundle.bundleURL.pathExtension != "app" else {
            return nil
        }
        return packageBundle()?.url(
            forResource: name,
            withExtension: fileExtension
        )
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
