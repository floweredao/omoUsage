# macOS releases and Sparkle updates

## Local ad-hoc packaging

```sh
env -u SDKROOT -u DEVELOPER_DIR sh Scripts/package-app.sh --adhoc
```

The result is `dist/OmoUsage.app`. Packaging embeds the checksum-verified
SwiftPM Sparkle 2.9.6 framework, preserving its symlinks and helpers. The
executable links with `@executable_path/../Frameworks`. Signing runs inside-out
(Installer, Downloader, Autoupdate, Updater, framework, app), preserving helper
entitlements without applying the app's iCloud entitlement to nested code.
`--deep` is used only for verification, never signing.

Ad-hoc builds remain usable for local/manual distribution, but are not
Developer ID signed or notarized and have no iCloud team entitlement. Sparkle
EdDSA signatures authenticate updates; they do not remove Gatekeeper warnings
or make ad-hoc builds trusted public distributions. An Apple Development
certificate is not a substitute for a Developer ID Application certificate.

## Prepare a local signed update (no upload)

Increase `CURRENT_PROJECT_VERSION` in `Config/Version.xcconfig` for every
update; Sparkle compares this build number, not just `MARKETING_VERSION`.
Package the app first. The packaged `SUPublicEDKey` must match the existing
Sparkle keychain account `com.omo.usage.sparkle`. Never regenerate/replace a
production update key or commit/export its private value as part of a release.

Download the official tools archive once:

```sh
curl --fail --location \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz \
  --output /tmp/Sparkle-2.9.6.tar.xz
```

Run preparation with explicit inputs (replace `VERSION` with the packaged
marketing version; the output directory must not already exist):

```sh
sh Scripts/prepare-update.sh \
  --app dist/OmoUsage.app \
  --sparkle-archive /tmp/Sparkle-2.9.6.tar.xz \
  --key-account com.omo.usage.sparkle \
  --download-url-prefix https://github.com/floweredao/omoUsage/releases/download/vVERSION/ \
  --output-dir dist/update-VERSION
```

The script verifies the official archive's pinned SHA-256
`52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`, verifies
app code signing, and uses `generate_keys --account ACCOUNT -p` only to read
an existing public key. A missing or mismatched key fails before creating
release artifacts; it never falls back to Sparkle's default account.

Official `generate_appcast` and `sign_update` create and verify:

- `OmoUsage-VERSION.zip`, with its EdDSA signature in the appcast enclosure;
- `appcast.xml`, also signed using Sparkle's embedded feed signature;
- `SHA256SUMS`, covering both final files.

The output contains one full update and no deltas. This intentionally minimal
path does not merge historical feeds or publish anything. Do not modify the
ZIP or signed XML afterward; regenerate into a new directory instead.

For local inspection:

```sh
(cd dist/update-VERSION && shasum -a 256 -c SHA256SUMS)
xmllint --format dist/update-VERSION/appcast.xml
codesign --verify --deep --strict --verbose=2 dist/OmoUsage.app
```

Before manually attaching assets to a GitHub release, inspect the enclosure's
URL, version/build, minimum OS/architecture requirements, signature and byte
length. Upload the unchanged ZIP, `appcast.xml`, and `SHA256SUMS` together to
the matching release, then make it the latest stable release. The configured
feed is:

`https://github.com/floweredao/omoUsage/releases/latest/download/appcast.xml`

That URL must actually serve the signed XML; a missing asset is not a working
update feed. Test Check for Updates from an older installed build and verify
download, signature validation, installation, and relaunch before declaring
the update path production-ready. Builds shipped without Sparkle require one
manual installation to join this update path.

## Developer ID and notarization

For trusted public distribution, a Developer ID Application certificate and
notary credentials are required. The existing local release helper packages
with hardened runtime and secure timestamps, verifies, notarizes, staples,
Gatekeeper-assesses, and writes a ZIP/checksum/source-version manifest. It
requires a clean worktree and an existing local version tag pointing at HEAD;
it does not create a tag, push, or publish. Inspect its non-executing plan:

```sh
OMO_USAGE_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
OMO_USAGE_TEAM_IDENTIFIER=TEAMID \
OMO_USAGE_NOTARY_PROFILE=example \
OMO_USAGE_NOTARY_KEYCHAIN=/path/to/notary.keychain-db \
OMO_USAGE_RELEASE_REF=refs/tags/vVERSION \
sh Scripts/release-app.sh --dry-run
```

With real credentials and the required local release ref, omit `--dry-run`
to execute. `OMO_USAGE_SIGNING_KEYCHAIN` can select a dedicated signing
keychain. Run `prepare-update.sh` on the resulting **stapled** app, not on a
subsequently rebuilt ad-hoc app. Retain the release manifest alongside the
update artifacts. Neither this manual path nor update preparation needs
GitHub Actions. The existing tag-triggered CI workflow remains separate.

The desktop and mobile targets must be registered under the same Apple
Developer team and use the same team-prefixed iCloud KVS identifier
`TEAMID.com.omo.usage`. Enable iCloud key-value storage for both App IDs and
provision both targets accordingly; ad-hoc desktop builds cannot sync iCloud.

Official references: [Sparkle setup and distribution](https://sparkle-project.org/documentation/)
and [manual nested code signing](https://sparkle-project.org/documentation/sandboxing/#code-signing).
