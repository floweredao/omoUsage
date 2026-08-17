import AppKit
import SwiftUI

struct ProviderIcon: View {
    let provider: ProviderID

    var body: some View {
        let style = ProviderVisualStyle.style(for: provider)
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(style.background)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(provider == .antigravity ? .original : .template)
                    .foregroundStyle(.white)
                    .padding(3)
            } else {
                Text(provider.monogram)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(style.foreground)
            }
        }
    }

    private var image: NSImage? {
        if let resourceURL = Bundle.main.resourceURL {
            let packagedURL = resourceURL
                .appending(path: "ProviderIcons", directoryHint: .isDirectory)
                .appending(path: "\(provider.rawValue).svg")
            if FileManager.default.fileExists(atPath: packagedURL.path) {
                return NSImage(contentsOf: packagedURL)
            }
        }
        guard Bundle.main.bundleURL.pathExtension != "app" else {
            return nil
        }
        #if SWIFT_PACKAGE
        guard let url = Bundle.module.url(
            forResource: provider.rawValue,
            withExtension: "svg"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
        #else
        return nil
        #endif
    }
}
