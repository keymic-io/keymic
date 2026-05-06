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

After rebuilding, macOS may invalidate the previous authorization because the binary's cdhash changes. Re-grant in **System Settings → Privacy & Security** or run:

```bash
tccutil reset Accessibility io.keymic.app
```

## Release

```bash
scripts/release.sh 1.2.3        # build universal binary, generate appcast, tag, publish
scripts/release.sh -f 1.2.3     # overwrite existing release/tag
```

Requires `~/.sparkle-tools/generate_appcast` (from Sparkle distribution) and a `gh` CLI authenticated to `keymic-io/keymic`.

## Architecture

See [`CLAUDE.md`](CLAUDE.md) for component layout and [`AGENTS.md`](AGENTS.md) for macOS HID / event-tap gotchas.

## License

See the source repository for license details.
