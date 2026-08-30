import AppKit
import Darwin

@main
enum OmoUsageApp {
    @MainActor
    static func main() {
        if ProcessInfo.processInfo.environment[
            "OMO_USAGE_SINGLE_INSTANCE_FIXTURE"
        ] == "1" {
            runSingleInstanceFixture()
            return
        }

        let singleInstance: SingleInstanceController
        do {
            singleInstance = try SingleInstanceController.live()
            guard try singleInstance.claim() == .owner else {
                NSLog("OmoUsage activation handoff sent")
                return
            }
            NSLog("OmoUsage interactive instance owner acquired")
        } catch {
            NSLog(
                "OmoUsage single-instance ownership failed (%@)",
                String(reflecting: type(of: error))
            )
            return
        }

        let application = NSApplication.shared
        if !application.setActivationPolicy(.accessory) {
            NSLog("OmoUsage failed to set accessory activation policy at startup")
        }

        let delegate = AppDelegate()
        singleInstance.installActivationHandler { [weak delegate] in
            delegate?.activateFromSecondaryLaunch()
            NSLog("OmoUsage activation handoff received")
        }
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
        withExtendedLifetime(singleInstance) {}
    }

    @MainActor
    private static func runSingleInstanceFixture() {
        do {
            let singleInstance = try SingleInstanceController.live()
            switch try singleInstance.claim() {
            case .owner:
                writeFixtureEvent("owner")
                singleInstance.installActivationHandler {
                    writeFixtureEvent("activation")
                    Darwin.exit(EXIT_SUCCESS)
                }
                RunLoop.main.run()
                withExtendedLifetime(singleInstance) {}
            case .contender:
                guard singleInstance.activationHandoffWasAcknowledged else {
                    writeFixtureEvent("handoff-timeout")
                    Darwin.exit(EXIT_FAILURE)
                }
                writeFixtureEvent("contender")
            }
        } catch {
            writeFixtureEvent("error")
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func writeFixtureEvent(_ event: String) {
        FileHandle.standardOutput.write(Data("\(event)\n".utf8))
    }
}
