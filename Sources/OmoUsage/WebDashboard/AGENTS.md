# WEB DASHBOARD

## OVERVIEW

Score 9 (code ratio 2, symbol density 2, export count 2, reference centrality 3): a distinct loopback HTTP and security boundary serving sanitized usage plus narrowly scoped controls.

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Request parsing, route allowlist, nonce authorization | `WebDashboardServer.swift` (`WebDashboardHTTPRequest`, `WebDashboardRouter`) |
| Snapshot/settings serialization and command handoff | `WebDashboardServer.swift` (`WebDashboardSnapshotStore`, `WebDashboardSettingsStore`, `WebDashboardCommandBridge`) |
| Listener lifecycle, connection cap, request deadline | `WebDashboardServer.swift` (`WebDashboardServer`, `NWWebDashboardListener`) |
| Bundle lookup and icon rendering | `WebDashboardAssets.swift` |
| HTML, CSS, localization, settings interactions | `../Resources/WebDashboard/index.html` |
| Router, lifecycle, privacy, and accessibility coverage | `Tests/OmoUsageTests/WebDashboardServerTests.swift` |

## CONVENTIONS

- Bind only `127.0.0.1:7827`. The listener is local device plumbing, not a LAN or public server.
- `WebDashboardRouter` is an explicit route allowlist. Unknown paths return 404; known paths with the wrong method return 405 and `Allow`.
- POST mutations require the per-launch nonce in `X-Omo-CSRF`. The nonce is substituted into the bundled template at load time.
- Settings payloads accept exact key sets only. Provider order must contain every `ProviderID` exactly once; language uses `WebDashboardLanguageStore`, separate from app language.
- Serve usage through `UsageSnapshotCodec` output and settings through `WebDashboardSettingsState`; both surfaces remain free of credentials, cookies, local paths, and diagnostics.
- Web commands cross `WebDashboardCommandBridge` to the existing `@MainActor` dashboard owner. Refresh completion increments `refreshRevision`; the web layer never fetches providers itself.
- Shared mutable server state uses `NSLock` and `@unchecked Sendable` only around audited lock-protected storage. Network callbacks stay off the main actor.
- Serialized requests are capped at 16 KiB, active connections at 32, and incomplete connections at 10 seconds. Stop/failure finishes all tracked connections.
- `WebDashboardAssets` checks packaged app resources before `Bundle.module`; an `.app` must not silently fall back to development resources.
- The client is one bundled HTML/CSS/JS file with system fonts, light/dark tokens, reduced-motion handling, and 44 pt controls. It fetches only same-origin endpoints.

## ANTI-PATTERNS

- Never bind wildcard, LAN, or public interfaces; do not add discovery, tunneling, or Tailscale Funnel behavior.
- Never serve arbitrary filesystem paths or derive a resource path from the request URL.
- Never weaken or bypass the mutation nonce, exact payload schemas, request cap, connection cap, or shutdown cleanup.
- Never expose API keys, tokens, cookies, credential state, local paths, or raw provider diagnostics in snapshot/settings responses.
- Never call `CredentialDiscovery`, `UsageProvider`, or provider HTTP from this folder; dispatch to the existing dashboard view model.
- Never add external scripts, fonts, analytics, cookies, or third-party asset requests to `index.html`.
- Never create a second refresh scheduler or optimistic state that can overwrite the authoritative control-state stores.
