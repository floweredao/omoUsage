# PROVIDERS

## OVERVIEW

Ten live adapters plus `FixtureUsageProvider` implement `UsageProvider` here. Live network adapters are `Sendable` structs built around `CredentialDiscovery` and `ProviderHTTP`; fixture and local OpenCode paths skip network work. Cross-refresh state lives outside provider values in the `ClaudeRefreshCooldown` actor.

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Register a provider in the live roster | `ProviderFactory.current` (order must equal `ProviderID.allCases`) |
| Status-code to error mapping | `ProviderHTTP.data(for:provider:)`, `ProviderTransportError` |
| Pull a number/date/string out of a payload | `ProviderPayload` (multi-path lookups), `UsageJSON` (type coercion) |
| Percent, reset text, money formatting | `ProviderPayload.remainingPercent`, `.resetText`, `.money` |
| Big schema-heavy parsing | `ClaudeUsageParser`, `AntigravityUsageParser`, `CodexUsageParser` |
| Fixture-mode payloads | `FixtureUsageProvider` (Claude/Codex/Antigravity go through the real parsers) |

## CONVENTIONS

- Add a provider by touching `ProviderID`, its implementation, `ProviderFactory`, `ProviderSetup`, and `ProviderRosterTests`, then add a provider reliability suite. The roster tests fail loudly when identity, registration, or API-key setup drifts.
- Never call `URLSession` directly. Route everything through `http.data(for:provider:)` so 401/403 becomes `authenticationRequired`, other non-2xx becomes `requestFailed(id, status)`, and a non-HTTP response becomes `invalidResponse`. The dashboard's remove-vs-retain behavior depends on that distinction.
- Set `timeoutInterval` explicitly per request; existing providers use 10 or 15 seconds.
- Prefer `ProviderPayload.value(_:paths:)` with several candidate key paths over one hard-coded path. Provider schemas change under us; first match wins.
- Throw `UsageParsingError.invalidPayload` or `ProviderTransportError.invalidResponse(id)` when a payload yields no meaningful meter. An empty `ProviderUsage` is worse than a failure.
- `UsageJSON.number` rejects `CFBoolean` on purpose, and `ProviderPayload.date` divides by 1000 above 10_000_000_000 to absorb millisecond epochs. Reuse them instead of reimplementing.
- Meter and group IDs are stable machine values (`"claude.session"`, `"opencode-rolling"`). Titles and credit strings are Korean display text baked in at parse time.
- Secondary endpoints that only enrich the result (Grok settings, Z.ai subscriptions) are fetched with `async let` and `try?`, so a failure there can't sink the primary meter.
- A provider that authenticates fine but has no plan returns `availability: .unavailable` rather than throwing. See the Z.ai "no active coding plan" branch.

## CLAUDE AND OPENCODE EXCEPTIONS

- Claude is the only multi-source usage adapter: OAuth usage first, then Claude Desktop session cookies, then cached `plan-usage-history.json`. Cached history is allowed only when no credential was ever discovered (`allowsCachedHistory`), never after a failed refresh.
- Token refresh posts to `platform.claude.com` with the `claude-cli/...` User-Agent. That agent string is load-bearing: the endpoint throttles unknown clients with a 429 before validating the grant. Rotated tokens are written back through `discovery.persistClaudeCredential` so Claude Code and this app share one chain.
- Every OAuth token-refresh failure calls `ClaudeRefreshCooldown.recordFailure`, blocking another rotation attempt for 10 minutes. The dashboard ticks every minute, so skipping the cooldown gets the whole client rate-limited.
- OpenCode is the only provider constructed without an injected `http` at the factory. A token of the literal string `"local"` means read SQLite (`opencode*.db`) via `LocalDataAccess` and report 30-day spend as credit text; anything else hits the Zen Go usage API.
- Cancellation is rethrown as `CancellationError` before any fallback branch. Don't let a cancelled task fall through to a lower-fidelity source.

## TEST SURFACES

- `Tests/OmoUsageTests/<Provider>ReliabilityTests.swift` is the per-provider contract: a private `URLProtocol` on an `ephemeral` `URLSessionConfiguration`, a UUID-namespaced temp home, and a fixed `now`. Add a provider, add one of these.
- `UsageParsingTests` covers the three standalone parsers on raw JSON; `ProviderRosterTests` pins order, factory registration, and which providers accept API keys; `AdditionalUsageProviderTests` covers the smaller adapters.
- Assert on captured requests (headers, body via `requestBodyData`) as well as the parsed result. Header regressions are the usual live breakage.

## ANTI-PATTERNS

- Don't swallow a transport error into a default/zero usage value. Missing auth must stay distinguishable from a transient 500.
- Don't reach for `.shared` sessions or real network calls in tests; the URLProtocol seam exists so the suite runs offline.
- Don't add sleeps or retry loops inside a provider. Periodic attempts come from `UsageRefreshScheduler`; Claude's single rotate-once retry is deliberate, not a pattern to copy.
- Don't log tokens, cookies, or account IDs. The Claude logger prints error descriptions and status codes only.
- Don't let a parser bake in `Date()`; every entry point takes `now` so fixtures stay deterministic.
