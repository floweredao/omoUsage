# Contributing

Thanks for taking the time to contribute. OmoUsage is a native macOS app, so
everything below assumes a Mac.

## Requirements

- macOS 15 or later on Apple silicon.
- Xcode 26 or later (Swift 6.1 or later). The Command Line Tools alone are not
  enough: they ship without the SwiftUI macro plugins, so the build fails with
  `plugin for module 'SwiftUIMacros' not found`. If `xcode-select -p` prints
  `/Library/Developer/CommandLineTools`, either run
  `sudo xcode-select -s /Applications/Xcode.app` or prefix each command with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you change target
  membership in `project.yml` and have to regenerate `OmoUsage.xcodeproj`.

No account, server, or API key is needed to build or test: the test suite and
the fixture mode below run entirely offline.

## Build and run

```sh
swift build                               # debug build
swift test                                # full test suite
OMO_USAGE_FIXTURE_MODE=1 swift run OmoUsage   # run with sample data
sh Scripts/package-app.sh                 # → dist/OmoUsage.app
```

SwiftPM builds the macOS app and its tests. The iPhone and Mac Catalyst targets
live in `project.yml` and the checked-in `OmoUsage.xcodeproj`.

Run with `OMO_USAGE_FIXTURE_MODE=1` whenever you work on the UI: it shows
sample data instead of calling any service, so you never spend a real account's
quota and screenshots carry no personal data.

## Checks before a pull request

```sh
swift test
sh Scripts/check-repository-hygiene.sh
sh Scripts/check-core-boundary.sh
sh Scripts/check-source-policy.sh
```

| Check | What it covers |
| --- | --- |
| `swift test` | The whole suite, including provider parsing, the web dashboard router, and the visual contract |
| `check-repository-hygiene.sh` | Tracked files keep mode 644; the scripts it lists keep 755 |
| `check-core-boundary.sh` | `OmoUsageCore` stays mobile-safe: no provider, network, or credential code |
| `check-source-policy.sh` | No fixed sleeps, no credentials in snapshot fields |
| `sh Scripts/ci-check.sh policy` | The three checks above plus `xcodegen generate`; it rewrites `OmoUsage.xcodeproj`, so commit the diff it produces |
| `sh Scripts/ci-check.sh swiftpm` | `swift test` plus debug and release builds |
| `sh Scripts/ci-check.sh xcode` | macOS, Mac Catalyst, and iOS target builds |
| `sh Scripts/ci-check.sh package-smoke` | The packaged-resource smoke tests |

`.github/workflows/ci.yml` mirrors these lanes, so a change that passes them
locally is the change that passes there.

A new file is committed with mode 644. If you add a script that has to be
executable, add it to both `Scripts/check-repository-hygiene.sh` and
`RepositoryHygieneTests`, otherwise the hygiene check fails.

## Conventions

- `AGENTS.md` at the repository root is the map of the code base, and each
  source folder has its own `AGENTS.md` with the rules for that boundary. Read
  the one next to the code you change.
- [`DESIGN.md`](DESIGN.md) is the binding contract for layout, tokens, motion,
  and accessibility. UI changes follow it, and
  `DashboardVisualContractTests` pins the machine-consumed tokens.
- Tests use [Swift Testing](https://developer.apple.com/documentation/testing)
  (`@Test`, `#expect`), with injected files, Keychain, and `URLProtocol` stubs
  instead of network access. Add the regression test next to its neighbors.
- The display language follows the system language until the user chooses
  one. A user-visible string belongs in
  `Sources/OmoUsageCore/Localization/AppStrings.swift` with both a Korean and
  an English value.
- Credentials stay on the machine. Never put a token, cookie, API key, local
  path, or raw diagnostic into the dashboard snapshot, the iCloud payload, the
  web dashboard, or a log line, and never add an external script, font, or
  analytics request to the bundled web client.
- Provider work keeps the existing boundaries: `ProviderHTTP`, `UsageJSON`,
  and `ProviderPayload`. A failing service must never blank the others.

## Commits and pull requests

- One logical change per commit, with a subject in the Conventional Commits
  form the history uses: `type(scope): imperative summary`, where `type` is
  one of feat, fix, refactor, test, docs, chore, build, ci, or perf.
- Every commit builds and its tests pass on its own.
- A pull request says what changed, why, and which checks you ran with their
  result. For a behavior change, include the reproduction: the command or
  request, what it did before, and what it does now.
- A bug report is most useful with the exact steps, the expected behavior, and
  the observed behavior. Leave credentials, tokens, Keychain contents, and
  anything else private out of issues, fixtures, and screenshots — a sanitized
  payload is enough to reproduce a parsing bug.

## License

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE) that covers this project.
