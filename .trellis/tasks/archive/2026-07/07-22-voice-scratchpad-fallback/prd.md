# PRD — Voice scratchpad window when there is no editable target

## Goal / user value

When the user triggers voice input while focus is on a surface that cannot
accept the transcribed text, the text is currently lost silently (a Cmd+V into
a non-editable target is fire-and-forget with no feedback). Instead, KeyMic pops
a small temporary window with an editable text field pre-filled with the
transcript, lets the user keep editing it by keyboard, and offers a
"Copy & Close" action so the text is recoverable.

## Background — confirmed facts (from code)

- `.replaceFocusedText` (raw-dictation default) synthesizes Cmd+V and is
  **fire-and-forget**: `TextInjector.inject` returns `Void` and `CGEvent.post`'s
  result is discarded (`TextInjector.swift:34-142`, post at :107-108). Cmd+V
  success/failure is **undetectable after the fact** — so the trigger must be a
  *pre-flight* check, not post-hoc failure detection.
- Raw-dictation injection: `VoiceTrigger.injectAfterPop`
  (`VoiceTrigger.swift:424-429`), reached from the picker `.defaultInput` path
  (`:252`) and the persona-hotkey fallback (`:231`). Carries no `RouteResult`.
  It re-activates the originating app then injects after a 0.1 s delay.
- Persona path returns a real `RouteResult` from `OutputRouter.route`
  (`OutputRouter.swift:134-170`). `.replaceSelection` already falls back to
  clipboard with `.selectionNotEditable` / `.noFocusedElement` (`:144-154`);
  fallbacks/failures surface a HUD toast via `OverlayPanel.showRouteResult`
  (`OverlayPanel.swift:168-188`); `.injected` is silent.
- Editability probes live in `SelectionTextProvider`
  (`PersonaPlatform/Persona/SelectionTextProvider.swift`). `isSelectionEditable()`
  (`AXUIElementIsAttributeSettable` on `kAXSelectedText`) returns **false for
  AX-unsupported apps** (Electron/Chrome/VSCode/Slack/Discord) — which DO accept
  Cmd+V. A naive "false → divert" would badly regress those apps, so the trigger
  needs a **tri-state** probe (editable / non-editable / unknown), not a bool.
- Reusable window infra: `ClipboardPanel` (`.nonactivatingPanel`, `canBecomeKey`),
  `OverlayPanel`, and the `SwiftUISettingsWindow` NSPanel pattern. The scratchpad
  must become **key/activating** (unlike the non-activating overlays) so the user
  can type into it.

## Requirements

- **R1 — Raw-dictation trigger.** In `injectAfterPop`, after re-activating the
  originating app and before synthesizing Cmd+V, run a conservative editability
  probe against the focused element. If the probe is high-confidence
  "no editable target", open the scratchpad pre-filled with the transcript
  instead of pasting. Otherwise paste as today.
- **R2 — Conservative detection (no false positives).** Divert **only** on
  high-confidence non-editable: (a) no focused UI element
  (`kAXFocusedUIElement` fails/nil), or (b) focused element present but its role
  is non-editable **and** its value/selected-text is not settable.
  AX-unsupported / can't-tell → treated as **editable**, paste as today. Never
  regress Electron/Chrome/VSCode/Slack.
- **R3 — Persona-path trigger.** When `OutputRouter.route` returns
  `.fellBackToClipboard(reason:)` for an editability reason
  (`.selectionNotEditable` / `.noFocusedElement`), open the scratchpad
  pre-filled with the routed text. The pre-existing clipboard write on that path
  is kept (additive; intentional asymmetry with R1's no-auto-copy). `.failed`
  (URL/shell) stays a toast.
- **R4 — Editable scratchpad.** A key (focusable) window hosting a multi-line,
  scrollable, editable text field pre-filled with the text. The user can
  continue typing/editing with the keyboard.
- **R5 — Copy & Close.** A primary action (button + ⌘↩) writes the field's
  *current* text to `NSPasteboard.general` and closes the window. The write is
  recorded in clipboard history (not marked-ignored) so the content survives.
- **R6 — Discard.** Esc or a close control dismisses the window **without**
  writing the clipboard. No auto-copy on open.
- **R7 — Always on.** No settings toggle; the feature is unconditionally
  enabled.

## Acceptance criteria

- [ ] AC1: A pure decision helper (`shouldOpenScratchpad(for editability:)` or
  equivalent) returns `true` only for `.nonEditable`; `false` for `.editable`
  and `.unknown`. Covered by a standalone `swiftc` test runner + a `test-*`
  Makefile target (repo convention).
- [ ] AC2: Dictating with focus on a no-focused-field surface (Finder desktop,
  image/PDF viewer, a game) opens the scratchpad pre-filled with the transcript.
- [ ] AC3: Dictating into a native editable field (TextEdit, Notes, Safari
  address bar) pastes as before — no scratchpad.
- [ ] AC4 (regression guard): Dictating into an AX-unsupported-but-editable app
  (VSCode, Slack) pastes as before — NOT diverted to the scratchpad.
- [ ] AC5: "Copy & Close" writes the (possibly edited) text to the clipboard and
  closes; Esc closes without writing the clipboard.
- [ ] AC6: Manual typing/editing inside the scratchpad works while it is open.
- [ ] AC7: Persona `.replaceSelection` falling back for an editability reason
  opens the scratchpad with the routed text; `make build` clean; existing
  clipboard-fallback behavior preserved.

## Out of scope

- Detecting Cmd+V paste success after the fact (technically impossible).
- Auto-pasting the scratchpad text back into the originating app (it was
  non-editable by definition).
- Redesigning the persona/LLM pipeline (scratchpad is additive to the existing
  fallback).
- A manual "always open scratchpad" hotkey.

## Open questions

None blocking. Timing risk for reading the originating app's focused element
after KeyMic's overlay had focus is tracked in `design.md`.
