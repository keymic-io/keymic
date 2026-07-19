<h1 align="center">KeyMic</h1>

<hr>

<p align="center">
  <a href="https://twitter.com/intent/tweet?text=Check%20out%20KeyMic%20%E2%80%94%20keyboard,%20mic,%20clipboard%20for%20macOS&url=https%3A%2F%2Fgithub.com%2Fkeymic-io%2Fkeymic">
    <img alt="Tweet" src="https://img.shields.io/twitter/url?style=social&url=https%3A%2F%2Fgithub.com%2Fkeymic-io%2Fkeymic">
  </a>
</p>

<p align="center">
  ⌨️ <strong>Keyboard-first macOS productivity</strong> 🎙️<br>
  A signed, open-source menu-bar app that bundles voice input, clipboard history, key remapping, hotkey actions, and secret-aware vault — all driven by one shared event tap.
</p>

<p align="center">
  Available for macOS 14 Sonoma and later.
</p>

<p align="center">
  <a href="https://github.com/keymic-io/keymic/releases"><img alt="Release" src="https://img.shields.io/github/v/release/keymic-io/keymic"></a>
  <a href="https://github.com/keymic-io/keymic/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/keymic-io/keymic/total"></a>
  <a href="https://github.com/keymic-io/keymic/releases/latest"><img alt="Downloads@latest" src="https://img.shields.io/github/downloads/keymic-io/keymic/latest/total?label=downloads%40latest"></a>
  <a href="https://github.com/keymic-io/keymic/stargazers"><img alt="Stars" src="https://img.shields.io/github/stars/keymic-io/keymic?style=social"></a>
</p>

<p align="center">
  <a href="https://keymic.io"><strong>Website</strong></a>
  &nbsp;|&nbsp;
  <a href="#features"><strong>Features</strong></a>
  &nbsp;|&nbsp;
  <a href="#downloads"><strong>Downloads</strong></a>
  &nbsp;|&nbsp;
  <a href="#development"><strong>Development</strong></a>
  &nbsp;|&nbsp;
  <a href="#contribution"><strong>Contribution</strong></a>
</p>

<p align="center">
  This keyboard-first stack that could. Built with ❤️ by <a href="https://github.com/keymic-io">keymic-io</a> and <a href="https://github.com/keymic-io/keymic/graphs/contributors">contributors</a>.
</p>

---

## Why KeyMic

Most keyboard-first Mac workflows stitch together Karabiner + Maccy + Raycast + a dictation app. Each one ships its own update channel, its own permission prompts, its own event tap. KeyMic collapses that stack:

- **One signed binary, one event tap.** Lower CPU, fewer privacy dialogs.
- **Built for the hold-and-talk loop.** Voice input feels native, not bolted on.
- **Secrets stay out of clipboard history.** Tokens hit Keychain, not SwiftData.

---

## Features

### Remap — Unlock every forgotten key

Karabiner-style remaps without a separate daemon.

```
 ┌──────────┐                ┌────────────────┐
 │ Caps Lock│  ───────────►  │  Left Control  │
 └──────────┘                └────────────────┘

 ┌──────────┐                ┌────────────────┐
 │  Right ⌘ │  ───────────►  │ Forward Delete │
 └──────────┘                └────────────────┘
```

Session-level `CGEvent` tap. Modifier→modifier and modifier→key mappings. Auto-repeat handled for non-modifier targets.

---

### Voice — Hold, talk, paste

Hold a trigger key, speak, KeyMic transcribes and (optionally) routes through an LLM to clean up filler, punctuation, and casing before pasting.

```
   Hold ⌥R                              Release ⌥R
   ──────►                              ─────────►

  ┌────────────────────────────────────────────────────────┐
  │  ● Listening…                                          │
  │  "um so can you uh write a function that returns       │
  │   the first n fibonacci numbers in python thanks"      │
  └────────────────────────────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │  LLMRefiner                 │
              │  POST /v1/chat/completions  │
              │  model: gpt-4o-mini         │
              └──────────────┬──────────────┘
                             │
                             ▼
  ┌────────────────────────────────────────────────────────┐
  │  Refined transcript                              ⌘V    │
  │                                                        │
  │  Write a Python function that returns the first N      │
  │  Fibonacci numbers.                                    │
  └────────────────────────────────────────────────────────┘
```

Configurable system prompt (e.g. "Clean up speech-to-text. Keep meaning, fix grammar, drop filler"). Any OpenAI-compatible chat-completions endpoint works — OpenAI, Anthropic via gateway, local Ollama, vLLM, etc. Disable refinement to paste raw speech transcripts. IME-safe paste path for Pinyin and other non-ASCII input sources.

---

### Clipboard — Searchable history at `⌥V`

```
 ⌥V  ►  ┌───────────────────────────────────────────────┐
        │  🔍  Search clips…                            │
        ├───────────────────────────────────────────────┤
        │  ⌥1   https://keymic.io                  3m   │
        │  ⌥2   ~/code/keymic/Sources/KeyMic      11m   │
        │  ⌥3   let store = ModelContainer(…)      1h   │
        │  ⌥4   Quarterly review draft             2h   │
        │  ⌥5   #FF6A2C                            4h   │
        ├───────────────────────────────────────────────┤
        │  ↑ ↓  navigate   ⏎  paste    esc  close       │
        └───────────────────────────────────────────────┘
```

Dedups repeats. Skips transient, concealed, and self-generated clipboard writes. SwiftData store, in-memory fallback if disk init fails.

---

### Vault — Secrets never hit history

Every clipboard write runs through a gitleaks-derived scanner. Matches divert to macOS Keychain, plain text never lands in SwiftData history.

```
   Copy             ┌───────────────────┐
   "sk-proj-abc…"   │  SecretScanner    │
   ─────────────►   │  gitleaks rules   │
                    └─────────┬─────────┘
                              │ match
                              ▼
        ┌────────────────────────────────────────┐
        │  📋  Plain History                     │
        │      ─ urls, snippets, paths           │
        │                                        │
        │  🔒  Vault  (macOS Keychain)           │
        │      ─ sk-pro•••••••••••  masked       │
        └────────────────────────────────────────┘
```

Bundled `gitleaks.toml` ruleset. Service id `io.keymic.app.vault`. Masked display in the Vault list view.

---

### Shortcuts — Bind any hotkey to a sequence

Wire a hotkey to a typed string + keypress chain. Scope by app.

```
   ⌥K   ►   ┌──────────────────────────────────────┐
            │  Sequence                            │
            │  ─────────────────────────────────── │
            │  1.  type   "/clear"                 │
            │  2.  press  ⏎                        │
            │                                      │
            │  Scope:  Terminal · VSCode · Zed     │
            │          · Claude                    │
            └──────────────────────────────────────┘

   In Claude Code:
   ┌───────────────────────────────┐
   │ > /clear                      │
   │ (context cleared)             │
   └───────────────────────────────┘
```

Persisted in `UserDefaults`. Configure from the settings window.

---

### Screenshot annotation

Selection overlay → annotate → pixelate → export PNG to disk or clipboard.

```
   ┌───────── Screen ──────────────────────────────────────┐
   │                                                       │
   │     ┌─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐       │
   │     │                                          │       │
   │     │           selection region               │       │
   │     │                                          │       │
   │     └─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘       │
   │              ┌─────────────────────┐                  │
   │              │  ✎  A  ▢  ◯  🟦  ░  ⤓  │              │
   │              └─────────────────────┘                  │
   │                                                       │
   └───────────────────────────────────────────────────────┘
```

Toolbar repositions against screen edges. PNG filenames prefixed `KeyMic-`.

---

### Auto-update

Sparkle 2 with an EdDSA-signed appcast. The release script builds, signs, packages, tags, publishes, and pushes the appcast to GitHub Pages in one command.

---

## Downloads

```bash
brew install --cask keymic-io/tap/keymic
```

Or grab a signed build from [Releases](https://github.com/keymic-io/keymic/releases), or build from source (see [Development](#development)).

```bash
make build   # release build → ./KeyMic.app
make run     # build and launch
make install # copy to /Applications
```

First launch will request **Accessibility**, **Microphone**, **Speech Recognition**, and **Screen Recording** permissions in System Settings.

---

## Development

KeyMic is a single menu-bar app (`LSUIElement`) built with Swift, AppKit, SwiftUI, SwiftData, ScreenCaptureKit, Keychain Services, and Sparkle. No Xcode project — SwiftPM plus a Makefile.

Source layout:

- `Sources/KeyMic/AppDelegate.swift` — wires long-lived services together
- `Sources/KeyMic/KeyMonitor.swift` — shared global event tap
- `Sources/KeyMic/Clipboard/` — monitor, store, controller, panel
- `Sources/KeyMic/Hotkey/` — actions, bindings, recorder, persistence
- `Sources/KeyMic/Vault/` — secret scanning, Keychain storage, masking, UI
- `Sources/KeyMic/Screenshot/` — capture, selection, annotation, export
- `Sources/KeyMic/Updater/` — Sparkle integration

Build, code-signing, permissions, tests, and release flow → [`docs/BUILDING.md`](docs/BUILDING.md).

Deeper implementation notes: [`CLAUDE.md`](CLAUDE.md). macOS HID, event-tap, and TCC gotchas: [`AGENTS.md`](AGENTS.md).

---

## Contribution

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — basics
- [`SECURITY.md`](SECURITY.md) — vulnerability reporting
- Run `make test-all` before opening a pull request

Keep patches small. KeyMic touches macOS privacy, keyboard input, clipboard state, and signing — small reviewable changes are easier to land.

Licensed under AGPL-3.0. See [`LICENSE`](LICENSE).
