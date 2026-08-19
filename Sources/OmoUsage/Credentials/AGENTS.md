# CREDENTIALS

## OVERVIEW

The only place OmoUsage reads local secrets. Eight files map each provider's real on-disk/Keychain layout to one `DiscoveredCredential`, which carries the token plus the `CredentialSource` that produced it. `CredentialDiscovery` is referenced from about 30 Swift files, so its method signatures and error cases are effectively public API inside the app.

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Claude, Codex, Antigravity lookup; token persistence | `CredentialDiscovery.swift` |
| Cursor, Copilot, Devin, Grok, OpenCode, OpenRouter, Z.ai lookup | `AdditionalCredentialDiscovery.swift` |
| Claude Desktop cookie session path | `ClaudeDesktopSessionReader.swift`, `ClaudeCookieDatabase.swift`, `ClaudeSafeStorageKeychainReader.swift` |
| `/usr/bin/security` read/update | `SecurityKeychainReader.swift`, `SecurityKeychainWriter.swift` |
| Bounded subprocess and read-only `sqlite3` helpers | `LocalDataAccess.swift` |
| Claude/Codex/Antigravity precedence, plan parsing, redaction | `Tests/OmoUsageTests/CredentialDiscoveryTests.swift` |
| Every other provider, XDG handling, keychain failure isolation | `Tests/OmoUsageTests/AdditionalCredentialDiscoveryTests.swift` |

## CONVENTIONS

- Source precedence is per provider and tested, not global. Claude: `CLAUDE_CODE_OAUTH_TOKEN` env, then Keychain (`Claude Code-credentials`), then `~/.claude/.credentials.json`. Codex: file under `CODEX_HOME` first, then the `Codex Auth`/`Codex`/`OpenAI Codex` services in order. Antigravity is Keychain only (`gemini`/`antigravity`, base64 or raw). Copilot prefers the official env token over any broader stored credential.
- Claude and Codex remember parser failures in `candidateError` while trying valid later candidates. Precedence is provider-specific: a Copilot Keychain read failure intentionally terminates instead of widening to a broader credential.
- Three distinct errors, and callers branch on them: `.notFound` means nothing exists (the provider is dropped from the dashboard), `.malformed` means a store exists but is unusable, `.expired` means a valid store with a dead token. Grok skips an expired account when another account is still valid.
- `DiscoveredCredential.description` prints `<redacted>`. Route any diagnostic string that could contain a token through `SecretRedactor.redact(_:secrets:)`, which replaces longest secrets first so substrings can't leak.
- Writes are atomic: temp file created with `0o600` (and the directory forced to `0o700` for Grok), then `rename(2)`. Keychain updates go through `/usr/bin/security add-generic-password -U`, and the existing account is read back first so the update replaces the item instead of adding a second one.
- Every subprocess and SQLite query is bounded: `LocalDataAccess` waits with a semaphore, `terminate()`s on timeout, `SIGKILL`s after 0.25 s, and throws `.timedOut`. It also checks `Task.isCancelled` before and after the run. `sqlite3` is always invoked `-readonly`.
- Rewrites of another CLI's credential file preserve every unknown JSON field; Claude output uses sorted keys and a whole-millisecond `expiresAt` so the CLI keeps working after rotation.
- Tests inject `CredentialPaths`, an environment dictionary, and a `KeychainReading` stub, and run inside a UUID-namespaced temp home. New sources need the same injection seam; no test may touch the real home directory or Keychain.

## ANTI-PATTERNS

- Don't add a reflective or glob-based credential scan. Each source is named, provider-specific, and pinned by a test.
- Don't collapse `.notFound`, `.malformed`, and `.expired` into one error; the dashboard's remove-versus-retain behavior depends on the distinction.
- Don't let a Keychain read failure widen the search to a less specific service or account (see `copilotKeychainFailureDoesNotSelectBroaderCredential`).
- Don't write a credential file in place or with default permissions, and don't skip the read-back before a Keychain update.
- Don't run an unbounded `Process` or a writable SQLite connection here; use `LocalDataAccess`.
- Don't honor a relative `XDG_DATA_HOME`, and don't add nonstandard overrides such as `OPENCODE_DATA_DIR`; absolute XDG paths are supported and tested.
- Don't log, render, or put a token into a snapshot, and don't compile this folder into the mobile target.
