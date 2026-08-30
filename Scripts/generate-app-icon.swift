import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate-app-icon.swift <source.svg> <iconset>\n", stderr)
    exit(2)
}

let source = URL(filePath: CommandLine.arguments[1])
let destination = URL(
    filePath: CommandLine.arguments[2],
    directoryHint: .isDirectory
)
guard let image = NSImage(contentsOf: source) else {
    fputs("could not load app icon source\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(
    at: destination,
    withIntermediateDirectories: true
)

for logicalSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = logicalSize * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            exit(1)
        }
        bitmap.size = NSSize(width: logicalSize, height: logicalSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            bitmapImageRep: bitmap
        )
        image.draw(
            in: NSRect(
                x: 0,
                y: 0,
                width: logicalSize,
                height: logicalSize
            ),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let output = destination.appending(
            path: "icon_\(logicalSize)x\(logicalSize)\(suffix).png"
        )
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: output
        )
    }
}
