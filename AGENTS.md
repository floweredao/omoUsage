# PROJECT KNOWLEDGE BASE

**Generated:** 2026-08-30T12:00:51Z
**Commit:** 1371442
**Branch:** main

## OVERVIEW

OmoUsage is a native Swift 6 menu-bar app that aggregates remaining quota from ten coding-AI providers. The macOS app owns credentials, provider calls, and a loopback web dashboard; an iOS/Catalyst companion receives only sanitized usage snapshots through private iCloud key-value storage.

## STRUCTURE

```text
.
|-- Sources/OmoUsage/          # macOS executable plus the two-file Mobile UI
|   |-- Credentials/           # Local environment, file, Keychain, SQLite, and CLI discovery
|   |-- Providers/             # Provider HTTP adapters, payload parsing, and fixture providers
|   |-- Dashboard/             # Refresh orchestration, ordering, and provider protocol
|   |-- Settings/              # Provider setup actions and local API-key storage
|   |-- Views/                 # macOS popover and settings UI
|   |-- WebDashboard/          # Loopback HTTP router, command bridge, and bundled web assets
|   `-- Mobile/                # iOS/Catalyst entry point and read-only UI
|-- Sources/OmoUsageCore/      # One enforced mobile-safe shared library
|   |-- Models/                # Typed metrics, freshness, provider identity
|   |-- Localization/          # Korean-default typed string catalog
|   `-- Sync/                  # Schema-v4 private iCloud codec/store
|-- Tests/OmoUsageTests/       # Swift Testing suites and provider reliability fixtures
|-- Config/                    # Plists and matching macOS/mobile iCloud entitlements
|-- Scripts/                   # Local app packaging, icon generation, and manual QA tools
|-- Package.swift              # SwiftPM macOS build and test definition
|-- project.yml                # XcodeGen source for macOS plus iOS/Catalyst targets
`-- DESIGN.md                  # Binding visual, interaction, accessibility, and privacy contract
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Trace macOS startup | `OmoUsageApp.swift`, `AppDelegate.swift` | Manual `NSApplication` lifecycle; no SwiftUI `App` on macOS |
| Add or reorder a provider | `Models/ProviderID.swift`, `Providers/ProviderFactory.swift` | Roster order must stay aligned with setup and tests |
| Change credential lookup | `Credentials/` | Preserve source precedence, typed failures, and redaction |
| Change provider requests/parsing | `Providers/` | Shared boundaries are `ProviderHTTP`, `UsageJSON`, and `ProviderPayload` |
| Change refresh/failure behavior | `Dashboard/UsageDashboardViewModel.swift` | Concurrent fetch, cancellation, last-good retention |
| Change provider accounts | `Settings/ProviderAccountStore.swift`, `ProviderAccountRegistryController.swift` | Registry changes rebuild account-scoped providers and repair persisted order |
| Change provider setup/login | `Settings/ProviderSetup.swift` | Only official apps/CLIs; OpenRouter and Z.ai accept API keys |
| Change desktop UI | `Views/`, `AppDelegate.swift`, `DESIGN.md` | Native 320 pt popover and system appearance |
| Change web dashboard | `WebDashboard/`, `Resources/WebDashboard/index.html` | Loopback-only sanitized surface; mutations require a launch nonce |
| Change mobile data/UI | `Sources/OmoUsageCore/`, `Sources/OmoUsage/Mobile/` | Mobile target depends only on Core and its two UI files |
| Change target membership | `project.yml` | Regenerate the checked-in Xcode project afterward |
| Add regression coverage | `Tests/OmoUsageTests/` | Swift Testing, injected files/Keychain/URLProtocol |

## CODE MAP

LSP document symbols supplied declaration shape and semantic spot checks. `Refs` is the number of Swift files containing the symbol; ast-grep was unavailable during this refresh.

| Symbol | Type | Location | Refs | Role |
|--------|------|----------|------|------|
| `OmoUsageApp.main` | entry point | `Sources/OmoUsage/OmoUsageApp.swift:5` | 1 | Starts the accessory `NSApplication` |
| `AppDelegate` | class | `Sources/OmoUsage/AppDelegate.swift:107` | 2 | macOS composition root and popover lifecycle |
| `ProviderFactory.current` | factory | `Sources/OmoUsage/Providers/ProviderFactory.swift:3` | 4 | Registers account-scoped live providers or fixture providers |
| `CredentialDiscovery` | struct | `Sources/OmoUsage/Credentials/CredentialDiscovery.swift:77` | 33 | Central local credential boundary |
| `UsageProvider` | protocol | `Sources/OmoUsage/Dashboard/UsageProvider.swift:3` | 21 | `Sendable` async provider contract for live and fixture adapters |
| `UsageDashboardViewModel` | class | `Sources/OmoUsage/Dashboard/UsageDashboardViewModel.swift:56` | 13 | Main-actor refresh, ordering, connection-state, and snapshot coordinator |
| `ProviderID` | enum | `Sources/OmoUsageCore/Models/ProviderID.swift` | 49 | Canonical provider identity and order |
| `UsageSnapshotCodec` | enum | `Sources/OmoUsageCore/Sync/UsageSnapshotSync.swift` | 5 | Validates schema-v4 mobile-safe snapshots |
| `WebDashboardRouter` | struct | `Sources/OmoUsage/WebDashboard/WebDashboardServer.swift:290` | 3 | Allowlists local HTTP routes and authorized dashboard commands |
| `OmoUsageMobileApp` | entry point | `Sources/OmoUsage/Mobile/OmoUsageMobileApp.swift:5` | 1 | Loads snapshots; never calls providers |

## CONVENTIONS

- Providers are value-type `Sendable` implementations of `UsageProvider`; `fetch(now:)` is `async throws`.
- UI and observable state live on `@MainActor`; shared mutable cooldown state uses an actor.
- `UsageDashboardViewModel.refresh()` fetches independently with a task group. Cancellation publishes neither failure state nor a new timestamp.
- Provider failures are typed. Missing authentication removes a provider; transient failures may retain its last-good usage.
- Korean is the persisted default language. Machine values use typed IDs/enums; provider-generated display text is localized separately.
- SwiftPM builds `OmoUsageCore`, the macOS executable, and tests. XcodeGen/Xcode builds macOS, iOS, and Catalyst targets.
- `OMO_USAGE_FIXTURE_MODE=1` swaps the production roster for fixture providers and also enables the mobile fixture.

## ANTI-PATTERNS (THIS PROJECT)

- Never put credentials, cookies, API keys, local paths, or diagnostics into `DashboardSnapshot` or iCloud.
- Never render or log stored secrets. `DiscoveredCredential.description` and diagnostics must remain redacted.
- Never treat documentation or help links as successful authentication; missing tools must report the required executable.
- Never resolve similarly named third-party executables such as `opencodex`; launch only the provider's official app or CLI.
- Never route provider help through OpenUsage or copy its unrelated product surfaces.
- Never force Aqua, Dark Aqua, or a SwiftUI color scheme. The app follows system appearance.
- Never replace the native status-item-anchored `NSPopover` with custom pointer or screen-relative panel geometry.
- Never expose the web dashboard beyond loopback, serve arbitrary files, or accept mutations without the per-launch nonce.
- Do not add provider/network/credential code to the mobile target.

## UNIQUE STYLES

- `DESIGN.md` is the prose source of truth; `DashboardVisualContractTests` pins only machine-consumed visual tokens and behavior.
- Provider APIs vary, so parsers deliberately accept known schema paths through `ProviderPayload` while rejecting payloads with no meaningful usage.
- Credential discovery is explicit and provider-specific rather than reflective: environment, Keychain, files, SQLite, and selected CLI paths have tested precedence.
- The web dashboard reuses the sanitized snapshot and existing refresh owner; its HTML has no external scripts, fonts, cookies, or analytics.
- Tests synchronize async work with actors, continuations, and `AsyncStream`; fixed dates and UUID-namespaced temporary homes keep fixtures deterministic.

## COMMANDS

```bash
swift build
swift test
sh Scripts/package-app.sh
```

`package-app.sh` builds release with SwiftPM, assembles `dist/OmoUsage.app`, patches plist substitutions, generates the icon, and signs in explicit ad-hoc or Developer ID mode. `release-app.sh` owns notarization/stapling/assessment.

## NOTES

- `Package.swift` exports one `OmoUsageCore` library and the macOS executable; `project.yml` makes both apps depend on the same Core target.
- Both app targets must use the same development team and `$(TeamIdentifierPrefix)com.omo.usage` iCloud identifier.
- The checked-in `.xcodeproj` mirrors `project.yml`; treat the YAML as the target-definition source.
- `UsageSnapshotCodec` currently uses schema version 4, decodes versions 1–3, and keeps a 256 KB payload ceiling.
- `NWWebDashboardListener` binds `127.0.0.1:7827`; `WebDashboardRouter` is the only HTTP route and mutation boundary.
