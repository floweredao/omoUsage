# PROJECT KNOWLEDGE BASE

**Generated:** 2026-08-23T03:26:22Z
**Commit:** 5fd43e3
**Branch:** main

## OVERVIEW

OmoUsage is a native Swift 6 menu-bar app that aggregates remaining quota from ten coding-AI providers. The macOS app owns credentials, provider calls, and a loopback web dashboard; an iOS/Catalyst companion receives only sanitized usage snapshots through private iCloud key-value storage.

## STRUCTURE

```text
.
|-- Sources/OmoUsage/          # Single SwiftPM executable; domain folders are not separate modules
|   |-- Credentials/           # Local environment, file, Keychain, SQLite, and CLI discovery
|   |-- Providers/             # Provider HTTP adapters, payload parsing, and fixture providers
|   |-- Dashboard/             # Refresh orchestration, ordering, and provider protocol
|   |-- Models/                # Codable data shared with the mobile target
|   |-- Settings/              # Provider setup actions and local API-key storage
|   |-- Views/                 # macOS popover and settings UI
|   |-- Localization/          # Korean-default typed string catalog
|   |-- Sync/                  # Versioned iCloud snapshot codec/store
|   |-- WebDashboard/          # Loopback HTTP router, command bridge, and bundled web assets
|   `-- Mobile/                # iOS/Catalyst entry point and read-only UI
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
| Change provider setup/login | `Settings/ProviderSetup.swift` | Only official apps/CLIs; OpenRouter and Z.ai accept API keys |
| Change desktop UI | `Views/`, `AppDelegate.swift`, `DESIGN.md` | Native 320 pt popover and system appearance |
| Change web dashboard | `WebDashboard/`, `Resources/WebDashboard/index.html` | Loopback-only sanitized surface; mutations require a launch nonce |
| Change mobile data/UI | `Sync/`, `Models/`, `Localization/`, `Mobile/` | Mobile target excludes credentials and providers |
| Change target membership | `project.yml` | Regenerate the checked-in Xcode project afterward |
| Add regression coverage | `Tests/OmoUsageTests/` | Swift Testing, injected files/Keychain/URLProtocol |

## CODE MAP

LSP document symbols supplied declaration shape; ast-grep supplied conformer and constructor counts. `Refs` is the number of Swift files containing the symbol because Swift LSP reference requests timed out.

| Symbol | Type | Location | Refs | Role |
|--------|------|----------|------|------|
| `OmoUsageApp.main` | entry point | `Sources/OmoUsage/OmoUsageApp.swift:5` | 1 | Starts the accessory `NSApplication` |
| `AppDelegate` | class | `Sources/OmoUsage/AppDelegate.swift:93` | 2 | macOS composition root and popover lifecycle |
| `ProviderFactory.current` | factory | `Sources/OmoUsage/Providers/ProviderFactory.swift:4` | 3 | Registers ten live providers or fixture providers |
| `CredentialDiscovery` | struct | `Sources/OmoUsage/Credentials/CredentialDiscovery.swift:77` | 30 | Central local credential boundary |
| `UsageProvider` | protocol | `Sources/OmoUsage/Dashboard/UsageProvider.swift:3` | 17 | `Sendable` async provider contract; 11 structural conformers |
| `UsageDashboardViewModel` | class | `Sources/OmoUsage/Dashboard/UsageDashboardViewModel.swift:4` | 6 | Main-actor refresh, ordering, and snapshot coordinator |
| `ProviderID` | enum | `Sources/OmoUsage/Models/ProviderID.swift:1` | 33 | Canonical provider identity and order |
| `UsageSnapshotCodec` | enum | `Sources/OmoUsage/Sync/UsageSnapshotSync.swift:16` | 2 | Validates and versions mobile-safe snapshots |
| `WebDashboardRouter` | struct | `Sources/OmoUsage/WebDashboard/WebDashboardServer.swift:274` | 17 | Allowlists local HTTP routes and authorized dashboard commands |
| `OmoUsageMobileApp` | entry point | `Sources/OmoUsage/Mobile/OmoUsageMobileApp.swift:6` | 1 | Loads snapshots; never calls providers |

## CONVENTIONS

- Providers are value-type `Sendable` implementations of `UsageProvider`; `fetch(now:)` is `async throws`.
- UI and observable state live on `@MainActor`; shared mutable cooldown state uses an actor.
- `UsageDashboardViewModel.refresh()` fetches independently with a task group. Cancellation publishes neither failure state nor a new timestamp.
- Provider failures are typed. Missing authentication removes a provider; transient failures may retain its last-good usage.
- Korean is the persisted default language. Machine values use typed IDs/enums; provider-generated display text is localized separately.
- SwiftPM is the macOS build/test path. XcodeGen/Xcode is the only path for the mobile target.
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

`package-app.sh` builds release with SwiftPM, assembles `dist/OmoUsage.app`, patches plist substitutions, generates the icon, and ad-hoc signs it. It does not notarize or publish.

## NOTES

- `Package.swift` builds only macOS; `project.yml` explicitly selects the shared files compiled into `OmoUsageMobile`.
- Both app targets must use the same development team and `$(TeamIdentifierPrefix)com.omo.usage` iCloud identifier.
- The checked-in `.xcodeproj` mirrors `project.yml`; treat the YAML as the target-definition source.
- `UsageSnapshotCodec` currently uses schema version 1 and a 256 KB payload ceiling.
- `NWWebDashboardListener` binds `127.0.0.1:7827`; `WebDashboardRouter` is the only HTTP route and mutation boundary.
