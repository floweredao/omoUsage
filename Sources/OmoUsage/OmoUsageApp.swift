import AppKit

@main
enum OmoUsageApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        if !application.setActivationPolicy(.accessory) {
            NSLog("OmoUsage failed to set accessory activation policy at startup")
        }

        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
