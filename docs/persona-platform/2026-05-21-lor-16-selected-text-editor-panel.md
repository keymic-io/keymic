# Selected Text Editor Panel (LOR-16 / R4)

> **Status:** Draft · 2026-05-21
> **Linear:** https://linear.app/lorne/issue/LOR-16
> **Parent epic:** [LOR-23 Voice + LLM Persona Platform](https://linear.app/lorne/issue/LOR-23)
> **Phase:** P1
> **Dependencies:**
> - [LOR-14 Persona system (Done)](https://linear.app/lorne/issue/LOR-14)
> - [LOR-17 Selected Text Reader](2026-05-21-lor-17-selected-text-reader.md)
> - [LOR-15 OutputRouter (P1 subset: `.replaceSelection` + `.clipboard`)](2026-05-21-lor-15-output-router.md)
> - `HotkeySettingsStore` (already shipped)

---

## 1. Context

The single most compelling Persona Platform demo: user selects text anywhere, hits a hotkey, a tiny panel pops up next to the selection. They speak an instruction (or type one), and the selection gets rewritten in place.

This is the user-visible payoff of the abstraction layer — it stitches **SelectionReader + Persona + OutputRouter** into one obvious workflow.

It also doubles as a clipboard-fallback proving ground: when the selection is in Safari read-only text, we still produce useful output by copying to clipboard with a clear toast.

## 2. Goals

- One-keystroke entry from any app: select → hotkey → mini panel appears at the caret/selection.
- Voice-first input: hold a button to record, release to transcribe.
- Keyboard-first power-user path: type instruction, hit Enter.
- Quick-action chips (expand / shrink / translate / polish / free-form).
- Result replaces selection if editable, else falls back to clipboard with a toast.
- Visual continuity with KeyMic's existing overlay aesthetic (capsule, blurred background, system font).

## 3. Non-Goals

- Multi-turn chat / regeneration inside the panel (single shot only at P1).
- Diff preview before applying ("here's the proposed rewrite, accept/reject"). Possible follow-up.
- Persistent history of past edits.
- Configurable action chips (built-in list only at P1; users can add custom personas through Settings but the chip set is fixed).
- Working without a selection ("just open the panel anywhere"). At P1, no selection ⇒ no panel.

## 4. User flow

```
1. User selects text in any app.
2. User presses ⌥E (configurable via HotkeySettingsStore).
3. KeyMic reads selection via SelectedTextReader.
   - If selection is empty: brief toast "No selection — select text first", panel does NOT open.
   - If AX denied: toast "Accessibility permission needed" + Open Settings link.
4. Panel appears near the selection (clamped to screen).
   - Header: app icon + truncated selection preview (first 80 chars + "…" + char count).
   - Chip row: [Expand] [Shrink] [Translate] [Polish] [Custom…].
   - Voice button (hold to record) + text input field (focusable for typing).
   - Status line: hidden initially.
5. User chooses one of:
   a. Hold voice button → speak → release → transcript appears in input field
      (visible preview, not auto-submitted).
   b. Type into input field.
   c. Click a chip (no instruction required — chip name IS the instruction).
6. User commits by pressing Enter or clicking [Apply].
7. KeyMic builds prompt:
      systemPrompt = GeneralEditor base prompt + chosen action template
      userText = "Selected text:\n<selection>\n\nInstruction:\n<typed-or-spoken>"
8. LLM call (LLMRefiner) → result string.
9. OutputRouter.route(PersonaOutput(strategy: .replaceSelection, ...))
   - Editable: text replaced in place. Panel closes. Brief success toast (optional).
   - Not editable: text on clipboard. Panel stays open showing the result + "Copied" toast.
   - LLM failure: panel shows inline error, no injection.
10. Esc dismisses panel without applying.
```

## 5. Architecture

### 5.1 Module layout

```
Sources/KeyMic/SelectedTextEditor/
├── SelectedTextEditorController.swift   // public entry point, owned by AppDelegate
├── SelectedTextEditorPanel.swift        // NSPanel host
├── SelectedTextEditorView.swift         // SwiftUI body
├── SelectedTextEditorState.swift        // @Observable state
└── EditorAction.swift                   // chip/action enum
```

### 5.2 Public entry point

```swift
@MainActor
final class SelectedTextEditorController {
    init(
        outputRouter: OutputRouter,
        llm: LLMRefiner = .shared,
        speechEngine: SpeechEngine,
        personaStore: PersonaStore = .shared
    )

    /// Called by HotkeyActionRunner when the user fires the editor hotkey.
    /// Reads selection, opens the panel positioned near it.
    /// No-op (with toast) if no selection or AX denied.
    func open()
}
```

`AppDelegate` constructs and retains one instance. The existing `HotkeyActionRunner` invokes `open()` for the new `HotkeyFeature.selectedTextEditor` case (added to `HotkeyFeature` enum).

### 5.3 Hotkey registration

Add to `HotkeyFeature` (defined in already-shipped HotkeySettingsStore spec):

```swift
case selectedTextEditor    // default ⌥E
```

Add default mapping in the seed function so existing installs pick it up on next launch.

### 5.4 State model

```swift
@Observable
final class SelectedTextEditorState {
    var selectionPreview: String = ""
    var selectionFullText: String = ""
    var selectionIsEditable: Bool = false
    var instructionText: String = ""
    var selectedAction: EditorAction = .freeForm
    var isRecording: Bool = false
    var isRunning: Bool = false
    var result: String?
    var errorMessage: String?
    var routeResult: RouteResult?       // set after apply, drives toast
}
```

### 5.5 Action enum

```swift
enum EditorAction: String, CaseIterable, Identifiable {
    case expand
    case shrink
    case translate          // detect input language → English (mirrors builtin-translate)
    case polish
    case freeForm           // pure instruction, no preset template

    var id: String { rawValue }

    /// Returned to the prompt builder.
    var promptTemplate: String { ... }   // see §6 below
}
```

### 5.6 Panel host

`SelectedTextEditorPanel: NSPanel`, styled like `OverlayPanel`:

- `.borderless`, **but** `canBecomeKey = true` (unlike OverlayPanel) — the panel needs first-responder focus for the text field.
- `.nonactivatingPanel` style flag → does NOT steal app focus from the originating window's process, so the user's text selection survives.
- `level = .floating`, `collectionBehavior = [.canJoinAllSpaces]`.
- Esc key handler closes the panel (`NSPanel.cancelOperation`).
- Auto-dismiss on resign-key after a 200 ms grace (avoid flicker on transient focus loss while OS animates).

### 5.7 Panel positioning

Default position: center-bottom of the focused element's bounding rect, with a 12 pt offset.

1. Try `SelectedTextReader.boundingRectOfSelection()` (new helper — reads `kAXBoundsForRangeParameterizedAttribute` if available).
2. Fallback: position relative to mouse cursor.
3. Clamp to current screen visible frame.

`boundingRectOfSelection` is a stretch goal — if AX boundary support is flaky, P1 ships with mouse-cursor positioning and we file a follow-up. Spec the API surface now, allow the implementation to start with the cursor fallback.

## 6. Prompt design

A single built-in persona `GeneralEditor` (added to `Persona.builtInSeeds()`), with an action-specific suffix appended at request time.

**Base system prompt:**

```
You are a precise editor that rewrites a user's SELECTED text according to a brief
INSTRUCTION. Return ONLY the rewritten text — no preamble, no explanations, no quotes,
no markdown fences. Preserve the original language unless the instruction asks otherwise.
```

**Per-action suffix (appended to instruction):**

| Action | Instruction sent to LLM |
|---|---|
| `.expand` | "Expand the selected text by ~30% with relevant detail. Stay on topic." |
| `.shrink` | "Make the selected text more concise. Preserve meaning. Aim for ~40% shorter." |
| `.translate` | "Translate the selected text into English. Keep tone and terminology." |
| `.polish` | "Polish grammar, clarity, and flow without changing meaning." |
| `.freeForm` | "<user's typed/spoken instruction verbatim>" |

When the user types/speaks an instruction AND a non-`.freeForm` chip is selected, both are concatenated with `"\n\n"` (instruction takes priority).

**User message:**

```
[Selected text]
<full selection — not the truncated preview>

[Instruction]
<resolved instruction from §6 table>
```

## 7. Voice integration

Reuse the **existing** SpeechEngine — do NOT spin up a parallel pipeline.

- `SelectedTextEditorController` owns a dedicated `VoiceSession` distinct from the main voice trigger session, so a recording in the panel doesn't collide with `KeyMonitor`'s Fn-key voice trigger.
- Press-and-hold on the panel's voice button calls `speechEngine.startSession(locale: …)`.
- Partial results stream into `state.instructionText` (visible).
- Release ends the session → final transcript replaces `instructionText`.
- The panel **does not auto-apply** after the voice transcript lands. User must press Enter / click Apply. This is intentional: voice in this context is for instruction entry, not text injection — premature auto-apply makes the panel feel jumpy and reduces user control over the final prompt.

Rationale: the press-and-hold UX is consistent with KeyMic's primary voice trigger, lowering the learning curve.

## 8. Apply path

```swift
func apply() async {
    state.isRunning = true
    defer { state.isRunning = false }

    let resolvedInstruction = buildInstruction(from: state)
    let userText = "[Selected text]\n\(state.selectionFullText)\n\n[Instruction]\n\(resolvedInstruction)"
    do {
        let refined = try await llm.refine(
            userText,
            systemPrompt: GeneralEditor.systemPrompt,
            temperature: 0.4
        )
        state.result = refined

        let output = PersonaOutput(
            text: refined,
            strategy: state.selectionIsEditable ? .replaceSelection : .clipboard,
            originatingApp: originatingApp,
            context: .init(selection: state.selectionFullText, clipboardTop: nil)
        )
        let result = await OutputRouter.shared.route(output)
        state.routeResult = result

        switch result {
        case .injected:                 closePanel()
        case .fellBackToClipboard:      keepPanelOpenShowingResult()
        case .userCancelled, .failed:   keepPanelOpenShowingError()
        }
    } catch {
        state.errorMessage = error.localizedDescription
    }
}
```

## 9. UI specification

**Frame:** 420 pt wide; height adapts to content (range 140–320 pt).

**Layout (top to bottom, 16 pt vertical rhythm):**

1. **Header row** — app icon (24 pt) + truncated selection (single line, dimmed). On hover, expand to multi-line tooltip.
2. **Chip row** — horizontal scrollable on overflow. Selected chip uses accent fill.
3. **Instruction input** — `NSTextField` styled as bordered rounded rect, single-line; growing to multi-line if `\n` is pressed via Shift+Return. Placeholder: "Type, or hold ⏺ to speak".
4. **Voice button** — circular, 32 pt, holds-down state with red accent + ripple on the OverlayPanel's wave anim primitive (reuse the smoothed level path from OverlayPanel for visual unity).
5. **Apply button** — accent-tinted; disabled while `state.isRunning` or instruction empty AND `selectedAction == .freeForm`.
6. **Status line** — shows running spinner, error message, or clipboard-fallback toast.

**Color & fonts:** reuse OverlayPanel's `labelFont` and capsule background (NSVisualEffectView, .hudWindow material).

## 10. Keyboard map (inside panel)

| Key | Action |
|---|---|
| Enter | Apply |
| Shift+Enter | Insert newline in instruction field |
| Esc | Close without applying |
| ⌘1…⌘5 | Select chip 1..5 |
| Space (when text field empty) | Start voice recording (hold) |

## 11. Test Strategy

`make test-selected-text-editor` (new runner under `Tests/SelectedTextEditor/`).

### Pure-logic

- `EditorAction.promptTemplate` is non-empty for every case.
- `SelectedTextEditorController.buildInstruction(state:)` correctness:
  - `.freeForm` + typed → user text verbatim
  - `.polish` + empty typed → action template only
  - `.polish` + typed → action template + "\n\n" + typed
- `SelectedTextEditorController.composeUserMessage(selection:instruction:)` formats the two labelled blocks correctly.

### Integration with stubs

- Stub `LLMRefiner` (records calls), stub `OutputRouter` (returns canned `RouteResult`), stub `SelectedTextReader`.
- `open()` with empty selection → no panel created, toast posted.
- `open()` with editable selection → panel state populated correctly.
- `apply()` with editable selection → router called with `.replaceSelection`.
- `apply()` with non-editable selection → router called with `.clipboard`.

### Manual smoke matrix

| App | Selection | Action | Expected |
|---|---|---|---|
| TextEdit | a paragraph | Polish | replaced in place, panel closes |
| TextEdit | a paragraph | Translate | replaced in place |
| VS Code | a code comment | Polish via voice | replaced in place |
| Safari `<textarea>` | text | Shrink | replaced in place |
| Safari article body (read-only) | text | Polish | clipboard fallback toast, panel stays open showing result |
| Notes.app | bullet | Expand | replaced |
| No selection | (hotkey only) | — | toast "No selection", panel does not open |
| AX denied | — | — | toast + Open Settings link |

## 12. Settings UI

`PersonasView` already supports per-persona hotkey assignment.

Additionally, surface the new `HotkeyFeature.selectedTextEditor` in the existing "Hotkeys" tab of Settings as a recordable hotkey row, default ⌥E.

The `GeneralEditor` built-in persona shows up in the personas list as a normal built-in (immutable name + builtIn flag; editable stylePrompt for power users).

## 13. Logging

Subsystem `io.keymic.app`, category `SelectedTextEditor`.

- `.debug` — open with selection char count, action chosen, route result enum, total elapsed ms.
- `.error` — LLM failure (error description), AX permission missing.
- **No PII**: never log selection text or instruction text content.

## 14. Open Questions

- **Should the panel persist its position across invocations**, or always re-anchor to the latest selection? Proposal: always re-anchor — it's an in-context tool, not a floating workspace.
- **What happens if the user clicks outside the panel during the LLM call?** Proposal: keep panel open (since `nonactivatingPanel` + `canBecomeKey=true` but no resign-key auto-close while `isRunning == true`); cancel the LLM call only on explicit Esc.
- **Should `Translate` chip detect target language from system locale** (e.g. user on zh-CN system → "Translate to Chinese") instead of always English? Proposal: P1 ships English-only to match `builtin-translate`; revisit when we add locale-aware personas.

## 15. Acceptance Criteria

- [ ] ⌥E (or configured hotkey) opens the editor panel near the selection in any app with editable text.
- [ ] Empty selection / missing AX permission produces a toast, no panel.
- [ ] All five chips produce visibly different LLM outputs for the same selection.
- [ ] Hold-to-record voice button transcribes into the instruction field; Enter applies.
- [ ] Esc closes the panel without applying; the selection in the originating app is untouched.
- [ ] Editable destination → in-place replace via `.replaceSelection`.
- [ ] Non-editable destination → clipboard fallback with toast.
- [ ] LLM failure shows inline error inside the panel; selection remains untouched.
- [ ] `make test-selected-text-editor` passes.
- [ ] Manual smoke matrix in §11 fully green.
