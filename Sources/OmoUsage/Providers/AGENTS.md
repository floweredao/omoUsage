# PROVIDERS

## OVERVIEW

Ten live adapters and `FixtureUsageProvider` implement `UsageProvider` here. Live adapters are `Sendable` values using `CredentialDiscovery` and, for network calls, `ProviderHTTP`; OpenCode can read local SQLite data. Account-scoped construction is selected by `ProviderFactory` from registry references. Cross-refresh Claude state lives in the `ClaudeRefreshCooldown` actor.

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Register provider identity and live construction | `Sources/OmoUsageCore/Models/ProviderID.swift`, `ProviderFactory.swift` |
| Endpoint headers, method, safety, schema revision | `ProviderContractCatalog.swift`, `ProviderContract.swift` |
| Transport mapping, retries, timeout, response limits | `ProviderHTTP.swift`, `ProviderRetryPolicy.swift` |
| Payload paths and type coercion | `ProviderPayload.swift`, `UsageParsing.swift` |
| Percent, reset text, money formatting | `ProviderPayload.remainingPercent`, `.resetText`, `.money` |
| Large schema parsers | `ClaudeUsageParser.swift`, `AntigravityUsageParser.swift`, `CodexUsageParser.swift` |
| Fixture behavior | `FixtureUsageProvider.swift` |
| Claude cooldown and token rotation | `ClaudeUsageProvider.swift`, `ClaudeRefreshCooldown.swift` |

## CONVENTIONS

- Adding a provider requires `ProviderID`, its adapter, `ProviderFactory`, `ProviderSetup`, roster/API-key tests, a contract entry, and reliability coverage.
- Never call `URLSession` directly from an adapter. Use the injected `ProviderHTTP` endpoint boundary. It validates the contract, maps 401/403 to `authenticationRequired`, other non-2xx to `requestFailed`, and non-HTTP responses to `invalidResponse`.
- Set `timeoutInterval` explicitly on each request. Shared retry policy handles bounded attempts, deadlines, safe-method rules, `Retry-After`, backoff, and maximum response bytes; do not add provider-local retry loops.
- Prefer `ProviderPayload.value(_:paths:)` with candidate paths. Reject payloads with no meaningful meter using `UsageParsingError.invalidPayload` or the appropriate transport error.
- `UsageJSON.number` rejects booleans, and `ProviderPayload.date` accepts millisecond epochs above `10_000_000_000`; reuse these helpers.
- Meter and group IDs are stable machine values. Korean titles and credit strings are display text produced at the provider boundary.
- Secondary enrichment requests (Grok settings and Z.ai subscription) use `async let` and `try?`; enrichment failure must not remove the primary meter.
- Successful authentication with no plan is represented as `availability: .unavailable` where the adapter defines that case, including Z.ai.
- Every adapter carries `accountID` and `accountLabel`; discovery and cooldown must remain account-scoped.

## CLAUDE AND OPENCODE EXCEPTIONS

- Claude tries OAuth usage, then Desktop session cookies, then cached `plan-usage-history.json`. Cached history is allowed only when no credential was discovered, never after a failed refresh. Cancellation is rethrown before fallback.
- Claude token refresh uses the required `claude-cli/...` User-Agent, sends only `grant_type`, `client_id`, and `refresh_token`, and persists rotated credentials through `CredentialDiscovery`. `ClaudeRefreshCoordinator` runs one exchange per account at a time. Every refresh failure records the account in `ClaudeRefreshCooldown` (ten minutes, or a clamped `Retry-After` for a token 429); while it blocks, a still-valid token is used and an expired one reports `requestFailed(429)` so last-good usage stays. Only a 400 `invalid_grant` means login is required.
- OpenCode is constructed without an injected `http` at the factory boundary. The literal token `local` reads `opencode*.db` through `LocalDataAccess` and reports 30-day spend; other tokens call the Zen Go endpoint.

## TEST SURFACES

- Per-provider reliability suites use private `URLProtocol`, ephemeral sessions, injected credential paths, UUID-namespaced homes, and fixed dates. Assert captured headers and request bodies as well as parsed usage.
- `ProviderContractTests.swift` pins every provider endpoint contract. `ProviderHTTPRetryTests.swift` covers retries, replayable bodies, deadlines, and response limits. `ProviderRosterTests.swift`, `UsageParsingTests.swift`, `AdditionalUsageProviderTests.swift`, and `MultiAccountRefreshTests.swift` cover roster, parsers, smaller adapters, and account isolation.

## ANTI-PATTERNS

- Do not turn transport or parsing failures into zero usage; missing authentication must remain distinguishable from transient failure.
- Do not use `.shared` sessions or real network calls in tests; use the URLProtocol seam.
- Do not log tokens, cookies, account IDs, or raw provider payloads. Do not bake `Date()` into parsers; accept `now`.
