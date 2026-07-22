# Design — Voice scratchpad fallback

## Components

### 1. Editability probe (tri-state) — `SelectionTextProvider`

Add to `Sources/KeyMic/PersonaPlatform/Persona/SelectionTextProvider.swift`:

```swift
enum FocusEditability { case editable, nonEditable, unknown }

/// Conservative pre-flight classification of the current focused element.
/// - .editable    : focused element exposes a settable text value/selection.
/// - .nonEditable : focused element RESOLVES, is not settable, AND its role is a
///                  confidently non-editable role (e.g. AXOutline, AXStaticText).
///                  Only this case diverts to the scratchpad.
/// - .unknown     : AX could not decide — focus read failed / returned NoValue,
///                  role unreadable, or editable-ish/ambiguous role. Caller MUST
///                  treat .unknown as editable and paste (avoid regressions).
static func focusedTargetEditability() -> FocusEditability
```

Algorithm (corrected after live testing — see "Detection: verified behavior"):
1. Resolve `kAXFocusedUIElement` on the system-wide element.
   - Copy fails / NoValue / nil / not an AXUIElement → **`.unknown`** (NOT
     `.nonEditable`). Verified: Electron/Chromium apps (VSCode, Slack) return
     `kAXErrorNoValue` (-25212) here yet accept Cmd+V fine, so this is not a
     high-confidence "nowhere to type" signal.
2. Ask `AXUIElementIsAttributeSettable` for `kAXSelectedTextAttribute`, then
   `kAXValueAttribute`.
   - Either settable → **`.editable`**.
3. If neither is settable, read `kAXRoleAttribute`:
   - Editable-ish roles that sometimes mis-report settable
     (`AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`) → **`.unknown`**.
   - Confidently non-editable roles (`AXStaticText`, `AXImage`, `AXOutline`,
     `AXButton`, `AXMenuItem`, `AXMenuButton`, `AXCheckBox`, `AXRadioButton`)
     → **`.nonEditable`**. **`AXWebArea` and container roles (AXGroup /
     AXScrollArea / AXList / AXTable) are EXCLUDED** — a partial-AX web/Electron
     app can report a focused contenteditable as one of those with a non-settable
     value yet still accept Cmd+V.
   - Role missing / any AX error → **`.unknown`**.

Rationale for R2 (conservative, D2): `.unknown` is the safety bucket and is the
ONLY correct answer when AX can't decide. The single discriminator that makes
AC2 vs AC4 separable: a genuinely non-editable native surface (Finder desktop)
RESOLVES a focused element with a concrete non-editable role (`AXOutline`),
whereas AX-hidden editable apps FAIL the focus read (NoValue). We divert only on
the former. **Accepted trade-off**: a truly no-AX surface (some games, bare
viewers that also return NoValue) will NOT open the scratchpad — dictation there
Cmd+V's into nothing, same as before the feature. Chosen over the alternative
because diverting on NoValue would regress every Electron/Chromium editor.

### Detection: verified behavior (live AX probe data)

| Focus target | AX result | Verdict | Scratchpad? |
|---|---|---|---|
| VSCode / Slack (Electron) | `kAXFocusedUIElement` → NoValue (-25212) | `.unknown` | no (pastes) ✅ |
| Finder desktop | focus resolves, role `AXOutline`, not settable | `.nonEditable` | yes ✅ |
| TextEdit / Safari address bar | settable value/selection | `.editable` | no (pastes) ✅ |

### 2. Pure decision helper (unit-testable) — new file

`Sources/KeyMic/PersonaPlatform/Triggers/VoiceScratchpadDecision.swift`:

```swift
enum VoiceScratchpadDecision {
    static func shouldOpen(for editability: FocusEditability) -> Bool {
        editability == .nonEditable
    }
}
```

Separated so a standalone `swiftc` runner can test it without touching live AX
(mirrors `ClipboardHistoryKeyHandling`). AC1.

### 3. Scratchpad window — `Sources/KeyMic/Scratchpad/`

New controller + SwiftUI view (small, self-contained):

- `VoiceScratchpadController` (singleton or AppDelegate-owned): `present(text:)`
  reuses a single window instance; fills the text; makes it key & orders front;
  activates KeyMic (`NSApp.activate`) so the field is first responder.
- `VoiceScratchpadWindow`: a titled, resizable `NSWindow` (or activating
  `NSPanel` with `.titled`), centered on the active screen, hosting an
  `NSHostingView`. Must return `true` from `canBecomeKey`.
- `VoiceScratchpadView` (SwiftUI): a `TextEditor` bound to `@State text`,
  pre-filled; a short hint line ("No editable field — dictation captured here");
  a primary **Copy & Close** button (`.keyboardShortcut(.return, modifiers: .command)`)
  and the window's standard close (Esc via `.cancelAction` / window close).
  - Copy & Close: `NSPasteboard.general` clear + `setString(text)`, then close.
    Do **not** call `markIgnoredChangeCount` — we want it in clipboard history
    (R5). (Contrast: `ClipboardController`/`SelectionTextProvider` mark their own
    writes ignored; the scratchpad deliberately does not.)
  - Esc / close: dismiss, no clipboard write (R6).

### 4. Wiring

- **Raw dictation** — `VoiceTrigger.injectAfterPop` (`VoiceTrigger.swift:424-431`):
  after `activateOriginatingAppSync(originatingApp)` and before
  `textInjector.inject(text)`, compute
  `SelectionTextProvider.focusedTargetEditability()`. If
  `VoiceScratchpadDecision.shouldOpen(for:)` → present scratchpad with `text`,
  play the Pop sound, and return (skip inject). Else inject as today.
  - Inject `VoiceScratchpadController` into `VoiceTrigger` via its initializer
    (matches how `textInjector` is injected) rather than a new singleton, to
    keep AppDelegate the wiring root.
- **Persona path** — the scratchpad opens where the fallback toast is shown.
  `VoiceTrigger` already receives the `RouteResult` and calls
  `overlayPanel.showRouteResult` (`VoiceTrigger.swift:312-316`). Add: when the
  result is `.fellBackToClipboard(.selectionNotEditable | .noFocusedElement)`,
  present the scratchpad with the routed text (in addition to / instead of the
  toast). Keep `OutputRouter`'s existing `writeClipboard` on that path
  untouched. `.failed` unchanged.

## Data flow

```
trigger up → transcript
  ├─ raw dictation → injectAfterPop
  │     activate originating app
  │     editability = focusedTargetEditability()
  │     shouldOpen(.nonEditable)? ── yes → VoiceScratchpadController.present(text)
  │                                └─ no  → textInjector.inject(text)   (unchanged)
  └─ persona → PersonaEngine.run → OutputRouter.route → RouteResult
        .fellBackToClipboard(editability reason) → present(routedText)
        else → showRouteResult (unchanged)
```

## Trade-offs / risks

- **Timing (main risk).** The probe reads the *originating* app's focused
  element after KeyMic's picker/overlay had key focus.
  `activateOriginatingAppSync` runs first in `injectAfterPop`, so focus should be
  back on the target; but AX focus can lag activation. Mitigation: probe runs on
  the same 0.1 s-delayed main-queue block that already precedes inject, i.e.
  after activation. If flakiness appears, add a tiny settle or read the app's
  `kAXFocusedUIElement` via its PID rather than system-wide. Verify in AC2–AC4.
- **`.unknown` bias** deliberately favors pasting, so a genuinely non-editable
  Electron surface won't divert (accepted per D2 — safer than regressing
  editable Electron apps).
- **Focus stealing.** The scratchpad must activate KeyMic (LSUIElement app that
  normally never takes focus). This is inherent to letting the user type; scoped
  to only the no-editable-target case, so it does not affect normal dictation.
- **Clipboard-history capture.** `ClipboardMonitor` skips KeyMic's own bundle /
  ignored change counts. Confirm the Copy & Close write is actually recorded in
  history (it should be, since it is a normal write we do not mark ignored); if
  the monitor skips own-bundle writes unconditionally, note it and accept the
  clipboard still holds the text.

## Reuse

- Window/hosting pattern: `SwiftUISettingsWindow`, `ClipboardPanel`.
- Editability AX plumbing: extend `SelectionTextProvider` (same focused-element
  resolution as `axSelection()` / `axFocusedFieldValue()`).
- Pop sound + activate: `OutputRouter.activateOriginatingAppSync`, existing
  `NSSound(named: "Pop")`.
