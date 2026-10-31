# oh-my-openusage

**See how much of every coding-AI plan you have left, right from the macOS menu bar.**

oh-my-openusage is a native macOS app that collects the remaining quota of the
coding-AI services you already pay for and shows it in one place: a menu-bar
popover, an optional edge rail, a private web page, and an iPhone companion.
It reuses the sign-ins you already have, keeps every credential on your Mac,
and runs without an account or server of its own. The app is called
**OmoUsage**.

> Inspired by [OpenUsage](https://github.com/robinebers/openusage). This is an
> independent project, not affiliated with or endorsed by OpenUsage.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Docs/images/popover-dark.png">
    <img src="Docs/images/popover-light.png" width="346" alt="OmoUsage popover showing remaining Claude Code and Codex quota with reset times">
  </picture>
</p>

<sub>Every screenshot uses the app's built-in sample data, not a real account.</sub>

## What you get

- **Menu-bar popover.** One section per account with session and weekly
  windows, credits, spend, and when each one resets. The scroll bar appears
  only while you scroll.
- **Side Notch.** An optional notch that grows out of the screen edge, with a
  remaining-usage ring per account. Each ring, its account badge, and its
  detail bars take the color of the provider's own icon, so every provider
  reads as one color. Below a fifth remaining, the percentage under the ring
  turns into a dark pill. Point at a ring and its details open in a speech
  bubble beside it.
- **Native Settings.** Five panes (General, Display, Web Access, Order, Auth)
  in the standard macOS grouped style. Short panes fit their content; long
  panes scroll inside the window.
- **Several accounts per service.** Add a second Claude, Codex, or other
  account and see them side by side, each with its own name.
- **Your existing sign-ins.** Most services reuse the credential their official
  app or CLI already stored. OpenRouter and Z.ai take an API key.
- **Numbers that stay put.** Each service refreshes on its own every 60
  seconds, so one failing service never blanks the rest; the last good numbers
  stay with a clear "refresh failed" label.
- **Private web dashboard.** The same usage in a browser at
  `http://127.0.0.1:7827`, laid out for desktop and phone, and reachable from
  your own devices through Tailscale Serve.
- **iPhone companion.** A read-only app that shows the same numbers through
  your private iCloud.
- **Korean and English**, light and dark appearance, VoiceOver labels, and
  Reduce Motion support throughout.
- **In-app updates** through [Sparkle](https://sparkle-project.org).

## Screenshots

<table>
  <tr>
    <td align="center" width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/side-notch-dark.png">
        <img src="Docs/images/side-notch-light.png" width="344" alt="Side Notch rail with usage rings in each provider's icon color and a speech-bubble card for a Claude Code account">
      </picture>
      <br><sub>Side Notch</sub>
    </td>
    <td align="center" width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/settings-auth-dark.png">
        <img src="Docs/images/settings-auth-light.png" width="360" alt="Settings Auth pane listing connected accounts per service">
      </picture>
      <br><sub>Settings › Auth</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/settings-general-dark.png">
        <img src="Docs/images/settings-general-light.png" width="380" alt="Settings General pane with language, Launch at Login, and updates">
      </picture>
      <br><sub>Settings › General</sub>
    </td>
    <td align="center" width="50%">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/iphone-dark.png">
        <img src="Docs/images/iphone-light.png" width="240" alt="iPhone companion showing usage synced from the Mac">
      </picture>
      <br><sub>iPhone companion</sub>
    </td>
  </tr>
  <tr>
    <td colspan="2" align="center">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="Docs/images/web-dashboard-dark.png">
        <img src="Docs/images/web-dashboard-light.png" alt="Private web dashboard with one card per account">
      </picture>
      <br><sub>Private web dashboard</sub>
    </td>
  </tr>
</table>

## Install

1. Download `OmoUsage-<version>.zip` from the
   [latest release](https://github.com/floweredao/omoUsage/releases/latest).
2. Unzip it and move `OmoUsage.app` to `/Applications`.
3. Open it. Releases are not notarized, so the first time macOS may refuse to
   open it: go to **System Settings › Privacy & Security** and choose
   **Open Anyway**.

OmoUsage lives in the menu bar, with no Dock icon. Click the gauge icon for
the popover; the gear opens Settings, where **Auth** shows every service's
connection and starts its official sign-in. **Display** switches between the
popover and the Side Notch. New versions arrive through
**Settings › General › Check for Updates**.

Requires macOS 15 or later on Apple silicon. The iPhone companion requires
iOS 18.

## Supported services

| Service | How you sign in | What OmoUsage reads |
| --- | --- | --- |
| Claude Code | `claude auth login`, or sign in with your browser from Settings | `Claude Code-credentials` Keychain item, `~/.claude/.credentials.json`, or `CLAUDE_CODE_OAUTH_TOKEN` |
| Codex | `codex login` | `~/.codex/auth.json` (honours `CODEX_HOME`) or the Codex Keychain item |
| Cursor | Cursor app › Account | Cursor's local database |
| Antigravity | Antigravity app or `agy` | `gemini` Keychain item |
| Copilot | `copilot login` or `gh auth login` | `copilot-cli` Keychain item, `~/.config/gh/hosts.yml`, or an editor's OAuth token |
| Devin | `devin auth login`, or browser sign-in from Settings | `~/.local/share/devin/credentials.toml` (honours `XDG_DATA_HOME`) |
| Grok | `grok login` | `~/.grok/auth.json` |
| Kiro | Connect from Settings (reuses an existing login or opens browser sign-in) | Account-scoped Keychain credential or Kiro CLI's `data.sqlite3` |
| OpenCode | `opencode auth login` or an API key in Settings | OpenCode's `auth.json` plus local usage records |
| OpenRouter | API key in Settings | OmoUsage's own Keychain item |
| Z.ai | API key in Settings | OmoUsage's own Keychain item |

Services you are not signed in to stay hidden. An account you add in Settings
gets its own Keychain item, so it never overwrites the official CLI's
credential.

## Privacy

- Everything runs on your Mac. OmoUsage talks only to each service's own usage
  API. There is no analytics, telemetry, or backend.
- API keys you enter are stored in the macOS Keychain and are never shown
  again, synced to iCloud, or written to diagnostics.
- The web dashboard listens on loopback only and serves the same sanitized
  snapshot as the iPhone app: totals, plan names, and reset times. It never
  sends credentials, cookies, or file paths, and every change it makes needs a
  per-launch token. To open it from another device, proxy `127.0.0.1:7827`
  with Tailscale Serve inside your tailnet; do not expose it with Tailscale
  Funnel or on a LAN interface.
- The iPhone companion never sees service credentials and never calls service
  APIs.

## Configuration

OmoUsage needs no configuration file; everything is set in Settings. It keeps
its own state in these places:

| What | Where |
| --- | --- |
| Accounts you add in Settings | `$XDG_CONFIG_HOME/openusage/accounts.json` (default `~/.config/openusage/accounts.json`) |
| API keys and added-account credentials | macOS Keychain items owned by OmoUsage |
| Latest Claude usage read, for other local tools to reuse (no tokens) | `~/Library/Application Support/OmoUsage/claude-usage.json` |
| Display, language, and refresh preferences | the app's user defaults (`com.omo.usage`) |

The app also reads these environment variables. A Mac app opened from Finder
does not see your shell's variables, so set them when you launch it from a
terminal, for example `open --env OPENROUTER_API_KEY=... /Applications/OmoUsage.app`.
Each one is optional.

| Variable | Effect |
| --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code token, tried after the Keychain item and `~/.claude/.credentials.json` |
| `CLAUDE_CONFIG_DIR` | Claude Code config folder instead of `~/.claude` (absolute path) |
| `CODEX_HOME` | Codex folder instead of `~/.codex` |
| `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN` | GitHub token for Copilot, checked in this order |
| `GROK_HOME` | Grok folder instead of `~/.grok` |
| `KIRO_DATA_DIR` | Kiro CLI data folder (absolute path) |
| `KIRO_LB_URL` | Kiro LB gateway URL (Labs), instead of `http://127.0.0.1:<SERVER_PORT>` from `~/.local/share/kiro-lb/.env` (default port 8000) |
| `OPENCODE_API_KEY` | OpenCode Go API key when none is saved in Settings |
| `OPENCODE_DATA_DIR` | OpenCode data folder (absolute path) |
| `OPENROUTER_API_KEY` or `OPENROUTER_KEY` | OpenRouter API key when none is saved in Settings |
| `ZAI_API_KEY` or `GLM_API_KEY` | Z.ai API key when none is saved in Settings |
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME` | Base folders (absolute paths) for OmoUsage's account list and for Devin and OpenCode data |
| `OMO_USAGE_FIXTURE_MODE=1` | Show sample data instead of calling any service (debug builds, or a `--fixtures` package) |

Building a release uses `OMO_USAGE_CODESIGN_IDENTITY` and
`OMO_USAGE_TEAM_IDENTIFIER`; see [`RELEASE.md`](RELEASE.md).

## Build from source

Requires Xcode 26 or later (Swift 6.1 or later) on an Apple silicon Mac. The
Command Line Tools alone are not enough: they do not include the SwiftUI macro
plugins, so the build fails with `plugin for module 'SwiftUIMacros' not found`.
If `xcode-select -p` prints `/Library/Developer/CommandLineTools`, point the
build at Xcode with `sudo xcode-select -s /Applications/Xcode.app` or prefix
each command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
swift build                 # debug build
swift test                  # full test suite
sh Scripts/package-app.sh   # → dist/OmoUsage.app
open dist/OmoUsage.app
```

`package-app.sh` signs with the first Apple Development certificate in your
Keychain, so a rebuilt copy keeps its Keychain "Always Allow" approvals. Without
one it signs ad hoc; pass `--adhoc` to force that.

To try the app with sample data, for example to take screenshots:

```sh
OMO_USAGE_FIXTURE_MODE=1 swift run OmoUsage
```

The iPhone and Mac Catalyst companion targets live in `project.yml`
(XcodeGen) and the checked-in `OmoUsage.xcodeproj`; SwiftPM builds only the
macOS app and its tests.

## Documentation

- [`DESIGN.md`](DESIGN.md): the layout, tokens, motion, accessibility, and
  privacy rules every screen follows.
- [`RELEASE.md`](RELEASE.md): signing, Sparkle updates, and release steps.
- [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)

## Acknowledgements

- [OpenUsage](https://github.com/robinebers/openusage) for the idea and for
  showing how each service reports usage.
- [Sparkle](https://sparkle-project.org) for in-app updates.
