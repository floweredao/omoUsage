import AppKit
import Foundation

enum StatusItemIconWeight: Equatable, Sendable {
    case medium
}

enum StatusItemIconRenderingMode: Equatable, Sendable {
    case monochromeTemplate
}

enum StatusItemIconVisualTokens {
    static let symbolName = "gauge.with.dots.needle.50percent"
    static let pointSize = 14.0
    static let weight = StatusItemIconWeight.medium
    static let renderingMode = StatusItemIconRenderingMode.monochromeTemplate
}

@MainActor
enum AppIconFactory {
    static func applicationIcon() -> NSImage? {
        guard let url = resourceURL(name: "AppIcon", extension: "svg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    static func menuBarIcon() -> NSImage {
        guard let symbol = NSImage(
            systemSymbolName: StatusItemIconVisualTokens.symbolName,
            accessibilityDescription: nil
        ) else {
            preconditionFailure("Required status-item SF Symbol is unavailable")
        }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: StatusItemIconVisualTokens.pointSize,
            weight: appKitWeight
        )
        guard let image = symbol.withSymbolConfiguration(configuration) else {
            preconditionFailure("Status-item SF Symbol configuration failed")
        }
        let centered = NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            return true
        }
        centered.isTemplate = true
        return centered
    }

    private static var appKitWeight: NSFont.Weight {
        switch StatusItemIconVisualTokens.weight {
        case .medium:
            .medium
        }
    }

    private static func resourceURL(
        name: String,
        extension fileExtension: String
    ) -> URL? {
        if let packaged = Bundle.main.resourceURL?
            .appending(path: "\(name).\(fileExtension)"),
           FileManager.default.fileExists(atPath: packaged.path)
        {
            return packaged
        }
        #if SWIFT_PACKAGE
        return Bundle.module.url(
            forResource: name,
            withExtension: fileExtension
        )
        #else
        return nil
        #endif
    }
}
