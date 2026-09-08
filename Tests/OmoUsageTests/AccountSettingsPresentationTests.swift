import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

/// A fixed non-legacy account so identifiers can be pinned literally.
private let additionalAccountID = AccountID(
    rawValue: "6f1d2c3b-4a5e-4f60-8b7a-9c0d1e2f3a4b"
)!
private let primaryCodex = AccountProviderID(
    accountID: .legacy,
    providerID: .codex
)
private let additionalCodex = AccountProviderID(
    accountID: additionalAccountID,
    providerID: .codex
)

@Suite("Account settings presentation")
@MainActor
struct AccountSettingsPresentationTests {
    // MARK: Add Account gating

    @Test(
        arguments: [
            nil,
            .authenticationRequired,
            .unavailable,
            .failed,
            .schemaChanged
        ] as [ProviderAvailability?]
    )
    func addAccountIsHiddenUntilPrimaryIsConnected(
        availability: ProviderAvailability?
    ) {
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                additionState: .idle,
                primaryAvailability: availability,
                isPrimaryDisconnected: false
            ) == .hidden
        )
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                additionState: .blockedByOtherAddition,
                primaryAvailability: availability,
                isPrimaryDisconnected: false
            ) == .hidden
        )
    }

    @Test
    func connectedPrimaryOffersAddAccountAndKeepsBlockingVisible() {
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                additionState: .idle,
                primaryAvailability: .available,
                isPrimaryDisconnected: false
            ) == .offered
        )
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                additionState: .blockedByOtherAddition,
                primaryAvailability: .available,
                isPrimaryDisconnected: false
            ) == .blocked
        )
    }

    @Test
    func disconnectedPrimaryHidesAddAccountEvenWithAvailableUsage() {
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                additionState: .idle,
                primaryAvailability: .available,
                isPrimaryDisconnected: true
            ) == .hidden
        )
    }

    @Test(
        arguments: [nil, .authenticationRequired, .available]
            as [ProviderAvailability?]
    )
    func pendingAdditionControlsStayReachableWithoutConnectedPrimary(
        availability: ProviderAvailability?
    ) {
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                additionState: .waiting,
                primaryAvailability: availability,
                isPrimaryDisconnected: true
            ) == .pending
        )
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ProviderID.allCases,
        [nil, .authenticationRequired, .unavailable, .failed, .schemaChanged]
            as [ProviderAvailability?]
    )
    func availableAdditionalCannotStandInForPrimary(
        provider: ProviderID,
        primaryAvailability: ProviderAvailability?
    ) async {
        var providers = [SettingsAccountUsageProvider(
            id: provider,
            accountID: additionalAccountID,
            availability: .available
        )]
        if let primaryAvailability {
            providers.append(SettingsAccountUsageProvider(
                id: provider,
                accountID: .legacy,
                availability: primaryAvailability
            ))
        }
        let viewModel = UsageDashboardViewModel(providers: providers)
        await viewModel.refresh()

        #expect(viewModel.connectionStates[provider] == .available)
        #expect(!viewModel.isDisconnected(provider))
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                provider: provider,
                viewModel: viewModel,
                additionState: .idle
            ) == .hidden
        )
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                provider: provider,
                viewModel: viewModel,
                additionState: .waiting
            ) == .pending
        )
    }

    @Test(.timeLimit(.minutes(1)), arguments: ProviderID.allCases)
    func gatingTracksPrimaryDisconnectIndependentlyOfAvailableAdditional(
        provider: ProviderID
    ) async {
        let primary = AccountProviderID(accountID: .legacy, providerID: provider)
        let viewModel = UsageDashboardViewModel(providers: [
            SettingsAccountUsageProvider(
                id: provider,
                accountID: .legacy,
                availability: .available
            ),
            SettingsAccountUsageProvider(
                id: provider,
                accountID: additionalAccountID,
                availability: .available
            )
        ])
        await viewModel.refresh()
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                provider: provider,
                viewModel: viewModel,
                additionState: .idle
            ) == .offered
        )
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                provider: provider,
                viewModel: viewModel,
                additionState: .blockedByOtherAddition
            ) == .blocked
        )

        viewModel.disconnectAccountProvider(primary)

        #expect(viewModel.connectionStates[provider] == .available)
        #expect(!viewModel.isDisconnected(provider))
        #expect(viewModel.isDisconnected(primary))
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                provider: provider,
                viewModel: viewModel,
                additionState: .idle
            ) == .hidden
        )
        #expect(
            ProviderAccountAdditionAvailability.resolve(
                provider: provider,
                viewModel: viewModel,
                additionState: .waiting
            ) == .pending
        )
    }

    // MARK: Explicit account roles

    @Test
    func lonePrimaryStillProducesAnExplicitPrimaryRow() {
        let rows = ProviderAccountRowPresentation.rows(
            from: [
                ProviderAccountSettingsMetadata(
                    accountProviderID: primaryCodex,
                    provider: .codex,
                    label: AccountLabel.defaultValue,
                    isPrimary: true,
                    maskedIdentity: nil,
                    source: nil
                )
            ]
        )

        #expect(rows.map(\.role) == [.primary])
        #expect(rows.map(\.identity) == [primaryCodex])
        #expect(rows.first?.canRemove == false)
        #expect(rows.first?.showsCodexTier == true)
    }

    @Test
    func primaryLeadsAndAdditionalRowsKeepRegistryOrder() {
        let second = AccountProviderID(
            accountID: AccountID(),
            providerID: .codex
        )
        let rows = ProviderAccountRowPresentation.rows(
            from: [
                ProviderAccountSettingsMetadata(
                    accountProviderID: additionalCodex,
                    provider: .codex,
                    label: "Work",
                    isPrimary: false,
                    maskedIdentity: "w•••@example.com",
                    source: .keychain
                ),
                ProviderAccountSettingsMetadata(
                    accountProviderID: primaryCodex,
                    provider: .codex,
                    label: "Personal",
                    isPrimary: true,
                    maskedIdentity: nil,
                    source: nil
                ),
                ProviderAccountSettingsMetadata(
                    accountProviderID: second,
                    provider: .codex,
                    label: "Team",
                    isPrimary: false,
                    maskedIdentity: nil,
                    source: .keychain
                )
            ]
        )

        #expect(
            rows.map(\.identity) == [primaryCodex, additionalCodex, second]
        )
        #expect(rows.map(\.role) == [.primary, .additional, .additional])
        #expect(rows.map(\.canRemove) == [false, true, true])
        #expect(rows[1].maskedIdentity == "w•••@example.com")
    }

    @Test
    func codexTierIsOfferedOnlyForCodexAccounts() {
        let rows = ProviderAccountRowPresentation.rows(
            from: [
                ProviderAccountSettingsMetadata(
                    accountProviderID: AccountProviderID(
                        accountID: .legacy,
                        providerID: .openrouter
                    ),
                    provider: .openrouter,
                    label: AccountLabel.defaultValue,
                    isPrimary: true,
                    maskedIdentity: nil,
                    source: .keychain
                )
            ]
        )

        #expect(rows.map(\.showsCodexTier) == [false])
    }

    // MARK: Accessibility identity

    @Test
    func identifiersAreKeyedByProviderAndAccountNotAlias() {
        let legacy = "00000000-0000-0000-0000-000000000001"
        let added = additionalAccountID.rawValue

        #expect(
            AccountSettingsAccessibility.identifier(.row, for: primaryCodex)
                == "account-row-codex-\(legacy)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .role(.primary),
                for: primaryCodex
            ) == "account-role-primary-codex-\(legacy)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .role(.additional),
                for: additionalCodex
            ) == "account-role-additional-codex-\(added)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(.name, for: additionalCodex)
                == "account-name-codex-\(added)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .identity,
                for: additionalCodex
            ) == "account-identity-codex-\(added)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .editAlias,
                for: primaryCodex
            ) == "edit-alias-codex-\(legacy)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .aliasField,
                for: primaryCodex
            ) == "alias-field-codex-\(legacy)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .saveAlias,
                for: primaryCodex
            ) == "save-alias-codex-\(legacy)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .cancelAlias,
                for: primaryCodex
            ) == "cancel-alias-codex-\(legacy)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .removeAccount,
                for: additionalCodex
            ) == "remove-account-codex-\(added)"
        )
        #expect(
            AccountSettingsAccessibility.identifier(
                .codexTier,
                for: additionalCodex
            ) == "codex-tier-\(added)"
        )
    }

    @Test
    func accessibleNameCombinesRoleAliasAndMaskedIdentity() {
        #expect(
            AccountSettingsAccessibility.accessibleName(
                roleText: "Primary",
                label: "Work",
                maskedIdentity: "w•••@example.com"
            ) == "Primary, Work, w•••@example.com"
        )
    }

    @Test
    func missingIdentityIsNeverFabricated() {
        let name = AccountSettingsAccessibility.accessibleName(
            roleText: "Primary",
            label: "Work",
            maskedIdentity: nil
        )

        #expect(name == "Primary, Work")
        #expect(!name.contains("@"))
    }

    // MARK: Alias editing

    @Test
    func editingStartsFromTheSavedAliasAndCannotSaveUnchanged() {
        let edit = AccountAliasEdit(
            identity: primaryCodex,
            savedLabel: "Work"
        )

        #expect(edit.draft == "Work")
        #expect(!edit.canSave)
    }

    @Test(arguments: ["", "   ", "Work", "  Work  "])
    func blankOrUnchangedDraftCannotSave(draft: String) {
        var edit = AccountAliasEdit(
            identity: primaryCodex,
            savedLabel: "Work"
        )
        edit.draft = draft

        #expect(!edit.canSave)
    }

    @Test
    func trimmedDraftIsSavedThroughTheRegistry() throws {
        var edit = AccountAliasEdit(
            identity: additionalCodex,
            savedLabel: "Work"
        )
        edit.draft = "  Personal  "
        var renamed: [String] = []

        let outcome = edit.commit { label in renamed.append(label) }

        #expect(edit.canSave)
        #expect(outcome == .saved("Personal"))
        #expect(renamed == ["Personal"])
    }

    @Test(arguments: ["me@example.com", "team/one", "~home", "back\\slash"])
    func privacyInvalidDraftIsRejectedBeforeRenaming(draft: String) {
        var edit = AccountAliasEdit(
            identity: primaryCodex,
            savedLabel: "Work"
        )
        edit.draft = draft
        var renamed: [String] = []

        let outcome = edit.commit { label in renamed.append(label) }

        #expect(outcome == .rejected(.invalidLabel))
        #expect(renamed.isEmpty)
        #expect(edit.savedLabel == "Work")
        #expect(edit.draft == draft)
    }

    @Test
    func duplicateAliasRejectedByRegistryKeepsDraftAndSavedAlias() {
        var edit = AccountAliasEdit(
            identity: additionalCodex,
            savedLabel: "Work"
        )
        edit.draft = "Personal"

        let outcome = edit.commit { _ in
            throw ProviderAccountRegistryControllerError.invalidLabel
        }

        #expect(outcome == .rejected(.invalidLabel))
        #expect(edit.savedLabel == "Work")
        #expect(edit.draft == "Personal")
    }

    @Test
    func persistenceFailureIsReportedWithoutReplacingSavedAlias() {
        var edit = AccountAliasEdit(
            identity: additionalCodex,
            savedLabel: "Work"
        )
        edit.draft = "Personal"

        let outcome = edit.commit { _ in
            throw ProviderAccountRegistryControllerError
                .persistenceUnavailable
        }

        #expect(outcome == .rejected(.failed))
        #expect(edit.savedLabel == "Work")
    }

    @Test
    func blankDraftIsRejectedWithoutRenaming() {
        var edit = AccountAliasEdit(
            identity: primaryCodex,
            savedLabel: "Work"
        )
        edit.draft = "   "
        var renamed: [String] = []

        #expect(
            edit.commit { label in renamed.append(label) }
                == .rejected(.invalidLabel)
        )
        #expect(renamed.isEmpty)
    }
}

private struct SettingsAccountUsageProvider: UsageProvider {
    let id: ProviderID
    let accountID: AccountID
    let availability: ProviderAvailability

    func fetch(now: Date) async throws -> ProviderUsage {
        ProviderUsage(
            provider: id,
            planName: "Fixture",
            groups: [],
            availability: availability,
            updatedAt: now
        )
    }
}
