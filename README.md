# KeyMic

**KeyMic = Mac's Keyboard + Voice + Clipboard.** A macOS menu-bar utility (`LSUIElement`) bundling several productivity layers in one app:

- **Keyboard remap** — Karabiner-style modifier remaps through a session-level `CGEvent` tap (e.g. Right Cmd → Forward Delete, Caps Lock → Left Control).
- **Voice input** — hold a trigger key (Fn or Right Option), speak, transcribed text is pasted into the focused field. Optional LLM refinement via any OpenAI-compatible chat-completions endpoint.
- **Clipboard history** — text-only background monitor with SwiftData storage. Hotkey `⌥V` opens a search panel; arrow keys navigate, `⌥1`–`⌥0` quick-paste.
- **Hotkey actions** — user-configurable shortcuts bound to actions (toggle clipboard panel, take screenshot, etc.).
- **Vault** — secret-aware clipboard escalation. Incoming clipboard text is scanned for secrets (API keys, tokens, etc.); matches are stored in macOS Keychain rather than plain clipboard history.
- **Screenshot annotation** — selection capture with annotation and pixelation tools, export to file or clipboard.
- **Auto-update** — Sparkle 2 EdDSA-signed updates.

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools (for `swift build`)

## Build & Run

```bash
make build        # release build (host arch) → ./KeyMic.app
make build-arm64  # arm64 only
make build-x86_64 # x86_64 only
make run          # build then launch
make install      # copy bundle to /Applications
make clean        # swift package clean + remove .app
```

## Tests

Tests are standalone `swiftc` runners, not XCTest. Run via Make:

```bash
make test-all               # run every test suite
make test                   # KeyMappingManager
make test-clipboard-store   # ClipboardStore
make test-clipboard-monitor # ClipboardMonitor
```

`swift test` will not work — there is no test target in `Package.swift`.

## Permissions

| Permission | Required for |
|---|---|
| Accessibility | Event tap (voice trigger, clipboard hotkey, key remap) |
| Microphone | Voice input |
| Speech Recognition | Voice-to-text transcription |
| Screen Recording | Screenshot capture |

These are TCC-gated privacy permissions (declared in `Info.plist` via the matching `NS*UsageDescription` keys) and must be granted in **System Settings → Privacy & Security** on first use. The build also embeds [`KeyMic.entitlements`](KeyMic.entitlements), which grants microphone audio-input and disables library validation so Sparkle can load its bundled helpers under the Hardened Runtime. KeyMic is intentionally **not** sandboxed — a global `CGEvent` tap is incompatible with the App Sandbox.

After rebuilding, macOS may invalidate the previous authorization because the binary's cdhash changes. Re-grant in **System Settings → Privacy & Security** or run:

```bash
tccutil reset Accessibility io.keymic.app
tccutil reset Microphone io.keymic.app
tccutil reset SpeechRecognition io.keymic.app
tccutil reset ScreenCapture io.keymic.app
```

## Code Signing

Both `make build` and `scripts/release.sh` read the `CODESIGN_IDENTITY` environment variable. If it is not set, they fall back to `"-"` (ad-hoc signing).

### Option A — Ad-hoc signing (default, no certificate needed)

Ad-hoc signing works for local development and open-source contributors who don't have an Apple Developer account. The app runs fine on your own machine but **cannot be notarized** and Gatekeeper will block it on other machines unless the user right-clicks → Open.

```bash
# Nothing to set — "-" is the default.
make build
```

### Option B — Self-signed certificate (local use, no Apple account)

A self-signed certificate lets you use a stable identity across rebuilds so macOS doesn't invalidate TCC permissions (Accessibility, Microphone, etc.) every time you rebuild.

**Create the certificate (one-time):**

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Fill in:
   - Name: `KeyMic Dev` (or any name you like)
   - Identity Type: **Self Signed Root**
   - Certificate Type: **Code Signing**
   - Check **Let me override defaults** → keep clicking Continue with defaults → Done
3. The certificate is saved in your login keychain.

Or create it from the terminal:

```bash
# Creates a self-signed code-signing cert named "KeyMic Dev" in the login keychain
security create-certificate \
  -k ~/Library/Keychains/login.keychain-db \
  -n "KeyMic Dev" \
  -t codesigning \
  -s "KeyMic Dev"
```

> **Note:** Keychain Access GUI is more reliable for this. The `security` CLI path for cert creation is limited on modern macOS — use the GUI if the command above fails.

**Verify the certificate is visible:**

```bash
security find-identity -v -p codesigning
# Should list: "KeyMic Dev"
```

**Use it:**

```bash
export CODESIGN_IDENTITY="KeyMic Dev"
make build
# or for release:
CODESIGN_IDENTITY="KeyMic Dev" make release VERSION=0.1.0
```

### Option C — Apple Developer ID (distribution / notarization)

Required if you want to distribute outside the Mac App Store and pass Gatekeeper on other machines without user override.

**Prerequisites:** An [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year).

**Create the certificate:**

1. Open **Xcode → Settings → Accounts** → select your Apple ID → **Manage Certificates…**
2. Click **+** → **Developer ID Application**
3. Xcode downloads and installs the certificate into your login keychain automatically.

Or via the [Apple Developer portal](https://developer.apple.com/account/resources/certificates/list):
1. Create a **Developer ID Application** certificate, download the `.cer` file, double-click to install.

**Find the exact identity string:**

```bash
security find-identity -v -p codesigning
# Example output:
#   1) A1B2C3D4... "Developer ID Application: Your Name (TEAMID)"
```

**Use it:**

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make release VERSION=0.1.0
```

For notarization after signing, add a `notarize` step to `scripts/release.sh` using `xcrun notarytool`.

### Persisting the identity

Add the export to your shell profile so you don't have to set it every session:

```bash
# ~/.zshrc or ~/.zprofile
export CODESIGN_IDENTITY="KeyMic Dev"   # replace with your identity string
```

### Summary

| Scenario | `CODESIGN_IDENTITY` value | Runs on other Macs |
|---|---|---|
| Local dev / CI | `"-"` (default) | Only with user override |
| Self-signed cert | `"KeyMic Dev"` (your cert name) | Only with user override |
| Developer ID | `"Developer ID Application: …"` | Yes (after notarization) |

## Release

**Prerequisites (one-time setup):**

```bash
# 1. Install Sparkle tools
curl -L https://github.com/sparkle-project/Sparkle/releases/download/2.9.1/Sparkle-2.9.1.tar.xz \
  -o /tmp/sparkle.tar.xz
mkdir -p ~/.sparkle-tools
tar -xf /tmp/sparkle.tar.xz -C /tmp/sparkle-extracted
cp /tmp/sparkle-extracted/bin/{generate_appcast,generate_keys,sign_update,BinaryDelta} ~/.sparkle-tools/

# 2. Generate EdDSA key pair (stored in Keychain, public key printed to stdout)
~/.sparkle-tools/generate_keys
# Paste the printed SUPublicEDKey value into Info.plist

# 3. Authenticate gh CLI
gh auth login

# 4. Set your signing identity (see Code Signing section above)
export CODESIGN_IDENTITY="KeyMic Dev"   # or "-" for ad-hoc
```

**Run a release:**

```bash
make release VERSION=0.1.0          # build universal binary, sign, generate appcast, tag, publish
make release VERSION=0.1.0 FORCE=1  # overwrite existing release/tag
# or directly:
scripts/release.sh 0.1.0
scripts/release.sh -f 0.1.0         # force overwrite
```

The script:
1. Bumps `CFBundleShortVersionString` + `CFBundleVersion` in `Info.plist`
2. Builds arm64 + x86_64, merges with `lipo` into a universal binary
3. Assembles and signs `KeyMic.app`
4. Zips to `.release/KeyMic-<version>.zip`
5. Runs `generate_appcast` to produce an EdDSA-signed `appcast.xml`
6. Commits `Info.plist`, pushes to current branch
7. Deploys `appcast.xml` to the `gh-pages` branch (Sparkle auto-update feed)
8. Tags `v<version>` and creates a GitHub release with the zip attached

## Architecture

See [`CLAUDE.md`](CLAUDE.md) for component layout and [`AGENTS.md`](AGENTS.md) for macOS HID / event-tap gotchas.

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.