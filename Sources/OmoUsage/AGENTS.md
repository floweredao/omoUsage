# Sources/OmoUsage

## OVERVIEW

The macOS executable owns credentials, provider calls, diagnostics, AppKit
lifecycle, and the dashboard server. The iOS/Catalyst companion is limited to
the two files under `Mobile/` and consumes `OmoUsageCore` snapshots only.

## STRUCTURE

```text
OmoUsageApp.swift        single-instance gate and accessory NSApplication entry
AppDelegate.swift        composition root and macOS lifecycle
Credentials/             macOS credential discovery and redacted diagnostics
Providers/               provider adapters, parsing, HTTP, and fixtures
Dashboard/               refresh owner, ordering, scheduler, and layout
Settings/                account registry, setup/login, keys, and preferences
Views/                   popover, Side Notch, settings, and accessibility UI
WebDashboard/            loopback listener, access gateway, router, and assets
Mobile/                  read-only iOS/Catalyst snapshot UI
```

## WHERE TO LOOK

- `OmoUsageApp.swift` claims the single-instance lock, sets accessory policy,
  installs secondary-launch activation, and runs `AppDelegate`.
- `AppDelegate.swift` is the composition root. It builds account stores and
  account-scoped providers, injects them into `UsageDashboardViewModel`, owns
  the status item/popover and Side Notch controller, starts refresh scheduling,
  and wires the web command bridge.
- `Dashboard/UsageDashboardViewModel.swift` is the only refresh owner. Keep
  provider fetches, cancellation, last-good retention, ordering, visibility,
  and published control state here.
- `Settings/ProviderAccountRegistryController.swift` and
  `ProviderMutationCoordinator.swift` govern account identity, durable registry
  recovery, per-account ordering, and visibility. Do not collapse account
  identity into the provider enum.
- `Settings/ProviderSetup.swift` owns official app/CLI setup and login actions;
  `ProviderAPIKeyStore.swift` owns API-key persistence for supported providers.
- `Views/` contains the native popover and Side Notch surfaces. Presentation
  style, settings actions, provider ordering, account aliases, and accessibility
  identifiers must remain consistent across both surfaces.
- `WebDashboard/` serves sanitized snapshots and delegates commands to the
  existing main-actor dashboard owner. The listener binds loopback; optional
  private Tailscale Serve exposure is handled by its access/controller layer.
- `../OmoUsageCore/Sync/UsageSnapshotSync.swift` is the only macOS/mobile data
  bridge. Treat every field reaching the codec as a privacy decision.

## CONVENTIONS

- Providers are `Sendable` value types with `fetch(now:) async throws`; mutable
  cross-fetch state belongs in an actor.
- UI and observable state are `@MainActor`; inject time and dependencies for
  deterministic tests. Never add a second refresh scheduler.
- Provider identity uses `ProviderID`; account identity uses `AccountProviderID`.
  Persisted orders must be repaired against the current roster.
- Display strings and visual tokens come from localization/style catalogs.

## ANTI-PATTERNS

- Do not initialize provider stores or UI before the single-instance owner claim.
- Do not activate both Popover and Side Notch simultaneously; close the prior
  surface before enabling its replacement, using the same dashboard state.
- Do not persist Side Notch selection or revealed state across launches.
- Do not let secondary launches construct another refresh owner or listener.
