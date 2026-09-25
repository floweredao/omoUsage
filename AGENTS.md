# PROJECT KNOWLEDGE BASE

**Generated:** 2026-09-14
**Commit:** 2941f87
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
|   |-- Settings/              # Account registry, credential transactions, setup, Sparkle
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
| Trace macOS startup | `Sources/OmoUsage/OmoUsageApp.swift`, `SingleInstanceController.swift`, `AppDelegate.swift` | Single-instance claim precedes manual `NSApplication` lifecycle |
| Add or reorder a provider | `Sources/OmoUsageCore/Models/ProviderID.swift`, `Sources/OmoUsage/Providers/ProviderFactory.swift` | Keep contracts, account roster, setup, and tests aligned |
| Change credential lookup | `Credentials/` | Preserve source precedence, typed failures, and redaction |
| Change provider requests/parsing | `Providers/` | Shared boundaries are `ProviderHTTP`, `UsageJSON`, and `ProviderPayload` |
| Change refresh/failure behavior | `Dashboard/UsageDashboardViewModel.swift` | Concurrent fetch, cancellation, last-good retention |
| Change provider accounts | `Settings/ProviderAccountStore.swift`, `ProviderAccountRegistryController.swift` | Registry changes rebuild account-scoped providers and repair persisted order |
| Change provider setup/login | `Settings/ProviderSetup.swift` | Official apps/CLIs; OpenCode Go, OpenRouter, and Z.ai accept API keys |
| Change desktop UI | `Views/`, `SideNotchPanelController.swift`, `AppDelegate.swift`, `DESIGN.md` | Default 320 pt popover; optional nonactivating Side Notch |
| Change app updates/version | `Settings/AppUpdateController.swift`, `Config/Version.xcconfig` | Sparkle is macOS-only; packaging embeds its framework |
| Change web dashboard | `WebDashboard/`, `Resources/WebDashboard/index.html` | Loopback-only sanitized surface; mutations require a launch nonce |
| Change mobile data/UI | `Sources/OmoUsageCore/`, `Sources/OmoUsage/Mobile/` | Mobile target depends only on Core and its two UI files |
| Change target membership | `project.yml` | Regenerate the checked-in Xcode project afterward |
| Add regression coverage | `Tests/OmoUsageTests/` | Swift Testing, injected files/Keychain/URLProtocol |

## CODE MAP

Paths below are repository-relative. Other macOS paths in the lookup table are relative to `Sources/OmoUsage`. SourceKit document/workspace symbols and an ast-grep import scan verified the map. `Refs` is the LSP reference count excluding declarations where measured; `—` means unmeasured.

| Symbol | Type | Location | Refs | Role |
|--------|------|----------|------|------|
| `OmoUsageApp.main` | entry point | `Sources/OmoUsage/OmoUsageApp.swift` | — | Claims single instance, then starts accessory application |
| `AppDelegate` | class | `Sources/OmoUsage/AppDelegate.swift` | — | Composition root and mutually exclusive dashboard surfaces |
| `ProviderFactory.current` | factory | `Sources/OmoUsage/Providers/ProviderFactory.swift` | — | Registers account-scoped live or fixture providers |
| `CredentialDiscovery` | struct | `Sources/OmoUsage/Credentials/CredentialDiscovery.swift` | — | Legacy discovery and isolated account snapshots |
| `UsageProvider` | protocol | `Sources/OmoUsage/Dashboard/UsageProvider.swift` | — | Sendable async provider and account identity contract |
| `UsageDashboardViewModel` | class | `Sources/OmoUsage/Dashboard/UsageDashboardViewModel.swift` | — | Refresh, deadlines, account ordering, snapshot coordinator |
| `ProviderID` | enum | `Sources/OmoUsageCore/Models/ProviderID.swift` | 325 | Canonical provider identity and order |
| `UsageSnapshotCodec` | enum | `Sources/OmoUsageCore/Sync/UsageSnapshotSync.swift` | — | Explicit privacy-minimized cloud DTO encoding |
| `WebDashboardRouter` | struct | `Sources/OmoUsage/WebDashboard/WebDashboardServer.swift` | — | HTTP allowlist and authorized command boundary |
| `OmoUsageMobileApp` | entry point | `Sources/OmoUsage/Mobile/OmoUsageMobileApp.swift` | — | Loads snapshots; never calls providers |

## CONVENTIONS

- Providers are value-type `Sendable` implementations of `UsageProvider`; `fetch(now:)` is `async throws`.
- UI and observable state live on `@MainActor`; shared mutable cooldown state uses an actor.
- `UsageDashboardViewModel.refresh()` fetches independently with a task group. Cancellation publishes neither failure state nor a new timestamp.
- Provider failures are typed. Missing authentication removes a provider; transient failures may retain its last-good usage.
- Korean is the persisted default language. Machine values use typed IDs/enums; provider-generated display text is localized separately.
- SwiftPM builds `OmoUsageCore`, the macOS executable, and tests. XcodeGen/Xcode builds macOS, iOS, and Catalyst targets.
- macOS fixture hooks require `OMO_USAGE_FIXTURES` (debug by default); release QA packaging uses `--fixtures`. `OMO_USAGE_FIXTURE_MODE=1` selects fixtures, including on Mobile.

## ANTI-PATTERNS (THIS PROJECT)

- Never put credentials, cookies, API keys, local paths, or diagnostics into `DashboardSnapshot` or iCloud.
- Never render or log stored secrets. `DiscoveredCredential.description` and diagnostics must remain redacted.
- Never treat documentation or help links as successful authentication; missing tools must report the required executable.
- Never resolve similarly named third-party executables such as `opencodex`; launch only the provider's official app or CLI.
- Never route provider help through OpenUsage or copy its unrelated product surfaces.
- Never force Aqua, Dark Aqua, or a SwiftUI color scheme. The app follows system appearance.
- Preserve the native status-item-anchored `NSPopover` in default Popover mode. Optional Side Notch uses its separate `NSPanel` and layout contract.
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
sh Scripts/check-source-policy.sh
sh Scripts/check-core-boundary.sh
sh Scripts/package-app.sh
```

`package-app.sh` builds release with SwiftPM, assembles `dist/OmoUsage.app`, patches plist substitutions, generates the icon, and signs in explicit ad-hoc or Developer ID mode. `release-app.sh` owns notarization/stapling/assessment.

## NOTES

- `Package.swift` exports one `OmoUsageCore` library and the macOS executable; `project.yml` makes both apps depend on the same Core target.
- Both app targets must use the same development team and `$(TeamIdentifierPrefix)com.omo.usage` iCloud identifier.
- The checked-in `.xcodeproj` mirrors `project.yml`; treat the YAML as the target-definition source.
- `sh Scripts/ci-check.sh policy` regenerates the Xcode project; it is not a read-only check. `swiftpm`, `xcode`, and `package-smoke` are separate local lanes.
- Existing GitHub workflows have push/PR/tag triggers. Do not trigger Actions without explicit authorization; check and reversibly disable relevant workflows before an authorized remote write.
- `UsageSnapshotCodec` currently uses schema version 4, decodes versions 1–3, and keeps a 256 KB payload ceiling.
- `NWWebDashboardListener` binds production `127.0.0.1:7827`; fixture mode may override the port. Optional Tailscale Serve supplies private HTTPS access. `WebDashboardAccessGateway` validates Host/Origin before the router checks routes and mutation nonces.
