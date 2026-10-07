# oh-my-openusage

**Every coding-AI quota you pay for, one glance away in the macOS menu bar.**

oh-my-openusage is a native Swift menu-bar app that shows how much quota you
have left across eleven coding-AI providers. It reuses the logins you already
have, keeps every credential on your Mac, and needs no account or backend of
its own. The app itself is named **OmoUsage**.

> Inspired by [OpenUsage](https://github.com/robinebers/openusage). This is an
> independent project, not affiliated with or endorsed by OpenUsage.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/images/popover-dark.png">
    <img src="Docs/images/popover-light.png" width="392" alt="OmoUsage popover listing remaining Claude Code, Codex, and Cursor quota with reset times">
  </picture>
</p>

<sub>All screenshots use the app's built-in fixture data, not a real account.</sub>

## Features

- **Menu-bar popover.** A 320 pt native popover with one card per provider:
  session and weekly windows, credits, spend, and when each one resets.
- **Side Notch.** An optional edge rail with circular remaining-usage rings.
  Point at a provider and its detail card slides in from the screen edge.
- **Several accounts per provider.** Add a second Claude, Codex, or other
  account and see them side by side.
- **Reuses existing logins.** Most providers read the credential their official
  CLI or app already stored. Only OpenRouter and Z.ai need an API key.
- **Last good numbers stay.** Providers refresh independently every 60 seconds,
  so one failing service never blanks the others.
- **Private web dashboard.** The same usage in a browser at
  `http://127.0.0.1:7827`, reachable from your other devices through
  Tailscale Serve.
- **iPhone companion.** A read-only iOS app that receives a sanitized usage
  snapshot through your private iCloud.
- **Korean and English.** Korean by default; switch in Settings.
- **In-app updates** through [Sparkle](https://sparkle-project.org).

## Screenshots

<table>
  <tr>
    <td align="center" width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/side-notch-dark.png">
        <img src="Docs/images/side-notch-light.png" width="344" alt="Side Notch rail with usage rings and an expanded provider card">
      </picture>
      <br><sub>Side Notch</sub>
    </td>
    <td align="center" width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/settings-auth-dark.png">
        <img src="Docs/images/settings-auth-light.png" width="380" alt="Settings Auth pane showing connected accounts per provider">
      </picture>
      <br><sub>Settings › Auth</sub>
    </td>
  </tr>
  <tr>
    <td colspan="2" align="center">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/web-dashboard-dark.png">
        <img src="Docs/images/web-dashboard-light.png" alt="Private web dashboard with one card per provider">
      </picture>
      <br><sub>Private web dashboard</sub>
    </td>
  </tr>
  <tr>
    <td colspan="2" align="center">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/settings-general-dark.png">
        <img src="Docs/images/settings-general-light.png" width="420" alt="Settings General pane with language, launch at login, and updates">
      </picture>
      <br><sub>Settings › General</sub>
    </td>
  </tr>
</table>

## Install

1. Download the latest `OmoUsage-<version>.zip` from
   [Releases](https://github.com/floweredao/omoUsage/releases/latest).
2. Unzip it and move `OmoUsage.app` to `/Applications`.
3. Release builds are not notarized yet. On first launch, if macOS blocks the
   app, open **System Settings › Privacy & Security** and choose
   **Open Anyway**.

The app lives in the menu bar (no Dock icon). Click the gauge icon for the
popover; the gear opens Settings, where each provider shows its connection
state and can start its official sign-in. Later versions arrive through
**Settings › General › Check for Updates**.

Requires macOS 15 or later on Apple silicon.

## Supported providers

| Provider | How you sign in | What OmoUsage reads |
| --- | --- | --- |
| Claude Code | `claude auth login`, or sign in with your browser in Settings | `Claude Code-credentials` Keychain item, `~/.claude/.credentials.json`, or `CLAUDE_CODE_OAUTH_TOKEN` |
| Codex | `codex login` | `~/.codex/auth.json` (honours `CODEX_HOME`) or the Codex Keychain item |
| Cursor | Cursor app › Account | Cursor's local database |
| Antigravity | Antigravity app or `agy` | `gemini` Keychain item |
| Copilot | `copilot login` or `gh auth login` | `copilot-cli` Keychain item, `~/.config/gh/hosts.yml`, or an editor's OAuth token |
| Devin | `devin auth login`, or browser sign-in in Settings | `~/.local/share/devin/credentials.toml` (honours `XDG_DATA_HOME`) |
| Grok | `grok login` | `~/.grok/auth.json` |
| Kiro | Connect in Settings (reuses an existing login or opens browser sign-in) | Account-scoped Keychain credential or Kiro CLI's `data.sqlite3` |
| OpenCode | `opencode auth login` or an API key in Settings | OpenCode's `auth.json` plus local usage records |
| OpenRouter | API key in Settings | OmoUsage-owned Keychain item |
| Z.ai | API key in Settings | OmoUsage-owned Keychain item |

Providers you are not signed in to are hidden. Accounts you add in Settings get
their own Keychain item, so a second account never rewrites the official CLI's
credential.

## Privacy

- Everything runs on your Mac. The app talks only to each provider's own usage
  API. There is no analytics, telemetry, or backend.
- API keys you enter are stored in the macOS Keychain and are never shown
  again, synced to iCloud, or written to diagnostics.
- The web dashboard listens on loopback only and serves the same sanitized
  snapshot as the iPhone app: totals, plan labels, and reset times. It never
  sends credentials, cookies, or file paths. To use it from another device,
  proxy `127.0.0.1:7827` with Tailscale Serve inside your tailnet; do not
  expose it with Tailscale Funnel or on a LAN interface.
- The iPhone companion never sees provider credentials and never calls
  provider APIs.

## Build from source

Requires the Swift 6.1 toolchain (Xcode 26).

```sh
swift build                 # debug build
swift test                  # full test suite
sh Scripts/package-app.sh   # → dist/OmoUsage.app
open dist/OmoUsage.app
```

`package-app.sh` signs with an Apple Development certificate when your Keychain
has one, so rebuilt copies keep their Keychain "Always Allow" grants. Without
one it falls back to ad-hoc signing; pass `--adhoc` to force it.

Run with fake data, for example to take screenshots:

```sh
OMO_USAGE_FIXTURE_MODE=1 swift run OmoUsage
```

The iOS and Mac Catalyst companion targets are defined in `project.yml`
(XcodeGen) and the checked-in `OmoUsage.xcodeproj`; SwiftPM builds only the
macOS app and tests.

## Documentation

- [`DESIGN.md`](DESIGN.md): visual tokens, layout, motion, accessibility, and
  the privacy contract the implementation follows.
- [`RELEASE.md`](RELEASE.md): signing, notarization, Sparkle updates, and
  iCloud team setup.
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)

## Acknowledgements

- [OpenUsage](https://github.com/robinebers/openusage) for the idea and for
  showing how each provider reports usage.
- [Sparkle](https://sparkle-project.org) for in-app updates.
