# Sources/OmoUsage

## OVERVIEW

The macOS executable and two-file Mobile UI consume the separate
`Sources/OmoUsageCore` library. Core is the enforceable shared boundary;
credentials, providers, diagnostics, SQLite, Security, and AppKit stay in the
macOS executable.

## STRUCTURE

```text
OmoUsageApp.swift        macOS entry, accessory NSApplication
AppDelegate.swift        composition root: stores -> providers -> view model -> popover
Credentials/             macOS only; env, files, Keychain, SQLite, CLI paths
Providers/               one adapter per provider + parsers + ProviderHTTP + fixtures
Dashboard/               UsageProvider protocol, view model, scheduler, layout
Settings/                UserDefaults-backed stores and ProviderSetup actions
Views/                   AppKit/SwiftUI popover and settings surfaces
../OmoUsageCore/         shared models, localization, schema-v4 snapshot sync
WebDashboard/            loopback HTTP server, sanitized snapshot/control surface
Mobile/                  iOS/Catalyst entry and read-only view
Resources/ProviderIcons  bundled icon assets
Resources/WebDashboard  single bundled HTML/CSS/JS dashboard
```

## WHERE TO LOOK

- Composition happens once in `AppDelegate`: it builds stores, providers, `UsageDashboardViewModel`, refresh scheduling, the native popover, and the loopback web server. Nothing else constructs providers or owns refreshes.
- The view model takes every dependency by closure or array in `init`, including `now`. Tests build it directly; don't reach for singletons inside it.
- `../OmoUsageCore/Sync/UsageSnapshotSync.swift` is the only bridge between halves. macOS encodes schema v4 through the privacy-minimized DTO; Mobile decodes versions 1–4. Any Core model field that reaches the codec is a privacy decision.
- `WebDashboard/WebDashboardServer.swift` owns HTTP parsing, route authorization, settings commands, listener lifecycle, and synchronized snapshot/settings stores. `Resources/WebDashboard/index.html` is its bundled zero-dependency client.
- The minimum provider path is `Models/ProviderID.swift`, a new `Providers/*UsageProvider.swift`, `ProviderFactory`, and `Settings/ProviderSetup.swift`; roster and reliability tests complete the change. Display strings go through `Localization/`, never string literals in views.
- Parsing lives apart from fetching for the messy providers (`ClaudeUsageParser`, `CodexUsageParser`, `AntigravityUsageParser`); shared shapes are in `ProviderPayload` and `UsageParsing`. Put schema tolerance in the parser, HTTP concerns in the provider.

## CONVENTIONS

- `UsageProvider` is `Sendable` with a single `fetch(now:) async throws`; providers are value types and carry no mutable state. Cross-fetch state needs an actor, as `ClaudeRefreshCooldown` does.
- View model and views are `@MainActor`; `@Observable` state is `private(set)` and mutated only through intent methods. Injected dependencies are `@ObservationIgnored`.
- Time is injected (`now`, `sleep`) everywhere it matters. No `Date()` or `Task.sleep` inline in refresh paths.
- Localization keys are enum cases in `AppStringKey`, so a new string is a compile-time addition, not a lookup that can silently miss.
- Provider identity is `ProviderID`; order flows from the roster through `ProviderDisplayOrder.repaired` so persisted orders survive roster changes.

## ANTI-PATTERNS

- Don't import AppKit or reference `Credentials/`, `Providers/`, or
  `Diagnostics/` from `Mobile/` or `Sources/OmoUsageCore`; Core compiles for
  macOS, iOS, and Catalyst.
- Don't widen `DashboardSnapshot` or `ProviderUsage` for UI convenience; those types cross into iCloud.
- Don't spawn refreshes outside the view model or add a second scheduler. Cancellation must leave state and timestamp untouched.
- Don't reintroduce `@MainActor` hops inside provider `fetch`; the fetch group runs off the main actor by design.
- Don't hardcode provider display text, colors, or ordering in `Views/`; they come from `Localization/`, `ProviderVisualStyle`, and the roster.
- Don't let `WebDashboard/` call providers or credentials directly; it delegates commands to the existing main-actor view model and serves sanitized snapshots.
- Don't add a file without deciding its target membership in `project.yml`. SwiftPM building clean proves nothing about the mobile target.

Per-folder AGENTS.md files, where present, win over this file for anything inside them.
