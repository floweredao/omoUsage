import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
@MainActor
struct KiroBrowserConnectionTests {
    private let identity = AccountProviderID(accountID: .legacy, providerID: .kiro)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test
    func existingCredentialConnectsWithoutOpeningBrowser() async throws {
        let coordinator = KiroBrowserConnectionCoordinator()
        var events: [String] = []
        let result = try await coordinator.connect(
            target: .existing(identity),
            discover: { events.append("discover"); return snapshot("existing") },
            authenticate: { events.append("browser"); return snapshot("oauth") },
            validate: { secret in
                events.append("validate:\(secret.accessToken)")
                return usage()
            },
            persist: { target, secret in
                #expect(target == .existing(identity))
                events.append("persist:\(secret.accessToken)")
                return identity
            }
        )
        #expect(result == identity)
        #expect(events == ["discover", "validate:existing", "persist:existing"])
        #expect(coordinator.pending == nil)
    }

    @Test(arguments: [
        CredentialDiscoveryError.notFound(.kiro),
        CredentialDiscoveryError.expired(.kiro)
    ])
    func absentCredentialTransitionsDirectlyToBrowser(_ error: CredentialDiscoveryError) async throws {
        let coordinator = KiroBrowserConnectionCoordinator()
        var events: [String] = []
        _ = try await coordinator.connect(
            target: .existing(identity),
            discover: { events.append("discover"); throw error },
            authenticate: {
                #expect(coordinator.pending == .existing(identity))
                events.append("browser")
                return snapshot("oauth")
            },
            validate: { secret in events.append("validate:\(secret.accessToken)"); return usage() },
            persist: { _, secret in events.append("persist:\(secret.accessToken)"); return identity }
        )
        #expect(events == ["discover", "browser", "validate:oauth", "persist:oauth"])
    }

    @Test
    func rejectedExistingCredentialOpensBrowserExactlyOnce() async throws {
        var browserCount = 0
        var persisted: String?
        _ = try await KiroBrowserConnectionCoordinator().connect(
            target: .existing(identity),
            discover: { snapshot("rejected") },
            authenticate: { browserCount += 1; return snapshot("oauth") },
            validate: { secret in
                if secret.accessToken == "rejected" {
                    throw ProviderTransportError.authenticationRequired(.kiro)
                }
                return usage()
            },
            persist: { _, secret in persisted = secret.accessToken; return identity }
        )
        #expect(browserCount == 1)
        #expect(persisted == "oauth")
    }

    @Test
    func transientFailureDoesNotOpenBrowserOrOverwriteCredentials() async {
        var browserCount = 0
        var writes = 0
        await #expect(throws: ProviderTransportError.requestFailed(.kiro, 500)) {
            try await KiroBrowserConnectionCoordinator().connect(
                target: .existing(identity),
                discover: { snapshot("existing") },
                authenticate: { browserCount += 1; return snapshot("oauth") },
                validate: { _ in throw ProviderTransportError.requestFailed(.kiro, 500) },
                persist: { _, _ in writes += 1; return identity }
            )
        }
        #expect(browserCount == 0)
        #expect(writes == 0)
    }

    @Test
    func malformedOrDeniedCredentialReadDoesNotWidenAuthentication() async {
        var browserCount = 0
        await #expect(throws: CredentialDiscoveryError.malformed(.kiro)) {
            try await KiroBrowserConnectionCoordinator().connect(
                target: .existing(identity),
                discover: { throw CredentialDiscoveryError.malformed(.kiro) },
                authenticate: { browserCount += 1; return snapshot("oauth") },
                validate: { _ in usage() },
                persist: { _, _ in identity }
            )
        }
        #expect(browserCount == 0)
    }

    @Test
    func anotherProfileIsNotImportedIntoSelectedAccount() async throws {
        let coordinator = KiroBrowserConnectionCoordinator()
        var browserCount = 0
        var writes = 0
        await #expect(throws: KiroBrowserConnectionError.accountMismatch) {
            try await coordinator.connect(
                target: .existing(identity), expectedProfile: "profile/selected",
                discover: { snapshot("companion", profile: "profile/other") },
                authenticate: { browserCount += 1; return snapshot("oauth", profile: "profile/other") },
                validate: { _ in usage() },
                persist: { _, _ in writes += 1; return identity }
            )
        }
        #expect(browserCount == 1)
        #expect(writes == 0)
        #expect(coordinator.pending == nil)
    }

    @Test
    func addingAccountDoesNotDuplicateAnAlreadyCapturedProfile() async throws {
        var browserCount = 0
        var storedProfile: String?
        _ = try await KiroBrowserConnectionCoordinator().connect(
            target: .newAccount("Work"), excludedProfiles: ["profile/existing"],
            discover: { snapshot("existing", profile: "profile/existing") },
            authenticate: { browserCount += 1; return snapshot("oauth", profile: "profile/new") },
            validate: { _ in usage() },
            persist: { _, secret in storedProfile = secret.accountReference; return identity }
        )
        #expect(browserCount == 1)
        #expect(storedProfile == "profile/new")
    }

    @Test
    func cancellationAfterValidationDoesNotSave() async {
        let coordinator = KiroBrowserConnectionCoordinator()
        var writes = 0
        let task = Task { @MainActor in
            try await coordinator.connect(
                target: .existing(identity),
                discover: { snapshot("existing") },
                authenticate: { snapshot("oauth") },
                validate: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return usage()
                },
                persist: { _, _ in writes += 1; return identity }
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(writes == 0)
        #expect(coordinator.pending == nil)
    }

    @Test
    func invalidNewAccountLabelFailsBeforeDiscoveryOrBrowser() async {
        let coordinator = KiroBrowserConnectionCoordinator()
        var events: [String] = []
        await #expect(throws: ProviderAccountRegistryControllerError.invalidLabel) {
            try await coordinator.connect(
                target: .newAccount("   "),
                discover: { events.append("discover"); return snapshot("existing") },
                authenticate: { events.append("browser"); return snapshot("oauth") },
                validate: { _ in events.append("validate"); return usage() },
                persist: { _, _ in events.append("persist"); return identity }
            )
        }
        #expect(events.isEmpty)
        #expect(coordinator.pending == nil)
    }

    @Test
    func alreadyAddedProfileIsReportedDistinctlyFromMismatch() async {
        await #expect(throws: KiroBrowserConnectionError.accountAlreadyConnected) {
            try await KiroBrowserConnectionCoordinator().connect(
                target: .newAccount("Work"), excludedProfiles: ["profile/existing"],
                discover: { throw CredentialDiscoveryError.notFound(.kiro) },
                authenticate: { snapshot("oauth", profile: "profile/existing") },
                validate: { _ in usage() },
                persist: { _, _ in identity }
            )
        }
    }

    @Test
    func registryWriteFailureIsReportedAsStorageFailure() async {
        await #expect(throws: KiroBrowserConnectionError.storageFailed) {
            try await KiroBrowserConnectionCoordinator().connect(
                target: .existing(identity),
                discover: { snapshot("existing") },
                authenticate: { snapshot("oauth") },
                validate: { _ in usage() },
                persist: { _, _ in throw ProviderAccountRegistryControllerError.persistenceUnavailable }
            )
        }
    }

    @Test
    func eachFailureMapsToItsOwnMessage() {
        let cases: [(any Error, AppStringKey?)] = [
            (KiroBrowserConnectionError.accountMismatch, .kiroAccountMismatch),
            (KiroBrowserConnectionError.accountAlreadyConnected, .kiroAccountAlreadyConnected),
            (KiroBrowserConnectionError.usageUnavailable, .browserUsageUnavailable),
            (KiroBrowserConnectionError.storageFailed, .browserCredentialSaveFailed),
            (KiroBrowserConnectionError.alreadyConnecting, nil),
            (ProviderAccountRegistryControllerError.invalidLabel, .accountAdditionFailed),
            (KiroBrowserAuthenticationError.timedOut, .browserSignInTimedOut),
            (KiroBrowserAuthenticationError.authorizationDenied, .browserSignInDenied),
            (KiroBrowserAuthenticationError.unsupportedOrganization, .kiroUnsupportedOrganization),
            (KiroBrowserAuthenticationError.browserOpenFailed, .unableToOpenOfficialAuthentication),
            (KiroBrowserAuthenticationError.exchangeFailed, .browserLoginFailed),
            (ProviderTransportError.requestFailed(.kiro, 500), .browserUsageUnavailable),
            (CancellationError(), nil)
        ]
        for (error, key) in cases {
            #expect(KiroBrowserConnectionFeedback.message(for: error) == key)
        }
    }

    private func snapshot(_ token: String, profile: String = "profile/selected") -> CredentialSnapshot {
        CredentialSnapshot(
            provider: .kiro, accessToken: token, refreshToken: nil,
            accountReference: profile, planName: nil,
            expiresAt: now.addingTimeInterval(3_600), source: .file
        )
    }

    private func usage() -> ProviderUsage {
        ProviderUsage(provider: .kiro, planName: "Pro", groups: [], availability: .available, updatedAt: now)
    }
}
