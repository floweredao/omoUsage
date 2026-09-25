# CREDENTIALS

## OVERVIEW

Local provider discovery is split between `CredentialDiscovery.swift` (Claude, Codex, Antigravity, persistence) and `AdditionalCredentialDiscovery.swift` (Cursor, Copilot, Devin, Grok, OpenCode, OpenRouter, Z.ai), with dedicated Claude Desktop readers and Security-framework Keychain facades. Account transactions and API-key staging are owned by `../Settings/`.

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Claude, Codex, Antigravity lookup and account snapshots | `CredentialDiscovery.swift` |
| Other provider lookup and XDG/OpenCode roots | `AdditionalCredentialDiscovery.swift` |
| Claude Desktop cookies and safe-storage authorization | `ClaudeDesktopSessionReader.swift`, `ClaudeCookieDatabase.swift`, `ClaudeSafeStorageKeychainReader.swift` |
| Security-framework Keychain read/update | `SecurityKeychainReader.swift`, `SecurityKeychainWriter.swift` |
| Bounded subprocess and read-only sqlite3 | `LocalDataAccess.swift`, `BoundedProcessRunner.swift` |
| Discovery and precedence tests | `Tests/OmoUsageTests/CredentialDiscoveryTests.swift`, `AdditionalCredentialDiscoveryTests.swift` |

## CONVENTIONS

- Precedence is provider-specific and tested. Claude uses environment, Claude Keychain services, then `~/.claude/.credentials.json`; Codex uses `CODEX_HOME` then its ordered Keychain services; Antigravity is Keychain-only; Copilot prefers its official environment token.
- A nonlegacy account reads only its app-owned account/provider snapshot. Never fall back to legacy or another account's credential. Provider account references are distinct from the app's UUID `AccountID`.
- `.notFound`, `.malformed`, and `.expired` are distinct. Dashboard behavior depends on preserving them. Grok may skip an expired candidate when another account candidate remains valid.
- Claude and Codex retain candidate parse failures while trying later valid candidates. A Copilot Keychain read failure intentionally terminates discovery rather than widening to a broader credential.
- `DiscoveredCredential.description` is redacted. Pass diagnostics that could contain a secret through `SecretRedactor.redact`, which replaces longer secrets first.
- File writes are atomic with restrictive permissions. Preserve unknown JSON fields when updating another CLI's credential file; Claude writes sorted keys and millisecond `expiresAt`.
- Keychain updates use the Security framework facade. Read the existing item and update its persistent identity rather than invoking `/usr/bin/security` or creating duplicates.
- Subprocess and SQLite work is bounded, cancellation-aware, and read-only. `LocalDataAccess` invokes `/usr/bin/sqlite3 -readonly` and terminates timed-out work.
- Tests inject credential paths, environment values, Keychain facades, and temporary homes. Never touch the real home, Keychain, credentials, or network in tests.

## PATH AND STORAGE RULES

- Honor only named provider-specific sources. For OpenCode, `OPENCODE_DATA_DIR` is a supported override when absolute; otherwise use absolute `XDG_DATA_HOME` or the platform default. Reject relative overrides and do not invent additional directory variables.
- Claude Desktop history is a lower-fidelity fallback only when no credential was ever discovered. It must not mask a failed authenticated refresh.
- Claude protected Keychain access may require the explicit authorization flow in `SecurityKeychainReader`; keep interaction policy separate from ordinary noninteractive reads.

## ANTI-PATTERNS

- Do not add reflective or broad glob-based credential scans. Each source is named, provider-specific, and pinned by tests.
- Do not collapse discovery errors or widen a failed Keychain lookup to a less-specific service/account.
- Do not write credential files in place or with default permissions, and do not skip Keychain read-back before update.
- Do not run unbounded processes, writable SQLite connections, or relative `XDG_DATA_HOME`/`OPENCODE_DATA_DIR` paths.
- Do not log, render, or place tokens in snapshots, and do not compile this folder into the mobile target.
