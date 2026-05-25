# Clipboard Transformer (LOR-19 / R6)

> **Status:** Draft · 2026-05-22
> **Linear:** https://linear.app/lorne/issue/LOR-19
> **Parent epic:** [LOR-23 Voice + LLM Persona Platform](https://linear.app/lorne/issue/LOR-23)
> **Phase:** P2
> **Dependencies:**
> - [LOR-14 Persona system (Done)](https://linear.app/lorne/issue/LOR-14)
> - [LOR-15 OutputRouter (.clipboard strategy, shipped P1)](2026-05-21-lor-15-output-router.md)
> - [LOR-18 Context Sources](2026-05-22-lor-18-context-sources.md)

---

## 1. Context

Today the clipboard panel is read-only: ⌥V opens, you pick a row, paste. There's no way to *transform* what's in your history — translate three snippets to Chinese, summarise five paragraphs into one, reformat a list of URLs into a markdown table.

This spec adds **Clipboard Transformer** — a built-in persona that takes N clipboard items as input and produces ONE synthesised output. Triggered by ⌥L or a per-row magic-wand button. The result lands at the top of the clipboard history *and* on the system pasteboard.

The persona's behavior is defined by its `stylePrompt`, which the user can edit in Settings. No per-call instruction UI — this is a one-keystroke power tool, not a free-form chat.

## 2. Goals

- One built-in `Clipboard Transformer` persona; user can edit its `stylePrompt`, not its identity.
- ⌥L global hotkey + per-row magic-wand button as the two entry points.
- Multi-select in `ClipboardPanel` (currently single-select).
- N-to-1 reduce semantics: one LLM call with all selected items, one output, one new history entry.
- Result also lands on the pasteboard so the user can immediately ⌘V it elsewhere.

## 3. Non-Goals

- Per-item transforms (item-by-item LLM call) — covered by the LOR-16 panel's freeform invocation; this spec is explicitly N-to-1.
- Streaming output.
- Diff / undo UI for the produced result. Cmd+Z in the destination app + the original history rows still being present handles the undo case.
- Free-form instruction input at trigger time — the persona's `stylePrompt` is the only knob.
- Configurable hotkey targets (always invokes `builtin-clipboard-transformer`; users who want a different persona can edit its prompt).

## 4. User flow

```
1. User opens clipboard panel (⌥V).
2. User selects N rows:
   - Click → single select (current behavior).
   - ⌘+Click → toggle in/out of selection.
   - ⇧+Click → range select from last anchor.
3. User presses ⌥L (or clicks the "Transform" button bottom-right, or clicks the
   inline magic-wand on any row — the inline button selects only that row).
4. Panel shows inline "Transforming N items…" spinner (status bar at the bottom).
5. LLM completes:
   - Success → new ClipboardItem inserted at the top, pasteboard contains the
     result, panel scrolls to the new top row and highlights it briefly,
     spinner replaced with "Transformed N items".
   - Failure → status bar shows "Transform failed: <message>" for 3s, history
     untouched, pasteboard untouched.
6. User presses Esc to close the panel, or ⌘V in another app to paste the
   result.
```

## 5. Architecture

### 5.1 Module layout

```
Sources/KeyMic/Clipboard/
├── ClipboardTransformController.swift   // (new) batch invoke pipeline
├── ClipboardTransformPrompt.swift       // (new) pure helpers — composeBatchUserMessage()
├── ClipboardController.swift            // (modified) wire transform entry points
└── ClipboardHistoryView.swift           // (modified) multi-select + Transform button + magic-wand
```

### 5.2 New built-in persona

Added to `Persona.builtInSeeds()`:

```swift
Persona(
    id: "builtin-clipboard-transformer",
    name: "Clipboard Transformer",
    icon: "wand.and.stars",
    stylePrompt: """
        You will receive N clipboard items, each labelled [Item k]. Produce ONE concise output that
        synthesises / summarises / reformats them according to the implicit user intent (default:
        summarise into a single clear paragraph). Return ONLY the result — no preamble, no item
        labels, no markdown fences. Preserve the dominant language of the inputs.
        """,
    temperature: 0.4,
    hotkey: nil,
    contextSources: [.clipboardHistory],     // declarative — actual items passed via PersonaContext
    builtIn: true,
    injectionStrategy: .clipboard
)
```

Name + builtIn flag are immutable in PersonasView; `stylePrompt`, `icon`, `temperature` are user-editable (consistent with other built-ins).

### 5.3 ClipboardTransformPrompt helpers

`Sources/KeyMic/Clipboard/ClipboardTransformPrompt.swift` (Foundation-only, testable in isolation):

```swift
enum ClipboardTransformPrompt {
    /// Static fallback when PersonaStore lookup fails (mirrors the seed above).
    static let systemPromptFallback: String

    /// Builds the user message from selected items. Numbered, blank-line separated.
    ///   [Item 1]
    ///   <text>
    ///
    ///   [Item 2]
    ///   <text>
    ///
    ///   …
    static func composeBatchUserMessage(items: [String]) -> String

    /// Soft cap on combined input size (UTF-16 units). Returns nil if within cap,
    /// or an error label like "Combined input too large (123 KB > 100 KB cap)".
    static func validateSize(items: [String]) -> String?
}
```

Caps:
- Per-item: 50,000 UTF-16 units (~50 KB).
- Combined: 100,000 UTF-16 units (~100 KB).

Above caps → controller posts an error toast and bails before the LLM call.

### 5.4 ClipboardTransformController

```swift
@MainActor
final class ClipboardTransformController {
    init(store: ClipboardStore,
         llm: LLMRefiner = .shared,
         outputRouter: @autoclosure @escaping () -> OutputRouter = OutputRouter.shared,
         overlayPanel: OverlayPanel?)

    /// Public entry point. Called by ClipboardController.transformSelected().
    func transform(items: [ClipboardItem])
}
```

`transform(items:)` algorithm:

1. Guard: `items.isEmpty` → toast "Select at least one clipboard item", return.
2. Build `texts = items.map(\.text)`. Validate size (§5.3) — toast and return on failure.
3. Compose user message via `composeBatchUserMessage`.
4. Resolve system prompt: `PersonaStore.shared.persona(id: "builtin-clipboard-transformer")?.stylePrompt ?? ClipboardTransformPrompt.systemPromptFallback`.
5. Resolve temperature similarly (persona override, fallback 0.4).
6. Set `state.isRunning = true`, status "Transforming \(items.count) items…".
7. Await LLM via `withCheckedContinuation` around `llm.refine(_:systemPrompt:temperature:completion:)`.
8. On success:
   - `store.add(text: result, sourceBundleID: Bundle.main.bundleIdentifier, sourceAppName: "Clipboard Transformer")` — new top entry.
   - `outputRouter().route(PersonaOutput(text: result, strategy: .clipboard, originatingApp: nil, context: nil))` — syncs pasteboard, fires `onMarkIgnored` so `ClipboardMonitor` doesn't ingest the same string a second time.
   - Status "Transformed \(items.count) items" for 2s, then clear.
9. On failure: status "Transform failed: \(error.localizedDescription)" for 3s. History + pasteboard untouched.

The controller does NOT close the panel — the user typically wants to see the new top row.

### 5.5 ClipboardHistoryView multi-select

Replace `@State var selectedID: UUID?` with `@State var selectedIDs: Set<UUID> = []` and a separate `@State var lastClickedID: UUID?` (range anchor).

Click handlers (passed to each row):

| Modifier | Behavior |
|---|---|
| (none) | `selectedIDs = [id]; lastClickedID = id` |
| ⌘+Click | `selectedIDs.toggle(id); lastClickedID = id` |
| ⇧+Click | `selectedIDs.formUnion(range(lastClickedID...id))` — last-anchor unchanged |

Single-select consumers (Enter / quick paste / ↑↓ navigation) read a derived `primarySelection: UUID?`:

```swift
private var primarySelection: UUID? { selectedIDs.count == 1 ? selectedIDs.first : nil }
```

- Enter / ⌥1…⌥0 / context-menu Paste: disabled when `primarySelection == nil`.
- ↑↓ navigation: clears `selectedIDs` to a single new row (`selectedIDs = [newID]`); range anchor follows.

**New bottom-bar "Transform" button** (right side, next to existing Paste button):

```
[ wand.and.stars  Transform ]    disabled when selectedIDs.isEmpty
```

Click → `ClipboardController.transformSelected()`.

**Inline magic-wand button per row** (between existing Pin icon and dismiss):

- Hover-revealed (matches existing row affordances), SF Symbol `wand.and.stars`.
- Click → `selectedIDs = [row.id]; ClipboardController.transformSelected()`.

### 5.6 ClipboardController wiring

`Sources/KeyMic/Clipboard/ClipboardController.swift`:

```swift
weak var transformController: ClipboardTransformController?

func transformSelected() {
    let items = currentSelectedItems()
    if items.isEmpty {
        if !isPanelVisible {
            toggle(initialTab: .clipboard)
            overlayPanel?.showTransientToast(
                String(localized: "Select items to transform"),
                durationSeconds: 2.0
            )
        }
        return
    }
    transformController?.transform(items: items)
}

private func currentSelectedItems() -> [ClipboardItem] {
    // 1. panel open + non-empty selectedIDs → return those items
    // 2. panel open + empty selectedIDs → return cursor row (1 item)
    // 3. panel closed → return []
}
```

The view publishes its selection back to the controller via a small `ClipboardPanelSelectionBridge` (an `@Observable` class owned by `ClipboardController`, bound into the SwiftUI view as `@Bindable`).

### 5.7 Hotkey path

`HotkeyFeature.clipboardTransform` (default `alt+l`) → `KeyMonitor.onClipboardTransformHotkey` → `AppDelegate` → `clipboardController.transformSelected()`. Mirrors LOR-16's `selectedTextEditor` hotkey wiring exactly (regular keyDown + F-row paths in `KeyMonitor`).

`HotkeyRegistry.Owner.clipboardTransform` registered in `AppDelegate.applicationDidFinishLaunching` built-in seed list.

### 5.8 Settings UI

Clipboard tab gains a "Transform: ⌥L" row alongside the existing ⌥V clipboard panel hotkey, using the same `HotkeyRecorderWithClear` pattern as the other feature hotkeys.

PersonasView shows `builtin-clipboard-transformer` in the persona list (immutable name, lock icon, editable `stylePrompt` / `temperature`) — automatic because PersonasView already iterates `PersonaStore.shared.personas`.

## 6. Prompt design

Single user message, system prompt comes from the persona's `stylePrompt`:

**System prompt** (editable in Settings):

```
You will receive N clipboard items, each labelled [Item k]. Produce ONE concise output that
synthesises / summarises / reformats them according to the implicit user intent (default:
summarise into a single clear paragraph). Return ONLY the result — no preamble, no item
labels, no markdown fences. Preserve the dominant language of the inputs.
```

**User message** (constructed by `composeBatchUserMessage`):

```
[Item 1]
<items[0].text>

[Item 2]
<items[1].text>

[Item 3]
<items[2].text>
```

Items in user-selection order (top-of-history first when selection spans multiple rows).

## 7. Logging

Subsystem `io.keymic.app`, category `ClipboardTransformer`.

- `.debug` on trigger: `count=N` + total chars + persona id (no item text).
- `.debug` on result: outcome enum, output chars.
- `.error` on LLM failure: error description (no item text).
- **No PII**: never log clipboard item content.

## 8. Test Strategy

`make test-clipboard-transform` (new runner, Foundation-only):

- `composeBatchUserMessage([])` → empty string.
- `composeBatchUserMessage(["one"])` → `"[Item 1]\none"`.
- `composeBatchUserMessage(["a", "b"])` → `"[Item 1]\na\n\n[Item 2]\nb"`.
- `composeBatchUserMessage` preserves item ordering.
- `validateSize` returns nil under cap, error string over cap (per-item and combined).
- `validateSize` empty array → nil.

Integration tests with stubbed `LLMRefiner` + `ClipboardStore` + `OutputRouter` are deferred per project convention (KeyMic prefers pure-logic tests + manual smoke).

PersonaTests / PersonaStoreTests / PersonaInjectionStrategyTests synchronously bump to 6 built-in seeds + new `contextSources` mapping (covered in LOR-18 spec).

### Manual smoke matrix

| Setup | Action | Expected |
|---|---|---|
| ⌥V open, no selection | ⌥L | toast "Select items to transform", no LLM call |
| ⌥V open, ⌘+click 3 items | ⌥L | spinner → new top row + pasteboard set + status "Transformed 3 items" |
| ⌥V open, click 1 item | ⌥L | N=1 transform, new top row appended |
| Hover row, click magic-wand | — | row becomes sole selection, transform runs |
| Panel closed | ⌥L | panel opens to clipboard tab + "Select items to transform" toast |
| ⌥V open, multi-select | Enter | ignored (or status hint "Press ⌥L to transform multiple") |
| ⌥V open, multi-select | ↑/↓ | falls back to single select on the new row |
| Combined input > 100 KB | ⌥L | error toast "Combined input too large", no LLM call |
| LLM offline / no API key | ⌥L | error toast with LLMRefiner's error text, history untouched |
| Pasteboard contains result | ⌘V in another app | result pastes verbatim |

## 9. Open Questions

- **Should multi-select extend to ⌥1…⌥0 quick-paste in some way?** Proposal: no — quick paste is a single-row affordance; multi-select is for transform only.
- **Should the new top row carry a visible "transformed from N items" badge?** Proposal: not in P2 — `sourceAppName == "Clipboard Transformer"` is enough metadata; revisit if users complain about losing provenance.
- **Settings location for the ⌥L row** — Clipboard tab (alongside ⌥V) or General → Hotkeys (alongside the LOR-16 row)? Proposal: Clipboard tab, because it's clipboard-domain functionality. Confirm at implementation time.
- **Behavior when the user edits the persona's `contextSources`** to remove `.clipboardHistory` and adds, say, `.selection`. Proposal: the trigger pipeline ignores `contextSources` (it always passes clipboard items) — the field is declarative metadata for PersonaContext consumers, not a runtime gate here. Document in `stylePrompt`'s Settings field.

## 10. Acceptance Criteria

- [ ] ⌥L (or configured hotkey) transforms the current ClipboardPanel selection into one new top-of-history entry, with the result also on the pasteboard.
- [ ] Per-row magic-wand button transforms just that row, identical pipeline.
- [ ] ClipboardPanel supports ⌘+click toggle and ⇧+click range selection.
- [ ] Bottom-bar "Transform" button is enabled iff `selectedIDs` non-empty.
- [ ] ⌥L with empty selection but panel open: takes cursor row (1 item).
- [ ] ⌥L with panel closed: opens panel + posts toast; does not invoke LLM.
- [ ] Combined input > 100 KB rejected with toast; no LLM call.
- [ ] LLM failure leaves history + pasteboard untouched; user sees the error.
- [ ] `builtin-clipboard-transformer` appears in PersonasView (immutable name + builtIn lock, editable stylePrompt + temperature).
- [ ] `make test-clipboard-transform` passes (pure-logic helpers).
- [ ] Manual smoke matrix in §8 fully green.
