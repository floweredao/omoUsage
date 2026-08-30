import Foundation
import Testing
@testable import OmoUsage

@Suite(.serialized)
struct SingleInstanceControllerTests {
    @Test(.timeLimit(.minutes(1)))
    func ownerReceivesActivationAndContenderExits() async throws {
        let fixture = try SingleInstanceFixture()
        defer { fixture.cleanup() }

        let owner = try fixture.launch()
        let ownerEvent = try await owner.nextEvent()
        #expect(ownerEvent == "owner")

        let metadata = try String(contentsOf: fixture.lockURL, encoding: .utf8)
        #expect(metadata == "\(owner.processIdentifier)\n")

        let contender = try fixture.launch()
        let contenderEvent = try await contender.nextEvent()
        #expect(contenderEvent == "contender")
        #expect(try await contender.terminationStatus() == 0)

        let activationEvent = try await owner.nextEvent()
        #expect(activationEvent == "activation")
        #expect(try await owner.terminationStatus() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleLivePIDMetadataNeverOverridesAdvisoryLockOwnership() async throws {
        let fixture = try SingleInstanceFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: fixture.lockURL,
            atomically: true,
            encoding: .utf8
        )

        let owner = try fixture.launch()
        #expect(try await owner.nextEvent() == "owner")

        let contender = try fixture.launch()
        #expect(try await contender.nextEvent() == "contender")
        #expect(try await contender.terminationStatus() == 0)
        #expect(try await owner.nextEvent() == "activation")
        #expect(try await owner.terminationStatus() == 0)
    }

    @Test @MainActor
    func productionNamespaceAndLockLocationAreAppSpecific() throws {
        let lockURL = try SingleInstanceController.defaultLockURL(
            fileManager: .default
        )

        #expect(
            SingleInstanceController.activationNotificationName.rawValue
                == "com.omo.usage.single-instance.activate"
        )
        #expect(lockURL.lastPathComponent == "interactive-instance.lock")
        #expect(lockURL.deletingLastPathComponent().lastPathComponent == "OmoUsage")
    }
}

private final class SingleInstanceFixture: @unchecked Sendable {
    let directory: URL
    let lockURL: URL
    private let notificationName: String
    private let executableURL: URL
    private let lock = NSLock()
    private var processes: [SingleInstanceFixtureProcess] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "SingleInstanceControllerTests-\(UUID().uuidString)"
        )
        lockURL = directory.appending(path: "interactive-instance.lock")
        notificationName = "com.omo.usage.tests.\(UUID().uuidString).activate"
        executableURL = try Self.productExecutableURL()
    }

    func launch() throws -> SingleInstanceFixtureProcess {
        let fixtureProcess = try SingleInstanceFixtureProcess(
            executableURL: executableURL,
            environment: [
                "OMO_USAGE_SINGLE_INSTANCE_FIXTURE": "1",
                "OMO_USAGE_SINGLE_INSTANCE_LOCK_PATH": lockURL.path,
                "OMO_USAGE_SINGLE_INSTANCE_NOTIFICATION": notificationName
            ]
        )
        lock.withLock {
            processes.append(fixtureProcess)
        }
        return fixtureProcess
    }

    func cleanup() {
        let running = lock.withLock { processes }
        for process in running where process.isRunning {
            process.terminate()
        }
        for process in running {
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func productExecutableURL() throws -> URL {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = repositoryRoot
            .appending(path: ".build/debug/OmoUsage")
        guard FileManager.default.isExecutableFile(
            atPath: executable.path
        ) else {
            throw SingleInstanceFixtureError.productExecutableNotFound
        }
        return executable
    }
}

private final class SingleInstanceFixtureProcess: @unchecked Sendable {
    private let process: Process
    private let events = SingleInstanceFixtureEvents()
    private let output: Pipe

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(executableURL: URL, environment: [String: String]) throws {
        process = Process()
        output = Pipe()
        process.executableURL = executableURL
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment,
            uniquingKeysWith: { _, fixture in fixture }
        )
        process.standardOutput = output
        process.standardError = output

        let events = self.events
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                events.finishOutput()
            } else {
                events.receive(data)
            }
        }
        process.terminationHandler = { process in
            events.terminate(status: process.terminationStatus)
        }
        try process.run()
    }

    func nextEvent() async throws -> String {
        try await events.nextEvent()
    }

    func terminationStatus() async throws -> Int32 {
        try await events.terminationStatus()
    }

    func terminate() {
        process.terminate()
    }

    func waitUntilExit() {
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
    }
}

private final class SingleInstanceFixtureEvents: @unchecked Sendable {
    private let condition = NSCondition()
    private var bufferedData = Data()
    private var lines: [String] = []
    private var status: Int32?
    private var outputFinished = false

    func receive(_ data: Data) {
        condition.withLock {
            bufferedData.append(data)
            while let newline = bufferedData.firstIndex(of: 0x0A) {
                let lineData = bufferedData[..<newline]
                bufferedData.removeSubrange(...newline)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
            }
            condition.broadcast()
        }
    }

    func finishOutput() {
        condition.withLock {
            outputFinished = true
            condition.broadcast()
        }
    }

    func terminate(status: Int32) {
        condition.withLock {
            self.status = status
            condition.broadcast()
        }
    }

    func nextEvent() async throws -> String {
        try await Task.detached {
            try self.condition.withLock {
                while true {
                    if !self.lines.isEmpty {
                        return self.lines.removeFirst()
                    }
                    if self.outputFinished, let status = self.status {
                        throw SingleInstanceFixtureError
                            .exitedBeforeEvent(status)
                    }
                    self.condition.wait()
                }
            }
        }.value
    }

    func terminationStatus() async throws -> Int32 {
        await Task.detached {
            self.condition.withLock {
                while self.status == nil {
                    self.condition.wait()
                }
                return self.status!
            }
        }.value
    }
}

private enum SingleInstanceFixtureError: Error {
    case productExecutableNotFound
    case exitedBeforeEvent(Int32)
}
