# Building, Signing & Releasing

## Local development build

```bash
make build   # release build (host arch) → ./KeyMic.app, codesigned with local identity "${CODESIGN_IDENTITY}"
make run     # build and launch
make install # copy to /Applications
```

`CODESIGN_IDENTITY` defaults to `-` (ad-hoc/self-signed). That's fine for local dev, but:

- Every `make build` gets a new ad-hoc identity, so macOS treats it as a new app — re-grant
  **Accessibility** after each build.
- Ad-hoc signed builds are **not notarizable** and will not pass Gatekeeper on any machine
  other than the one that built them.

Permissions requested on first launch: **Accessibility**, **Microphone**, **Speech
Recognition**, **Screen Recording**.

## Signing for distribution

Public releases must be signed with a **Developer ID Application** certificate and
notarized, or Gatekeeper hard-blocks the app on Apple Silicon (no override dialog — just a
"can't be opened" failure).

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

`scripts/release.sh` picks this up and, when it's not `-`, adds `--options runtime
--timestamp` to every `codesign` call (required for notarization) and runs the
notarization step automatically.

### Notarization credentials

Provide **one** of:

- `APPLE_NOTARY_PROFILE` — a profile name created once via:
  ```bash
  xcrun notarytool store-credentials "<profile-name>" \
    --apple-id "you@example.com" --team-id TEAMID --password "<app-specific-password>"
  ```
  (stored in the local keychain; nothing else to export per release)
- or the three explicit env vars: `APPLE_ID`, `APPLE_TEAM_ID`,
  `APPLE_APP_SPECIFIC_PASSWORD` (generate an app-specific password at
  [appleid.apple.com](https://appleid.apple.com)).

`scripts/release.sh` will refuse to proceed if `CODESIGN_IDENTITY` is set to a real
identity but no notarization credentials are found.

## Release flow

```bash
bash scripts/release.sh <version>        # e.g. bash scripts/release.sh 1.0.4
bash scripts/release.sh -f <version>      # force: delete + recreate an existing tag/release
```

One command:

1. Bumps `Info.plist` version.
2. Builds arm64 + x86_64 in release config, `lipo`s into a universal binary.
3. Assembles `KeyMic.app`, copies in Sparkle.framework and resources.
4. Codesigns (Developer ID + hardened runtime, if configured).
5. Submits for notarization, waits, staples the ticket, verifies with `spctl --assess`.
6. Zips the stapled `.app`, generates the Sparkle `appcast.xml`.
7. Commits the version bump, pushes `appcast.xml` to `gh-pages`, tags, and publishes the
   GitHub Release with the zip attached.

### After a notarized release: update the Homebrew cask

The cask lives in [`keymic-io/homebrew-tap`](https://github.com/keymic-io/homebrew-tap)
(`Casks/keymic.rb`), not in this repo. After a release:

```bash
shasum -a 256 .release/KeyMic-<version>-universal.zip
```

Bump `version` and `sha256` in `Casks/keymic.rb` in the tap repo and push. `brew install
--cask keymic-io/tap/keymic` (or `brew upgrade` for existing installs) then picks it up.

## Tests

See `make test` and the many `make test-*` targets in the `Makefile` — one target per test
suite, no single monolithic `swift test` (keeps iteration fast on a large test surface).
