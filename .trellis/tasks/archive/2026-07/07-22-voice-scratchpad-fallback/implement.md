# Implement — Voice scratchpad fallback

## Ordered checklist

1. **Editability probe** — extend `SelectionTextProvider.swift`
   - Add `enum FocusEditability { case editable, nonEditable, unknown }`.
   - Add `static func focusedTargetEditability() -> FocusEditability` per
     design (resolve focused element → settable checks on `kAXSelectedText` /
     `kAXValue` → role classification). Reuse the focused-element resolution
     already in `axSelection()`.
   - Verify: `make build`.

2. **Pure decision helper** — new
   `Sources/KeyMic/PersonaPlatform/Triggers/VoiceScratchpadDecision.swift`
   - `shouldOpen(for:) -> Bool` returning `editability == .nonEditable`.
   - The `FocusEditability` enum it depends on must be reachable by a standalone
     `swiftc` runner. If compiling `SelectionTextProvider.swift` standalone pulls
     in AppKit/AX (fine for swiftc) keep the enum there; otherwise define
     `FocusEditability` in the decision file to keep the test target minimal.

3. **Test** — `Tests/VoiceScratchpadDecisionTests.swift` + Makefile target
   - `@main` runner: `.nonEditable → true`, `.editable → false`,
     `.unknown → false`.
   - Add `test-voice-scratchpad-decision:` rule listing the decision source
     (+ enum source if separate); add to the `test-all` list.
   - Verify: `make test-voice-scratchpad-decision`.

4. **Scratchpad UI** — `Sources/KeyMic/Scratchpad/`
   - `VoiceScratchpadView.swift` (SwiftUI: `TextEditor`, hint, Copy & Close
     button with ⌘↩, Esc cancel).
   - `VoiceScratchpadWindow.swift` (titled/activating window, `canBecomeKey`,
     centered, `NSHostingView`).
   - `VoiceScratchpadController.swift` (`present(text:)`, single reused window,
     `NSApp.activate` + `makeKeyAndOrderFront`; Copy&Close writes
     `NSPasteboard.general` without marking ignored; Esc/close discards).
   - Verify: `make build`.

5. **Wire raw dictation** — `VoiceTrigger.injectAfterPop` (`:424-431`)
   - Inject `VoiceScratchpadController` through `VoiceTrigger.init` (wire in
     `AppDelegate` graph, `AppDelegate.swift` ~ where `textInjector` / voice
     graph is built).
   - In the delayed block, after `activateOriginatingAppSync`, compute
     editability; if `shouldOpen` → `present(text:)` + Pop sound + return; else
     `inject`.
   - Verify: `make build`.

6. **Wire persona fallback** — `VoiceTrigger` route-result handling (`:312-316`)
   - On `.fellBackToClipboard(.selectionNotEditable | .noFocusedElement)`,
     present the scratchpad with the routed text; keep `.failed` / other results
     on `showRouteResult`.
   - Verify: `make build`.

7. **Full check** — `make test-all` (or at least the clipboard/voice/new
   target) + manual AC2–AC6.

## Validation commands

- `make build`
- `make test-voice-scratchpad-decision`
- `make test-all`
- Manual: `make run`, then dictate into (a) Finder desktop / Preview → scratchpad;
  (b) TextEdit / Safari address bar → normal paste; (c) VSCode / Slack → normal
  paste (regression guard); exercise Copy & Close and Esc.

## Risky files / rollback points

- `SelectionTextProvider.swift` — shared by selection read + voice picker
  preview; the new function is additive (new enum + new static func), does not
  touch `axSelection()`/`currentSelection()`. Low risk.
- `VoiceTrigger.swift` — behavior branch in the hot dictation path; guard so the
  `.editable`/`.unknown` cases are byte-for-byte the old `inject` path. Rollback
  = remove the branch, restore direct `inject`.
- `AppDelegate.swift` — DI wiring only.

## Notes

- Complex task: sub-agent-dispatch requires ≥1 real entry in `implement.jsonl`
  and `check.jsonl` before `task.py start`. Curate those (probe + wiring specs;
  regression-guard checks) as the last planning step.
- Do not `git add -A`; commit only the touched sources + test + Makefile.
