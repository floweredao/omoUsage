# SETTINGS AND ACCOUNT TRANSACTIONS

## OVERVIEW

Native account setup, durable registry/credential mutations, preferences, and macOS update lifecycle.

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Setup flows and connection completion | `ProviderSetup.swift` |
| In-app sign-in clients and the shared loopback runner | `ClaudeBrowserAuthentication*.swift`, `CodexBrowserAuthentication.swift`, `OpenRouterBrowserAuthentication.swift`, `CopilotDeviceAuthentication.swift` |
| Registry schema, validation, backup recovery | `ProviderAccountStore.swift` |
| Account add/remove/rename/order and provider rebuild | `ProviderAccountRegistryController.swift` |
| Advisory lock, intent journal, interrupted mutation recovery | `ProviderMutationCoordinator.swift` |
| Exact Keychain items, staging, legacy API-key migration | `ProviderAPIKeyStore.swift` |
| Presentation and account multiplier preferences | `DashboardPresentationStyleStore.swift`, `CodexPlanMultiplierStore.swift` |
| Packaged-app Sparkle updater | `AppUpdateController.swift` |

## CONVENTIONS

- Registry storage retains the compatibility path `openusage/accounts.json` under absolute `XDG_CONFIG_HOME`, otherwise `~/.config`. Do not rename it casually.
- Account mutations run under `ProviderMutationCoordinator`'s advisory lock; reload stale registry state inside the lock before committing.
- Durable writes use private directories/files, fsync, rename, and readback. Journal phases track intent, staging, registry commit, secret promotion/removal, and completion.
- Journals record registry snapshots and digests, never credential values. Recovery must converge to a consistent old or new state.
- API keys resolve from environment, exact account-qualified Keychain item, then legacy file. An exact Keychain read failure must not fall through to plaintext.
- Stage a new secret before registry commit; promote only after persistence succeeds. Retain legacy files until committed migration cleanup; failed cleanup remains retryable.
- The legacy account cannot be removed. API-key account setup covers OpenCode Go, OpenRouter, and Z.ai.
- Captured companion credentials are prepared by the setup caller; the registry controller persists the supplied capture rather than reading live credentials itself.
- Labels are trimmed/sanitized, nonempty, and case-insensitively unique per provider. Persist order and visibility using composite account/provider IDs.
- In-app sign-in (Claude, Codex, Copilot, Devin, Kiro, OpenRouter) stores a grant only after the provider's token or key exchange succeeds; cancelled, denied, or timed-out sign-ins leave the account's credential unchanged.
- Official app/CLI launch is a pending connection. Only the subsequent available usage result completes authentication.
- `AppUpdateController` initializes Sparkle only in a packaged `.app`; unavailable update state is expected for a plain SwiftPM executable.

## ANTI-PATTERNS

- Do not bypass the transaction coordinator for a credential-plus-registry change or delete legacy data before convergence.
- Do not broaden a failed account lookup to another account or shared legacy credential.
- Do not mark browser/help navigation or a successful process launch as authenticated.
- Do not store revealed Side Notch state or selected detail as a presentation preference.

## VERIFICATION

- Use `ProviderMutationRecoveryTests`, `ProviderAccountRecoveryTests`, and `ProviderKeyMigrationTests` for interruption and rollback boundaries.
- Use `ProviderAccountRegistryControllerTests`, `ProviderAPIKeyStoreTests`, and `ProviderSetupTruthfulnessTests` for account identity and setup behavior.
