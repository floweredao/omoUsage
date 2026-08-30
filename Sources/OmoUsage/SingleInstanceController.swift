import Foundation
import Darwin

enum SingleInstanceRole: Equatable {
    case owner
    case contender
}

enum SingleInstanceControllerError: Error {
    case applicationSupportDirectoryUnavailable
    case openFailed(Int32)
    case lockFailed(Int32)
    case metadataWriteFailed(Int32)
}

@MainActor
final class SingleInstanceController: NSObject {
    static let activationNotificationName = Notification.Name(
        "com.omo.usage.single-instance.activate"
    )

    private let lockURL: URL
    private let notificationName: Notification.Name
    private let notificationCenter: DistributedNotificationCenter
    private let processIdentifier: Int32
    private var lockDescriptor: Int32 = -1
    private var role: SingleInstanceRole?
    private var activationHandler: (() -> Void)?
    private var hasPendingActivation = false
    private var isObserving = false

    init(
        lockURL: URL,
        notificationName: Notification.Name = activationNotificationName,
        notificationCenter: DistributedNotificationCenter = .default(),
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.lockURL = lockURL
        self.notificationName = notificationName
        self.notificationCenter = notificationCenter
        self.processIdentifier = processIdentifier
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> SingleInstanceController {
        let lockURL: URL
        if let override = environment["OMO_USAGE_SINGLE_INSTANCE_LOCK_PATH"] {
            lockURL = URL(fileURLWithPath: override)
        } else {
            lockURL = try defaultLockURL(fileManager: fileManager)
        }
        let notificationName = environment[
            "OMO_USAGE_SINGLE_INSTANCE_NOTIFICATION"
        ].map { Notification.Name($0) } ?? activationNotificationName
        return SingleInstanceController(
            lockURL: lockURL,
            notificationName: notificationName
        )
    }

    static func defaultLockURL(fileManager: FileManager) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SingleInstanceControllerError
                .applicationSupportDirectoryUnavailable
        }
        return applicationSupport
            .appending(path: "OmoUsage", directoryHint: .isDirectory)
            .appending(path: "interactive-instance.lock")
    }

    func claim() throws -> SingleInstanceRole {
        precondition(role == nil, "Single-instance ownership can only be claimed once")
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        startObservingActivation()
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            stopObservingActivation()
            throw SingleInstanceControllerError.openFailed(errno)
        }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)

        guard setAdvisoryLock(F_WRLCK, on: descriptor) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EACCES || lockError == EAGAIN {
                role = .contender
                stopObservingActivation()
                notificationCenter.postNotificationName(
                    notificationName,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                return .contender
            }
            stopObservingActivation()
            throw SingleInstanceControllerError.lockFailed(lockError)
        }

        do {
            try writeOwnerMetadata(to: descriptor)
        } catch {
            _ = setAdvisoryLock(F_UNLCK, on: descriptor)
            Darwin.close(descriptor)
            stopObservingActivation()
            throw error
        }
        lockDescriptor = descriptor
        role = .owner
        return .owner
    }

    func installActivationHandler(_ handler: @escaping () -> Void) {
        precondition(role == .owner, "Only the lock owner handles activation")
        activationHandler = handler
        if hasPendingActivation {
            hasPendingActivation = false
            handler()
        }
    }

    func releaseOwnership() {
        stopObservingActivation()
        guard lockDescriptor >= 0 else { return }
        _ = setAdvisoryLock(F_UNLCK, on: lockDescriptor)
        Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }

    deinit {
        let shouldRemoveObserver = isObserving
        let center = notificationCenter
        let name = notificationName
        let descriptor = lockDescriptor
        if shouldRemoveObserver {
            center.removeObserver(self, name: name, object: nil)
        }
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private func startObservingActivation() {
        notificationCenter.addObserver(
            self,
            selector: #selector(receiveActivation),
            name: notificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        isObserving = true
    }

    private func stopObservingActivation() {
        guard isObserving else { return }
        notificationCenter.removeObserver(
            self,
            name: notificationName,
            object: nil
        )
        isObserving = false
    }

    @objc
    private func receiveActivation() {
        guard role == .owner else { return }
        if let activationHandler {
            activationHandler()
        } else {
            hasPendingActivation = true
        }
    }

    private func setAdvisoryLock(
        _ type: Int32,
        on descriptor: Int32
    ) -> Int32 {
        var lock = flock()
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        return Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    private func writeOwnerMetadata(to descriptor: Int32) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else {
            throw SingleInstanceControllerError.metadataWriteFailed(errno)
        }
        let metadata = Data("\(processIdentifier)\n".utf8)
        try metadata.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw SingleInstanceControllerError
                        .metadataWriteFailed(errno)
                }
            }
        }
    }
}
