# KeyMic

<p align="center">
  <img src="assets/logo.png" alt="KeyMic logo" width="128" height="128">
</p>

**KeyMic is a macOS menu-bar app for voice input, clipboard history, key remapping, hotkeys, secret-aware clipboard storage, and screenshot annotation.**

It combines several keyboard-first productivity tools into one open-source desktop app: speak into any text field, search your clipboard, remap awkward keys, trigger app actions with shortcuts, keep secrets out of plain clipboard history, and annotate screenshots without leaving your workflow.

## Features

### Voice input anywhere

Hold a trigger key, speak, and KeyMic pastes the transcription into the focused app.

- Trigger with **Fn** or **Right Option**
- Live transcription overlay while speaking
- Paste result through simulated `Cmd+V`
- Optional LLM refinement through an OpenAI-compatible chat-completions endpoint
- IME-safe paste path for non-ASCII input sources such as Pinyin

### Clipboard history

Keep a searchable text clipboard history in a fast keyboard panel.

- Open with `⌥V`
- Search previous clips
- Navigate with arrow keys
- Quick paste with `⌥1`–`⌥0`
- Deduplicates repeated clips
- Skips transient, concealed, and self-generated clipboard writes

### Keyboard remapping

Use Karabiner-style key remaps without running a separate remapping daemon.

- Session-level `CGEvent` tap
- Modifier-to-modifier and modifier-to-key mappings
- Examples: Right Cmd → Forward Delete, Caps Lock → Left Control
- Auto-repeat support for modifier-to-key mappings

### Custom hotkey actions

Bind shortcuts to app actions from KeyMic settings.

- Toggle clipboard history
- Start screenshot capture
- Run other built-in `HotkeyAction` commands
- Persisted in `UserDefaults`

### Vault for secrets

KeyMic scans clipboard text for secrets before saving it to history.

- Detects API keys, tokens, and similar secret patterns
- Uses bundled `gitleaks.toml` rules
- Stores detected secrets in macOS Keychain
- Keeps secret values out of normal SwiftData clipboard history
- Displays masked values in the Vault list

### Screenshot annotation

Capture part of the screen, annotate it, and export it.

- Selection overlay
- Annotation tools
- Pixelation support
- Export to PNG file or clipboard
- Toolbar stays visible near screen edges

### Auto-update ready

KeyMic includes Sparkle 2 integration for signed app updates.

- Sparkle 2 updater controller
- EdDSA-signed appcast support
- Release script can build, sign, package, tag, publish, and update the appcast

## Requirements

- macOS 14.0 Sonoma or later
- Xcode Command Line Tools for source builds
- Accessibility permission for global keyboard features
- Microphone and Speech Recognition permissions for voice input
- Screen Recording permission for screenshot capture

## Quick Start from Source

KeyMic uses Swift Package Manager plus a Makefile. There is no Xcode project.

```bash
make build   # release build for host architecture → ./KeyMic.app
make run     # build and launch KeyMic.app
make install # copy KeyMic.app to /Applications
```

First launch may ask for macOS privacy permissions. Enable them in **System Settings → Privacy & Security**.

## Permissions

| Permission | Required for |
|---|---|
| Accessibility | Global event tap for voice trigger, clipboard hotkey, hotkey actions, and key remapping |
| Microphone | Voice input |
| Speech Recognition | Speech-to-text transcription |
| Screen Recording | Screenshot capture |

KeyMic is intentionally **not sandboxed**. A session-level `CGEvent` tap is incompatible with the App Sandbox.

After rebuilding, macOS may invalidate previous privacy approvals because the binary's code directory hash changes. Re-grant permissions in System Settings, or reset them with:

```bash
tccutil reset Accessibility io.keymic.app
tccutil reset Microphone io.keymic.app
tccutil reset SpeechRecognition io.keymic.app
tccutil reset ScreenCapture io.keymic.app
```

## Build Commands

```bash
make build        # release build for host architecture → ./KeyMic.app
make build-arm64  # arm64-only build
make build-x86_64 # x86_64-only build
make run          # build and launch
make install      # copy bundle to /Applications
make clean        # swift package clean + remove app bundle
```

Both `make build` and release packaging use `CODESIGN_IDENTITY`. If it is not set, the Makefile falls back to ad-hoc signing with `"-"`.

```bash
CODESIGN_IDENTITY="-" make build
CODESIGN_IDENTITY="KeyMic Dev" make build
```

For a stable local development identity, create a self-signed code-signing certificate in Keychain Access and set:

```bash
export CODESIGN_IDENTITY="KeyMic Dev"
make build
```

For distribution outside your own machine, use an Apple Developer ID Application certificate and notarization.

## Tests

Tests are standalone `swiftc` runners, not XCTest targets. Run them through Make:

```bash
make test-all               # run every standalone test suite
make test                   # KeyMappingManager tests
make test-clipboard-store   # ClipboardStore tests
make test-clipboard-monitor # ClipboardMonitor tests
```

`swift test` will fail because `Package.swift` does not define a test target.

## Release

```bash
make release VERSION=1.2.3
make release VERSION=1.2.3 FORCE=1
# or directly:
scripts/release.sh 1.2.3
scripts/release.sh -f 1.2.3
```

Release packaging performs these steps:

1. Updates `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`
2. Builds arm64 and x86_64 binaries
3. Merges them into a universal binary with `lipo`
4. Assembles and signs `KeyMic.app`
5. Creates `.release/KeyMic-<version>.zip`
6. Generates a Sparkle appcast with EdDSA signatures
7. Commits `Info.plist`
8. Deploys `appcast.xml` to the `gh-pages` branch
9. Tags `v<version>` and publishes a GitHub release with the zip attached

Release prerequisites:

- Sparkle command-line tools in `~/.sparkle-tools/`
- EdDSA private key available to Sparkle's `generate_appcast`
- Authenticated `gh` CLI
- `CODESIGN_IDENTITY` set to an appropriate signing identity

## Architecture

KeyMic is a single macOS menu-bar app (`LSUIElement`) built with Swift, AppKit, SwiftUI, SwiftData, ScreenCaptureKit, Keychain Services, and Sparkle.

Core areas:

- `Sources/KeyMic/AppDelegate.swift` wires long-lived services together
- `Sources/KeyMic/KeyMonitor.swift` owns the shared global event tap
- `Sources/KeyMic/Clipboard/` contains clipboard monitor, store, controller, and panel UI
- `Sources/KeyMic/Hotkey/` contains action definitions, bindings, recorder UI, and persistence
- `Sources/KeyMic/Vault/` contains secret scanning, Keychain storage, masking, and Vault UI
- `Sources/KeyMic/Screenshot/` contains capture, selection, annotation, rendering, and export
- `Sources/KeyMic/Updater/` wraps Sparkle update integration

For deeper implementation notes, see [`CLAUDE.md`](CLAUDE.md). For macOS HID, event-tap, and TCC gotchas, see [`AGENTS.md`](AGENTS.md).

## Contributing

Contributions are welcome. Start with:

- [`CONTRIBUTING.md`](CONTRIBUTING.md) for contribution basics
- [`SECURITY.md`](SECURITY.md) for vulnerability reporting
- `make test-all` before opening a pull request

Keep changes focused. This project touches macOS privacy, keyboard input, clipboard state, and signing behavior, so small reviewable patches are easier to validate.

## License

KeyMic is licensed under the MIT License. See [`LICENSE`](LICENSE).