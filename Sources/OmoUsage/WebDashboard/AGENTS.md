# WEB DASHBOARD

## OVERVIEW

A distinct HTTP, access, and concurrency boundary serving sanitized usage plus narrowly scoped controls. The listener is loopback; optional remote access is private Tailscale Serve.

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Request parsing, route allowlist, nonce authorization | `WebDashboardServer.swift` (`WebDashboardHTTPRequest`, `WebDashboardRouter`) |
| Host/origin access policy | `WebDashboardAccess.swift` (`WebDashboardAccessMode`, `WebDashboardAccessGateway`) |
| Tailscale Serve lifecycle | `WebDashboardAccess.swift` (`TailscaleCLIService`, `TailscaleDashboardController`) |
| Snapshot/settings serialization and command handoff | `WebDashboardServer.swift` (`WebDashboardSnapshotStore`, `WebDashboardSettingsStore`, `WebDashboardCommandBridge`) |
| Listener lifecycle, connection cap, request deadline | `WebDashboardServer.swift` (`WebDashboardServer`, `NWWebDashboardListener`) |
| Bundle lookup and icon rendering | `WebDashboardAssets.swift` |
| HTML, CSS, localization, settings interactions | `../Resources/WebDashboard/index.html` |
| Router, lifecycle, privacy, and accessibility coverage | `Tests/OmoUsageTests/WebDashboardServerTests.swift` |

## CONVENTIONS

- `NWWebDashboardListener` binds only `127.0.0.1` (production port `7827`; fixture mode may override it). Optional remote access is private Tailscale Serve and does not change the listener binding.
- `WebDashboardAccessGateway` validates exact Host and POST Origin for local or validated lowercase `*.ts.net` access before `WebDashboardRouter` applies its explicit route allowlist. Unknown paths return 404; wrong methods return 405 and `Allow`.
- POST mutations require the per-launch nonce in `X-Omo-CSRF`. The nonce is substituted into the bundled template at load time.
- Settings payloads accept exact key sets only. The bundled client sends composite account/provider IDs: order must match the configured roster exactly and visibility must target a member. Provider-level commands remain compatibility paths. Web language uses its separate `WebDashboardLanguageStore`.
- Serve usage through `UsageSnapshotCodec` output and settings through `WebDashboardSettingsState`; both surfaces remain free of credentials, cookies, local paths, and diagnostics.
- Web commands cross `WebDashboardCommandBridge` to the existing `@MainActor` dashboard owner. Refresh completion increments `refreshRevision`; the web layer never fetches providers itself.
- Shared mutable server state uses `NSLock` and `@unchecked Sendable` only around audited lock-protected storage. Network callbacks stay off the main actor.
- Serialized requests are capped at 16 KiB, active connections at 32, and incomplete connections at 10 seconds. Stop/failure finishes all tracked connections.
- `WebDashboardAssets` checks packaged app resources before `Bundle.module`; an `.app` must not silently fall back to development resources.
- The client is one bundled HTML/CSS/JS file with system fonts, light/dark tokens, reduced-motion handling, and 44 pt controls. It fetches only same-origin endpoints.

## ANTI-PATTERNS

- Never bind wildcard, LAN, or public interfaces; do not add discovery, arbitrary tunneling, or Tailscale Funnel behavior. Tailscale Serve must remain private and gateway-controlled.
- Never serve arbitrary filesystem paths or derive a resource path from the request URL.
- Never weaken or bypass the mutation nonce, exact payload schemas, request cap, connection cap, or shutdown cleanup.
- Never expose API keys, tokens, cookies, credential state, local paths, or raw provider diagnostics in snapshot/settings responses.
- Never call `CredentialDiscovery`, `UsageProvider`, or provider HTTP from this folder; dispatch to the existing dashboard view model.
- Never add external scripts, fonts, analytics, cookies, or third-party asset requests to `index.html`.
- Never create a second refresh scheduler or optimistic state that can overwrite the authoritative control-state stores.
