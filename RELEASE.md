# macOS release

Local packaging remains intentionally ad-hoc:

```sh
sh Scripts/package-app.sh --adhoc
```

It is runnable on the building Mac but is not a trusted public distribution and
has no iCloud team entitlement. Public releases are created only by pushing a
version tag matching `Config/Version.xcconfig` (for example `v0.1.8`). The
`release` GitHub environment should require approval and allow only protected
version tags.

Configure these environment secrets; never commit or persist their values:

- `MACOS_CERTIFICATE_P12_BASE64`: base64 Developer ID Application certificate
- `MACOS_CERTIFICATE_PASSWORD`: PKCS#12 password
- `MACOS_CODESIGN_IDENTITY`: full Developer ID Application identity
- `APPLE_TEAM_IDENTIFIER`: Apple Developer team identifier
- `MACOS_NOTARY_APPLE_ID` and `MACOS_NOTARY_PASSWORD`: notary account and
  app-specific password

CI imports the certificate and notary profile into a throwaway keychain, signs
with hardened runtime and secure timestamp, verifies, notarizes, staples,
Gatekeeper-assesses, and only then uploads the ZIP, checksum, and source/version
manifest. The cleanup trap deletes the temporary certificate and keychain.

Inspect a non-executing plan without credentials or network calls:

```sh
OMO_USAGE_CODESIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
OMO_USAGE_TEAM_IDENTIFIER=TEAMID \
OMO_USAGE_NOTARY_PROFILE=example \
OMO_USAGE_NOTARY_KEYCHAIN=/tmp/example.keychain-db \
OMO_USAGE_RELEASE_REF=refs/tags/v0.1.8 \
sh Scripts/release-app.sh --dry-run
```

The desktop and mobile targets must be registered under the same Apple
Developer team and use the same team-prefixed iCloud KVS identifier
`TEAMID.com.omo.usage`. Enable iCloud key-value storage for both App IDs and
provision both targets accordingly; ad-hoc desktop builds cannot sync iCloud.
