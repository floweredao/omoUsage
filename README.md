# OmoUsage

A native macOS menu-bar app that shows how much quota you have left across ten
coding-AI providers, in one popover, without asking you to log in again.

<img src="Docs/screenshot.png" width="346" alt="OmoUsage popover showing remaining Codex and Claude Code quota">

OmoUsage never owns your credentials. It reads the ones the official CLIs and
apps already stored on your Mac, calls each provider's own usage endpoint, and
renders the remaining percentage and reset time.

## Supported providers

| Provider | How you sign in | What OmoUsage reads |
| --- | --- | --- |
| Claude Code | `claude auth login` | `Claude Code-credentials` keychain item, `~/.claude/.credentials.json`, or `CLAUDE_CODE_OAUTH_TOKEN`; falls back to a live Claude Desktop session |
| Codex | `codex login` | `~/.codex/auth.json` (honours `CODEX_HOME`) or the Codex keychain item |
| Cursor | Cursor app → Account | Cursor's local database |
| Antigravity | Antigravity app or `agy` | `gemini` keychain item |
| Copilot | `copilot login` or `gh auth login` | `copilot-cli` keychain item, `~/.config/gh/hosts.yml`, or an editor's OAuth token |
| Devin | `devin auth login` | `~/.local/share/devin/credentials.toml` (honours `XDG_DATA_HOME`) |
| Grok | `grok login` | `~/.grok/auth.json` |
| OpenCode | `opencode auth login` | OpenCode's `auth.json` plus local usage records |
| OpenRouter | API key in Settings | key you paste, written to its documented local config file |
| Z.ai | API key in Settings | key you paste, written to its documented local config file |

Only OpenRouter and Z.ai ask for a key. Everything else reuses an existing
login. Providers you are not signed in to are simply omitted from the popover.

## Requirements

- macOS 15 or later
- Swift 6.1 toolchain (Xcode 26) to build
- iOS 18 for the optional iPhone companion target

## Build and run

```sh
swift build                 # debug build
swift test                  # full test suite
sh Scripts/package-app.sh   # → dist/OmoUsage.app
```

`package-app.sh` produces an explicitly ad-hoc, signed-for-local-use `.app`.
Copy it wherever you keep apps:

```sh
cp -R dist/OmoUsage.app /Applications/
open -a /Applications/OmoUsage.app
```

The app runs as a status item using the `gauge.with.dots.needle.50percent` SF
Symbol. Click it for the 320 pt popover; the gear opens Settings, where every
provider reports its connection state and can launch its official login flow.

`project.yml` (XcodeGen) and the checked-in `OmoUsage.xcodeproj` exist for the
iOS/Catalyst companion target, which SwiftPM does not build.

## How it works

Usage refreshes every 60 seconds, and each provider is fetched independently so
one failure never blanks the others. A provider that fails transiently keeps
showing its last good numbers rather than disappearing.

### Claude token refresh

Claude Code's OAuth access token lives about eight hours. When it has expired,
OmoUsage performs a `refresh_token` exchange against
`https://platform.claude.com/v1/oauth/token` and writes the rotated credential
back to the same `Claude Code-credentials` keychain item, preserving every
field the CLI owns (`scopes`, `subscriptionType`, `rateLimitTier`,
`refreshTokenExpiresAt`) so Claude Code keeps working afterwards.

Two details that are easy to get wrong:

- That token endpoint sorts clients by `User-Agent` *before* it validates the
  grant. An unrecognised agent gets `429 rate_limit_error`, which looks like
  throttling but means "unknown client".
- A failed refresh is placed under a 10 minute cooldown. Without it the
  60 second refresh loop would retry a dead token endlessly.

## iPhone companion

`OmoUsageMobile` is a read-only companion. The Mac stays the only credential
owner and publishes a usage snapshot — totals, plan labels, reset times — to
your private iCloud key-value store. Credentials, cookies, API keys, and file
paths never leave the Mac. Both targets must share a development team and team-prefixed iCloud key-value
identifier. See [`RELEASE.md`](RELEASE.md) for provisioning and trusted macOS
distribution requirements.

## Private web dashboard

While OmoUsage is running, it serves a private dashboard at
`http://127.0.0.1:7827`. The browser receives only the same sanitized usage
snapshot used by the iPhone companion. It can refresh usage, reorder providers,
hide or show providers, and choose an independent Korean or English web
language; credential setup remains native-only.

The server accepts loopback connections only. To reach it from another device,
configure Tailscale Serve to proxy `127.0.0.1:7827` inside your authenticated
tailnet. Do not expose it with Tailscale Funnel or bind it directly to a LAN or
public interface.

## Privacy

Everything runs locally. OmoUsage talks only to each provider's own API, has no
analytics or telemetry, and no backend of its own. Its web server is an
always-on loopback-only companion surface while the app is running. API keys
are written solely to their documented local config files and are never
rendered again after save or written to diagnostics.

## Layout

```
Sources/OmoUsage/
  Credentials/   local credential discovery per provider
  Providers/     one UsageProvider per service + response parsing
  Dashboard/     view model, refresh scheduler, provider protocol
  WebDashboard/  loopback HTTP server, commands, packaged assets
  Views/         popover, settings, meters, provider icons
  Localization/  Korean (default) and English strings
  Resources/     app icon, provider icons, web dashboard shell
  Mobile/        iOS companion
Tests/OmoUsageTests/
Scripts/         app packaging and icon generation
Config/          Info.plist and entitlements
```

The UI ships in Korean by default; English is selectable in Settings.

## Documentation

- [`DESIGN.md`](DESIGN.md) — the design contract: visual tokens, layout,
  motion, accessibility, and the constraints the implementation must honour.
- [`RELEASE.md`](RELEASE.md) — trusted macOS signing, notarization, and iCloud
  team setup.
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
