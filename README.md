# KeyMic

**KeyMic = Mac's Keyboard + Voice + Clipboard.** A macOS menu-bar utility (`LSUIElement`) bundling three productivity layers in one app:

- **Keyboard remap** — Karabiner-style modifier remaps applied through a session-level `CGEvent` tap (e.g. Right Cmd → Forward Delete, Caps Lock → Left Control).
- **Voice input** — hold a trigger key (Fn or Right Option), speak, transcribed text is pasted into the focused field. Optional LLM refinement via any OpenAI-compatible chat-completions endpoint.
- **Clipboard history** — text-only background monitor with SwiftData storage. Hotkey `⌥V` opens a search panel; arrow keys navigate, `⌥1`–`⌥0` quick-paste.

All three pillars share a single event tap and a single menu-bar process.

https://github.com/user-attachments/assets/3228f78a-f035-447d-98ef-8826798a122c

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode Command Line Tools (for `swift build`)

## Build & Run

```bash
make build   # release build → ./KeyMic.app (ad-hoc codesigned)
make run     # build then launch
make install # copy bundle to /Applications
make clean   # swift package clean + remove .app
```

## Tests

Tests are standalone `swiftc` runners, not XCTest. Run via Make:

```bash
make test                     # KeyMappingManager
make test-clipboard-store     # ClipboardStore
make test-clipboard-monitor   # ClipboardMonitor
```

`swift test` will not work — there is no test target in `Package.swift`.

## Permissions

The app needs **Accessibility** access for its event tap (voice trigger, clipboard hotkey, key remap). Microphone + Speech Recognition prompts appear on first voice use.

Because the build is ad-hoc codesigned, every fresh `make build` is treated as a new identity by macOS — you must re-grant Accessibility after rebuilding.

## Source & Reproducibility

The full source lives in this repository.

> **Reproducibility guarantee:** this repository contains every file needed to produce **exactly** the distributed artifact. Clone it, run `make build`, get an identical `KeyMic.app` bundle.

A complete, unedited terminal recording of a build from source:

| Permission | Required for |
|---|---|
| Accessibility | Event tap (voice trigger, clipboard hotkey, key remap) |
| Microphone | Voice input |
| Speech Recognition | Voice-to-text transcription |
| Screen Recording | Screenshot capture |

## Architecture

See [`CLAUDE.md`](CLAUDE.md) for component layout and [`AGENTS.md`](AGENTS.md) for the macOS HID / event-tap gotchas.

## License

See the source repository for license details.
