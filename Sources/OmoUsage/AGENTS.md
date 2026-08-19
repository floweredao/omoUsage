# Sources/OmoUsage

## OVERVIEW

One source tree supports two apps: SwiftPM builds one macOS target, while XcodeGen selects a smaller shared subset for iOS/Catalyst. Folders are boundaries by convention, not modules, so review must keep credentials, providers, and AppKit views out of mobile-compiled files.

## STRUCTURE

```text
OmoUsageApp.swift        macOS entry, accessory NSApplication
AppDelegate.swift        composition root: stores -> providers -> view model -> popover
Credentials/             macOS only; env, files, Keychain, SQLite, CLI paths
Providers/               one adapter per provider + parsers + ProviderHTTP + fixtures
Dashboard/               UsageProvider protocol, view model, scheduler, layout
Models/                  shared Codable types, ProviderID roster and order
Settings/                UserDefaults-backed stores and ProviderSetup actions
Views/                   AppKit/SwiftUI popover and settings surfaces
Localization/            AppStringKey catalog, AppLanguage, provider text mapping
Sync/                    UsageSnapshotCodec + iCloud KVS store
Mobile/                  iOS/Catalyst entry and read-only view
Resources/ProviderIcons  bundled icon assets
```

## WHERE TO LOOK

- Composition happens once in `AppDelegate`: it builds the stores, asks `ProviderFactory.current` for the roster, injects persistence and `publishSnapshot` closures into `UsageDashboardViewModel`, then drives `UsageRefreshScheduler` and the popover. Nothing else constructs providers.
- The view model takes every dependency by closure or array in `init`, including `now`. Tests build it directly; don't reach for singletons inside it.
- `Sync/UsageSnapshotSync.swift` is the only bridge between halves. macOS encodes a `DashboardSnapshot` through `UsageSnapshotCodec` (version 1, 256 KB cap, millisecond dates) and Mobile decodes it. Any field added to `Models/` that reaches the codec becomes mobile-visible data, so treat model edits as a privacy decision.
- The minimum provider path is `Models/ProviderID.swift`, a new `Providers/*UsageProvider.swift`, `ProviderFactory`, and `Settings/ProviderSetup.swift`; roster and reliability tests complete the change. Display strings go through `Localization/`, never string literals in views.
- Parsing lives apart from fetching for the messy providers (`ClaudeUsageParser`, `CodexUsageParser`, `AntigravityUsageParser`); shared shapes are in `ProviderPayload` and `UsageParsing`. Put schema tolerance in the parser, HTTP concerns in the provider.

## CONVENTIONS

- `UsageProvider` is `Sendable` with a single `fetch(now:) async throws`; providers are value types and carry no mutable state. Cross-fetch state needs an actor, as `ClaudeRefreshCooldown` does.
- View model and views are `@MainActor`; `@Observable` state is `private(set)` and mutated only through intent methods. Injected dependencies are `@ObservationIgnored`.
- Time is injected (`now`, `sleep`) everywhere it matters. No `Date()` or `Task.sleep` inline in refresh paths.
- Localization keys are enum cases in `AppStringKey`, so a new string is a compile-time addition, not a lookup that can silently miss.
- Provider identity is `ProviderID`; order flows from the roster through `ProviderDisplayOrder.repaired` so persisted orders survive roster changes.

## ANTI-PATTERNS

- Don't import AppKit or reference `Credentials/` or `Providers/` from `Mobile/`, `Sync/`, `Models/`, `Localization/`, or `Settings/ProviderDisplayOrderStore.swift`; those shared paths compile for iOS.
- Don't widen `DashboardSnapshot` or `ProviderUsage` for UI convenience; those types cross into iCloud.
- Don't spawn refreshes outside the view model or add a second scheduler. Cancellation must leave state and timestamp untouched.
- Don't reintroduce `@MainActor` hops inside provider `fetch`; the fetch group runs off the main actor by design.
- Don't hardcode provider display text, colors, or ordering in `Views/`; they come from `Localization/`, `ProviderVisualStyle`, and the roster.
- Don't add a file without deciding its target membership in `project.yml`. SwiftPM building clean proves nothing about the mobile target.

Per-folder AGENTS.md files, where present, win over this file for anything inside them.
