# TEST SUITE KNOWLEDGE BASE

## OVERVIEW

One SwiftPM test target, 74 Swift files, all Swift Testing (`import Testing`,
`@testable import OmoUsage`, and public `OmoUsageCore` where required). No
XCTest, live network, or real Keychain. Every provider gets a
`*ReliabilityTests.swift` file that pins its real-world failure modes; shared
behavior lives in dashboard, account-state, credential, parsing, sync,
security, release, and web-dashboard suites.

## WHERE TO LOOK

| Task | File |
|------|------|
| Refresh ordering, cancellation, connection states | `UsageDashboardViewModelTests.swift` |
| Last-good retention under transient failure | `LastGoodUsageReliabilityTests.swift` |
| Account migration, multi-account refresh/order | `AccountStateMigrationAndSnapshotTests.swift`, `MultiAccountRefreshTests.swift` |
| Credential precedence, malformed/expired sources | `CredentialDiscoveryTests.swift`, `AdditionalCredentialDiscoveryTests.swift` |
| One provider's HTTP request/parse/failure path | `<Provider>ReliabilityTests.swift` |
| Claude OAuth refresh and desktop-session fallback | `ClaudeTokenRefreshTests.swift`, `ClaudeDesktopRefreshTests.swift`, `ClaudeLiveFailureTests.swift` |
| Payload schema tolerance | `UsageParsingTests.swift` |
| Visual tokens and layout invariants from `DESIGN.md` | `DashboardVisualContractTests.swift`, `DashboardLayoutTests.swift` |
| Timestamp text, Korean strings | `RefreshBehaviorTests.swift`, `LocalizationTests.swift` |
| Loopback HTTP routes, nonce checks, request limits, web tokens | `WebDashboardServerTests.swift` |
| Reading a request body regardless of stream vs data | `URLRequestTestSupport.swift` |

## CONVENTIONS

- `@Suite struct`, `@Test func`, `#expect` for assertions and `try #require` to unwrap. Suite names are bare unless a label adds meaning (`@Suite("Provider disconnection store")`).
- Every date is a literal epoch: `Date(timeIntervalSince1970: 1_785_675_000)`, usually a `private let now` on the suite. Pass `now:` into `fetch(now:)` and inject `now: { now }` into the view model. Derive other instants with `addingTimeInterval`.
- Time formatting tests pin `TimeZone(secondsFromGMT: 0)!` explicitly.
- HTTP is faked with a per-file `private final class ...URLProtocol: URLProtocol` installed via `URLSessionConfiguration.ephemeral` + `protocolClasses`, then handed to `ProviderHTTP(session:)`. Recorders that capture headers or bodies are `reset()` at test start; register/unregister pairs use `defer`.
- Keychain is a `private struct ...Keychain: KeychainReading` stub, or a recording class when writes matter. Filesystem fixtures go under `FileManager.default.temporaryDirectory.appending(path: "Name-\(UUID().uuidString)")` with `defer { try? FileManager.default.removeItem(at: directory) }`.
- `UserDefaults(suiteName:)` with a UUID name for isolated store tests; suites that must touch `UserDefaults.standard` or shared recorder state are marked `@Suite(.serialized)` (see `UsageParsingTests`, `CodexReliabilityTests`, `ClaudeTokenRefreshTests`).
- Main-actor state is exercised with `@Test @MainActor`. Concurrency is ordered by explicit synchronization: `actor` gates with `withCheckedContinuation`, `actor` counters, and `AsyncStream.makeStream()` signals awaited for the next element.
- Test-only types are `private` and prefixed per file so names never collide across the target.

## ANTI-PATTERNS (THIS SUITE)

- Never use wall-clock time, `Task.sleep`, or polling to wait for async behavior. Inject fixed epochs and await the stream event or continuation that the code under test actually signals.
- Never let a test reach the real network, the real Keychain, `~/`, or a provider CLI. Inject `CredentialPaths`, `environment:`, `keychain:`, and a stubbed session instead.
- Never share mutable fixture state across a non-`.serialized` suite, and never leave a temp directory or registered `URLProtocol` behind.
- Never snapshot prose or assert incidental fragments. Localization tests may pin exact shipped-copy equality; visual tests pin `*VisualTokens` values, not descriptions.
- Never print or expect real tokens; fixtures use obvious placeholders like `header-test-token`.
- Do not add XCTest, snapshot images, or a shared global helper file. Per-file private fixtures are the pattern.

## COMMANDS

```bash
swift test                                        # full target
swift test --filter ClaudeReliabilityTests        # one suite
swift test --filter ClaudeReliabilityTests/oauthUsageRequestIncludesRequiredHeaders
```
