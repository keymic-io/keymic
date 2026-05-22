# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

KeyMic is a single macOS menu-bar app (`LSUIElement`) that bundles several productivity layers inspired by Maccy (clipboard history), Karabiner (key remap), and skhd (shortcut hotkeys):

- **Voice input** — hold a trigger key (Fn or Right Option), speak, transcribed text is pasted into the focused field via simulated `Cmd+V`. Optional LLM refinement (OpenAI-compatible chat-completions endpoint).
- **Clipboard history** — text-only background monitor, SwiftData-backed storage, hotkey panel (`⌥V`) with search, arrow navigation, `⌥1`–`⌥0` quick paste.
- **Key mapping** — Karabiner-style modifier remaps applied via a session-level `CGEvent` tap (e.g. Right Cmd → Forward Delete, Caps Lock → Left Control).
- **Hotkey actions** — user-configurable shortcuts bound to `HotkeyAction` cases (`HotkeyConfig` + `HotkeyBindingsStore` + `HotkeyActionRunner`).
- **Agent tools** — Claude-Code-compatible tool layer. `Tools/Protocol/` hosts the `Tool` protocol + `ToolContext` + `ToolRegistry`. Concrete tools: `Tools/Bash/BashTool` (wraps `ShellRunner`), `Tools/File/` (`Read` / `Write` / `Edit` / `MultiEdit` + `FileSystemActor` enforcing path-safe sandbox). Foundation for future Search / MCP / Skill tools and an in-app agent loop.
- **Vault** — secret-aware clipboard escalation. `SecretScanner` (driven by bundled `gitleaks.toml`) classifies clipboard text; matches are persisted in macOS Keychain via `KeychainBackend` + `VaultStore`, surfaced through `VaultListView`.
- **Screenshot annotation** — selection overlay + editor (`Sources/KeyMic/Screenshot/`) for capture, pixelation, annotation, and export.
- **Auto-update** — Sparkle 2 EdDSA-signed appcast (`UpdaterController`).

All keyboard pillars share a single `CGEventTap` (`KeyMonitor`) and a single `AppDelegate`. `SingleInstance` (`flock` on a file in Application Support) prevents two copies running concurrently.

## Build, Run, Test

No Xcode project — SwiftPM + a Makefile that wraps `swift build` and assembles a `.app` bundle:

```bash
make build                    # release build (host arch) → ./KeyMic.app, codesigned with local identity "${CODESIGN_IDENTITY}"
make build-arm64              # arm64-only build
make build-x86_64             # x86_64-only build
make run                      # build then `open KeyMic.app`
make install                  # copy bundle to /Applications
make clean                    # swift package clean + rm -rf KeyMic.app

make test                     # KeyMappingManager tests
make test-clipboard-store     # ClipboardStore tests
make test-clipboard-monitor   # ClipboardMonitor tests
make test-all                 # run every standalone test runner

make release VERSION=1.2.3    # delegates to scripts/release.sh
scripts/release.sh -f 1.2.3   # `-f` overwrites existing v<VERSION> release + tag (local + remote)
```

`scripts/release.sh` builds both arches, merges via `lipo` into a universal binary, codesigns, packages with `ditto`, generates a Sparkle appcast (EdDSA via `~/.sparkle-tools/generate_appcast`, keychain account `ed25519`), deploys appcast.xml to the `gh-pages` branch (served via GitHub Pages), commits + pushes `Info.plist`, creates an annotated `v<VERSION>` git tag, and publishes a GitHub release on `keymic-io/keymic`.

**Tests are standalone `swiftc` runners**, not XCTest and not part of the Swift package. Each test file declares `@main` and prints `… passed` on success or exits non-zero. To add a new test target, add a `test-<name>:` rule to the `Makefile` listing every source file the test depends on.

`swift test` will fail — there is no test target in `Package.swift`. Always run via `make test*`.

## Architecture

### Wiring root: `AppDelegate`

`Sources/KeyMic/AppDelegate.swift` owns every long-lived component and connects them by callback:

- `KeyMonitor` → emits `onTriggerDown` / `onTriggerUp` (voice hold) and `onClipboardHotkey` (⌥V).
- Voice path: `triggerDown` → `SpeechEngine.startRecording` → partial results stream into `OverlayPanel` → release fires `triggerUp` → 2s grace timer → `finishTranscription` → optional `LLMRefiner.refine` → `TextInjector.inject`.
- Clipboard path: `onClipboardHotkey` → `ClipboardController.toggle` (showing `ClipboardPanel` SwiftUI view).

User-visible state lives in `UserDefaults` and is read on demand (no central settings object). Keys are scattered across components: `voiceEnabled`, `selectedLocaleCode`, `voiceTriggerKey`, `keyMappingEnabled`, `llmEnabled`/`llm*`, `ClipboardPreferences.*Key`, `HotkeyPreferences`, and `VaultConfig`.

### Event-tap layer (`KeyMonitor`)

Single `.cgSessionEventTap` watching `flagsChanged` + `keyDown` + `keyUp`. The callback dispatches in this order:

1. `remapIfNeeded` — if the keyCode matches a `KeyMappingManager` entry, synthesize the mapped event and **swallow the original** (`return .some(...)` from the callback). For modifier→non-modifier mappings (e.g. Right Cmd → Forward Delete), a `DispatchSourceTimer` posts auto-repeat keyDowns — the OS does not auto-repeat synthesized non-modifier events whose source is a modifier.
2. `⌥V` clipboard hotkey detection (`keyCode == 0x09`, `.maskAlternate` only).
3. Voice trigger state machine via `computeTriggerActive`.

`AGENTS.md` (repo root) documents the **non-obvious macOS HID gotchas** — read it before editing `KeyMonitor.swift`. Highlights:

- Apple keyboards emit arrow/fn-row keyDowns with `.maskSecondaryFn` already set; never read `event.flags.contains(.maskSecondaryFn)` directly to detect Fn — track via `flagsChanged` filtered by `keyCode == 0x3F`.
- Synthetic Caps Lock events do **not** flip system Caps Lock state. Use `IOHIDSetModifierLockState` via IOKit (`CapsLockToggler` in `KeyMonitor.swift`).
- Modifier keys' `flagsChanged` events have no down/up boolean — derive state by toggling a `Set<CGKeyCode>` or by reading the matching flag bit.

### Clipboard subsystem (`Sources/KeyMic/Clipboard/`)

- `ClipboardItem` — SwiftData `@Model`, persisted via `ModelContainer`. Falls back to in-memory store if disk init fails.
- `ClipboardStore` — CRUD + dedup (identical newest text only bumps `createdAt`) + truncation to `maxHistory`.
- `ClipboardMonitor` — polls `NSPasteboard.changeCount` every 0.5s on the main queue. Skips: own bundle ID, `ConfidentialClipboardType` (`org.nspasteboard.{Concealed,Transient,AutoGenerated}`), and the changeCount we just wrote ourselves (`markIgnoredChangeCount`). Polling, not callback-based — `NSPasteboard` has no change notification API.
- `ClipboardController` — coordinator. On paste: writes selected item, marks the resulting changeCount as ignored, reactivates the previously-frontmost app, then synthesizes `Cmd+V` after a 100ms delay.
- `ClipboardPanel` — borderless `NSPanel` (`.nonactivatingPanel`, `.canBecomeKey == true`) hosting a SwiftUI `ClipboardHistoryView`. The view uses a `@Query` against the shared `ModelContainer` and an embedded `KeyEventMonitor` `NSView` for arrow/return/⌥1–0/⌘⌫/Esc handling — SwiftUI's `.onKeyPress` is not used.

### Text injection (`TextInjector`)

`Cmd+V` synthesis must work even when a non-ASCII IME (e.g. Pinyin) is frontmost — those IMEs intercept `V`. The injector temporarily switches to an ASCII-capable input source via TIS APIs, posts the keystroke, restores the source after 300ms, and restores the original clipboard after 500ms.

### Vault (`Sources/KeyMic/Vault/`)

- `SecretScanner` — loads `Resources/gitleaks.toml` (a slimmed gitleaks ruleset, parsed by `MinimalTOMLParser`) to detect secrets in incoming clipboard text.
- `KeychainBackend` (protocol) + concrete macOS Keychain implementation. Service id: `io.keymic.app.vault`. Tests inject `InMemoryKeychainBackend` from `Tests/Support/`.
- `VaultStore` — orchestrator above `KeychainBackend`. `VaultMask` redacts values for display.
- `VaultListView` — SwiftUI list inside the settings window.
- Detected secrets are diverted from `ClipboardStore` into the vault per `VaultConfig` policy.

### Hotkey actions (`Sources/KeyMic/Hotkey/`)

- `HotkeyAction` — enum of invokable actions (toggle clipboard panel, screenshot, etc.).
- `HotkeyConfig` — modifier + keyCode descriptor with codable persistence.
- `HotkeyBindingsStore` — `UserDefaults`-backed map `HotkeyAction → HotkeyConfig`.
- `HotkeyActionRunner` — central dispatch invoked from `KeyMonitor` / menu / settings.
- `HotkeyRecorder` — settings UI capture surface.

### Agent loop (`Sources/KeyMic/Agent/`)

- `AgentSession` actor runs a multi-turn OpenAI tool-calling loop
  (`/v1/chat/completions` + `tools` + `tool_choice`). Returns
  `AsyncStream<AgentEvent>` for step-level events (`step`, `assistantMessage`,
  `toolCall`, `toolResult`, `done`, `error`).
- Tools come from a `ToolRegistry` snapshot at the start of each `run`. MCP
  tools must already be registered — `AppDelegate.applicationDidFinishLaunching`
  calls `MCPClientManager.loadAndConnectAll(registry:)` so they appear in the
  registry before any `AgentSession.run`. The 8 built-in tools (`Bash`, `Read`,
  `Write`, `Edit`, `MultiEdit`, `Glob`, `Grep`, `ActivateSkill`) are registered
  synchronously at the same time via `registerLocalTools()`.
- `allowedToolNames: Set<String>?` filters the registry; `nil` = all.
  Skill-driven runs parse `skill.metadata.allowedTools` via `AllowedToolsParser`
  (v1: name-level only; `Bash(git:*)` collapses to `Bash`).
- Error policy: per-tool failures/timeouts become `tool_result.is_error=true`
  and the loop continues. Transport errors, `notConfigured`, `maxSteps`,
  `maxWallTime`, and cancellation terminate with `.error`.
- Config: `agentAPIBaseURL` / `agentAPIKey` / `agentModel` UserDefaults keys,
  falling back to `llmAPI*` for zero-config bootstrap. The "Agent" settings tab
  edits them.
- Entry points (all via `AgentRunner`, a `@MainActor` helper):
  `SkillHotkeyBridge` consumer (replaces the Plan-5 textInjector consumer),
  `HotkeyAction.runAgent(prompt:)`, and `AgentSettingsTab`. `AgentSession`
  itself is unaware of Skills, Personas, Hotkeys, or UI.
- Transport: `OpenAIChatTransport` is the only concrete `_ChatTransport`. The
  protocol exists solely for test injection — production has exactly one
  conformer.

### Screenshot (`Sources/KeyMic/Screenshot/`)

`ScreenshotController` orchestrates: `ScreenCapturer` (ScreenCaptureKit) → `SelectionOverlayPanel`/`SelectionOverlayView` → `OverlayState`+`SelectionHandle` → `EditorToolbarPanel`/`EditorToolbarView` → `AnnotationModel`/`AnnotationRenderer`/`Pixelator` → `ScreenshotExporter` (PNG to disk + clipboard, prefix `KeyMic-`). `ToolbarPositioner` keeps the toolbar visible against screen edges.

### Updater (`Sources/KeyMic/Updater/UpdaterController.swift`)

Wraps `SPUStandardUpdaterController` from Sparkle 2. Reads `SUFeedURL` and `SUPublicEDKey` from `Info.plist`. The appcast is hosted on GitHub Pages (`gh-pages` branch), NOT in the main source tree. `Info.plist`/`SUFeedURL` points to `https://keymic-io.github.io/keymic/appcast.xml`. Update artifacts are signed by `scripts/release.sh` using the EdDSA private key in `scripts/keys/` (or whatever the `~/.sparkle-tools/generate_appcast --account` resolves). The release script deploys appcast.xml to the `gh-pages` branch via a temporary git worktree.

### Settings (`SettingsWindow`)

Custom AppKit panel with sidebar-style sections (`general`/`voice`/`llm`/`keyMapping`/`clipboard`). Tab views are built with `NSTabViewItem` but rendered manually inside `contentContainer` — `tabView.label` is unused. Communicates back to `AppDelegate` through `SettingsWindowDelegate`.

## Permissions & entitlements

`Info.plist` declares `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, and `NSScreenCaptureUsageDescription`. Bundle id `io.keymic.app`. The `KeyMic.entitlements` file at repo root is embedded at codesign time and grants `com.apple.security.device.audio-input` plus `com.apple.security.cs.disable-library-validation` (the latter for Sparkle's bundled helpers under the Hardened Runtime). KeyMic is **not** sandboxed — the session-level `CGEvent` tap is incompatible with `com.apple.security.app-sandbox`. The build is **codesigned with a local self-signed identity** (`codesign --sign ${CODESIGN_IDENTITY} --entitlements KeyMic.entitlements`, `--identifier io.keymic.app`); the Sparkle framework is signed deeply with the same identity but without the entitlements file. Important consequences:

- **Accessibility** must be granted to `KeyMic.app` for the event tap to receive events. The app shows a setup alert and quits if `CGEvent.tapCreate` returns `nil`.
- The signing identity is local; cdhash changes whenever the binary is rebuilt, so TCC permission may invalidate. After significant rebuilds, run `tccutil reset Accessibility io.keymic.app` (and Microphone/SpeechRecognition/ScreenCapture) and re-grant.
- `Info.plist` is hand-edited — keep it `plutil -lint`-clean. A malformed plist silently breaks LaunchServices icon registration **and** TCC bundle recognition (symptom: app icon missing, Privacy toggle has no effect).

## Conventions

- Swift 5 language mode (swift-tools-version 6.0 with `.swiftLanguageMode(.v5)`), target macOS 14. Source root: `Sources/KeyMic/`.
- One SwiftPM dependency: Sparkle 2 (`2.6.0..<3.0.0`).
- Logging: `os.Logger` with subsystem `io.keymic.app`. `LLMRefiner` additionally writes to `~/Library/Logs/KeyMic.log` for offline debugging.
- Singletons (`KeyMappingManager.shared`, `LLMRefiner.shared`) for cross-cutting state; everything else is owned by `AppDelegate`.
- Persistent locations: SwiftData store + lock file under `~/Library/Application Support/KeyMic/`; vault entries in macOS Keychain under service `io.keymic.app.vault`.
- Agent tools follow Claude-Code-compatible naming (`Read`/`Write`/`Edit`/`Bash`/`Glob`/`Grep`/...) and exchange JSON `Data` as input + string output, allowing `[any Tool]` arrays without associatedtype gymnastics. The `Tool` protocol lives in `Sources/KeyMic/Tools/Protocol/`; concrete tools live in sibling directories (`Tools/Bash/`, `Tools/File/`, `Tools/Search/`, `Tools/MCP/`, `Tools/Skill/`). The agent loop that drives those tools lives in `Sources/KeyMic/Agent/`. File tools share a `FileSystemActor` (in `Tools/File/`) that enforces a symlink-tolerant path-safe sandbox against `ToolContext.workingDirectory` and dispatches blocking IO off the cooperative pool. Search tools (`Glob` for filename patterns, `Grep` for regex content search) build on the same actor and re-validate every emitted path via `isPathSafe` to defeat symlink escapes.
- `AGENTS.md` (repo root) documents non-obvious macOS HID + TCC gotchas — read it before editing `KeyMonitor.swift` or codesign/Info.plist plumbing.
