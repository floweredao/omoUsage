# SHARED CORE

## OVERVIEW

Cross-platform models, localization, and explicit privacy-minimized iCloud serialization for macOS, iOS, and Catalyst.

## WHERE TO LOOK

| Task | Location |
|------|----------|
| Provider and composite account identities | `Models/ProviderID.swift` |
| Persisted order repair | `Models/ProviderDisplayOrder.swift` |
| Usage, metrics, typed failures, freshness | `Models/UsageModels.swift`, `Models/DashboardSnapshot.swift` |
| Typed translation keys and provider text | `Localization/AppStrings.swift`, `Localization/ProviderTextLocalization.swift` |
| Cloud DTOs, codec, KVS store, mobile view model | `Sync/UsageSnapshotSync.swift` |
| Contract tests | `../../Tests/OmoUsageTests/CloudSnapshotPrivacyTests.swift`, `UsageSnapshotSyncTests.swift`, `SnapshotFreshnessSchemaTests.swift` |

## CONVENTIONS

- `Package.swift` explicitly lists Core Swift sources; `project.yml` defines the shared framework. New source files need both target definitions checked.
- Local `AccountProviderID` uses a UUID plus provider ID. Cloud DTOs replace account UUIDs and aliases with sequential per-provider ordinals; do not conflate local and wire identities.
- `encodeForLocalDashboard` is the only encoder that fills the DTO's optional account ID and sanitized label, for the loopback web dashboard. iCloud publishing must use `encode`.
- Encode through `CloudSnapshot` and `CloudProviderUsage`, never directly through a widened local model.
- Schema v4 decodes versions 1–3; unknown versions fail. Preserve sorted-key JSON, millisecond dates, and the 256 KiB limit.
- Codec validation checks account ordinals, duplicates, metric bounds, string/collection limits, and timestamp ordering. `oldestDisplayedSuccessAt` must agree with provider success times.
- `UbiquitousUsageSnapshotStore` synchronizes reads and writes on the main actor, surfaces failures, and skips unchanged payload writes.
- `MobileUsageViewModel` retains its last-good snapshot after reload failure. Snapshot age uses the Mac check time with a 15-minute threshold; provider freshness and iCloud failure remain separate.
- Typed language keys and machine IDs are shared; native and web preference ownership remains outside the codec.

## ANTI-PATTERNS

- Do not serialize local account UUIDs or user aliases into the cloud DTO; use its explicit account ordinal projection.
- Do not silently accept unsupported schema versions or repair invalid cloud payloads into successful empty snapshots.
- Do not advance displayed Mac timestamps when an iCloud read fails.
- Do not use a successful SwiftPM macOS build as proof of iOS/Catalyst membership; use the local Xcode lane when changing that boundary.
