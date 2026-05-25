# Persona Context Sources (LOR-18 / R5)

> **Status:** Draft · 2026-05-22
> **Linear:** https://linear.app/lorne/issue/LOR-18
> **Parent epic:** [LOR-23 Voice + LLM Persona Platform](https://linear.app/lorne/issue/LOR-23)
> **Phase:** P2
> **Dependencies:** [LOR-14 Persona system (Done)](https://linear.app/lorne/issue/LOR-14)
> **Consumers:** [LOR-19 Clipboard Transformer](2026-05-22-lor-19-clipboard-transformer.md), [LOR-20 Window OCR](https://linear.app/lorne/issue/LOR-20), any future persona needing fine-grained context selection

---

## 1. Context

Today every persona has a coarse `contextMode: ContextMode` with two values:

```swift
enum ContextMode: String, Codable, CaseIterable {
    case none
    case selectionAndClipboard
}
```

That works for P1 but two upcoming phases need finer control:

- **LOR-19 Clipboard Transformer** wants `[clipboardHistory]` *without* selection (the user is operating inside the clipboard panel; the focused-app's selection is irrelevant).
- **LOR-20 Window OCR** will add `[windowOCR]` and may combine with `[selection]` for "explain what's on screen near my selection".

Both demand multi-select with future expansion. This spec replaces `contextMode` with a typed, multi-valued `contextSources: Set<ContextSource>` field on `Persona`.

## 2. Goals

- One typed enum (`ContextSource`) covering selection, clipboard top, clipboard history, window OCR.
- Multi-select via `Set<ContextSource>`.
- Backward-compatible Codable migration from existing on-disk personas using `contextMode`.
- Centralized prompt assembly: `PersonaContext.buildPrompt(transcript:sources:)` is the single source of truth — callers pass the set, get back the labelled prompt.

## 3. Non-Goals

- New context providers (selection / clipboard / OCR mechanisms themselves) — those land per-source spec (LOR-17/19/20).
- Per-call source override at LLM invocation (sources are declared on the persona, not at the callsite).
- Source ordering by user preference — sections are emitted in a canonical order defined by this spec.
- UI for editing `contextSources` in PersonasView — covered in a follow-up; this spec only ships the model layer.

## 4. Public API

**File:** `Sources/KeyMic/LLM/ContextSource.swift` (new)

```swift
import Foundation

enum ContextSource: String, Codable, CaseIterable, Hashable {
    case selection         // focused element's selected text (via SelectionTextProvider / LOR-17 SelectedTextReader)
    case clipboardTop      // NSPasteboard.general.string(forType: .string)
    case clipboardHistory  // recent N items from ClipboardStore (N supplied by consumer)
    case windowOCR         // placeholder — provider lands with LOR-20

    var displayName: String { ... }   // localized
}
```

**File:** `Sources/KeyMic/LLM/Persona.swift`

```swift
struct Persona: Codable, Identifiable, Equatable {
    // …
    var contextSources: Set<ContextSource>   // replaces `contextMode`
    // …
}
```

**File:** `Sources/KeyMic/LLM/PersonaContext.swift`

```swift
extension PersonaContext {
    /// Builds the labelled user prompt for an LLM call.
    /// Sections are emitted in this fixed order when present:
    ///   [Selected text] → [Recent clipboard] → [Clipboard history] → [Window text] → [User said]
    /// Empty sources / nil providers produce no section.
    /// Caps the result at 7500 UTF-16 units, snapped to character boundary (unchanged from P1).
    func buildPrompt(transcript: String, sources: Set<ContextSource>) -> String
}
```

### Codable migration

`Persona.init(from:)` decodes in this priority:

1. If `contextSources` field is present → use it verbatim.
2. Else if legacy `contextMode` field is present:
   - `.none` → `[]`
   - `.selectionAndClipboard` → `[.selection, .clipboardTop]`
3. Else → `[]` (safe default).

`encode(to:)` emits **only** `contextSources` going forward. Old `contextMode` is dropped on re-save. Migration is opportunistic — the first time a user touches a persona row, it gets rewritten.

`ContextMode` enum is removed from the codebase in this change. The migration path lives entirely inside `Persona.init(from:)`.

## 5. Behavior

### 5.1 `buildPrompt(transcript:sources:)`

Pure assembly. Reads providers lazily — if a source is in the set but the provider returns nil/empty, the section is omitted, not emitted as an empty block.

Section template (lifted from the existing `[Selected text] / [Recent clipboard] / [User said]` shape):

```
[Selected text]
<text>

[Recent clipboard]
<text>

[Clipboard history]
1. <item1>
2. <item2>
…

[Window text]
<ocr>

[User said]
<transcript>
```

Deduplication rule (carried over from P1): when `[Selected text]` is present and the clipboard top is identical, the clipboard section is dropped.

### 5.2 `clipboardHistory` size

The size (N) is not a property of `ContextSource` — it's a parameter passed by the consumer when building the prompt. LOR-19 Clipboard Transformer passes the set of items the user actually selected; other consumers may pass a default like `top 5`. This keeps `ContextSource` Codable-stable and avoids version churn when defaults change.

PersonaContext gains an optional `clipboardHistory: [String]?` field for the consumer to supply.

```swift
struct PersonaContext: Equatable {
    let selection: String?
    let clipboardTop: String?
    let clipboardHistory: [String]?   // NEW — nil when caller doesn't supply
    let windowOCR: String?            // NEW — for LOR-20; nil for now
}
```

### 5.3 Built-in seed mapping

Scoped to the 5 existing seeds. LOR-19 adds a 6th seed (`builtin-clipboard-transformer`) which declares `[.clipboardHistory]` — see that spec for its own seed definition.

| Persona id | Old `contextMode` | New `contextSources` |
|---|---|---|
| `builtin-default` | `.none` | `[]` |
| `builtin-translate` | `.none` | `[]` |
| `builtin-cli` | `.none` | `[]` |
| `builtin-context` | `.selectionAndClipboard` | `[.selection, .clipboardTop]` |
| `builtin-general-editor` | `.none` | `[.selection]` (LOR-16 already reads selection at the consumer level — making it explicit on the persona is the right model) |

## 6. Test Strategy

### Pure-logic tests (no AppKit)

`Tests/ContextSourceTests.swift` (new):

- Codable round-trip for `Set<ContextSource>` (empty, single, all).
- `Persona.init(from:)` migration:
  - JSON containing only `contextMode == "none"` → `contextSources == []`.
  - JSON containing only `contextMode == "selectionAndClipboard"` → `[.selection, .clipboardTop]`.
  - JSON containing both fields → `contextSources` wins.
  - JSON containing neither → `[]`.
- `PersonaContext.buildPrompt(transcript:sources:)`:
  - All sources empty → returns just the transcript.
  - `[.selection]` with non-empty selection → `[Selected text]` + transcript.
  - `[.selection, .clipboardTop]` with both → both sections, in order.
  - `[.clipboardHistory]` with array → numbered list.
  - Selection equal to clipboard top → clipboard top dropped.
  - 7500-cap respected when sections exceed.

Existing `PersonaTests`, `PersonaStoreTests`, `PersonaContextTests`, `PersonaInjectionStrategyTests` update to expect 6 built-in seeds (5 + clipboard-transformer added by LOR-19) and the new `contextSources` field shape.

### Manual smoke

- Existing `~/Library/Application Support/KeyMic/personas.json` from a pre-LOR-18 install loads without error; `builtin-context` still pulls in `[Selected text]` + `[Recent clipboard]` sections in the LLM call.
- Edit a persona's `stylePrompt` in Settings, save, restart app → file now contains `contextSources` field, no `contextMode`.

## 7. Logging

Subsystem `io.keymic.app`, category `Persona`.

- `.debug` on persona decode: log `id` + `contextSources.count` (no content).
- `.error` on Codable migration failure (malformed JSON) — already covered by existing `PersonaStore.load` error path.

## 8. Migration plan

1. Add `ContextSource.swift`.
2. Extend `Persona` with `contextSources`; remove `contextMode` field and `ContextMode` enum from source.
3. Add Codable migration in `Persona.init(from:)`.
4. Update `PersonaContext` struct with `clipboardHistory` + `windowOCR` fields and `buildPrompt(transcript:sources:)` signature.
5. Update all 5 existing built-in seeds.
6. Update `PersonaStore` if it references `contextMode` (likely just builtin seed merging).
7. Update `AppDelegate.buildUserText` / `finishTranscription` (or wherever `buildPrompt(transcript:contextMode:)` is currently called) to pass `persona.contextSources`.
8. Migrate dependent tests (count assertions, contextMode references).

## 9. Open Questions

- **Should we keep `ContextMode` as a deprecated typealias for one release?** Proposal: no — there's only one caller (AppDelegate), migration is mechanical, deprecated aliases tend to outlive their welcome.
- **Should `contextSources` be order-preserving (Array) instead of Set?** Proposal: Set, because section order is canonical (defined by the spec, §5.1), not user-controlled. Set also dedupes naturally if PersonasView UI ends up with checkbox-style multi-select.
- **Should `.clipboardHistory` default to a fixed N when no consumer supplies it?** Proposal: no — if PersonaContext.clipboardHistory is nil and the persona declares `.clipboardHistory`, the section is just omitted. Forcing a default would surprise callers.

## 10. Acceptance Criteria

- [ ] `Persona` no longer has `contextMode`; `contextSources: Set<ContextSource>` is the only context-declaration field.
- [ ] On-disk `personas.json` from a pre-LOR-18 install decodes without loss; legacy `contextMode` field maps per §4.
- [ ] All 5 existing built-in seeds carry the `contextSources` mapping in §5.3 (clipboard-transformer is LOR-19's responsibility).
- [ ] `PersonaContext.buildPrompt(transcript:sources:)` emits sections in canonical order; absent providers produce no empty sections.
- [ ] `ContextMode` symbol is removed from the codebase.
- [ ] `Tests/ContextSourceTests.swift` passes; existing persona test suites updated and green.
- [ ] No log line contains selection / clipboard / OCR text content; only metadata.
