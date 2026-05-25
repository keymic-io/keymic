# Persona Platform Specs

Specs for [LOR-23 — Voice + LLM Persona Platform](https://linear.app/lorne/issue/LOR-23).

## What is the Persona Platform?

Generalises KeyMic's "hold-to-talk → transcribe → Cmd+V" into a reusable pipeline:

```
(optional context) + voice + LLM(persona) → routed injection target

context: none | selection | clipboard | clipboard history | window OCR | phone
inject:  focused field | clipboard | browser URL | iTerm pane | shell (confirmed)
```

A **Persona** is the swappable unit: `{ systemPrompt, contextSource, injectionStrategy }`.
The platform consists of three abstractions:

- **Context providers** — selection (LOR-17), clipboard (LOR-18), window OCR (LOR-20).
- **Persona engine** — LOR-14, already shipped (`Sources/KeyMic/LLM/Persona.swift`, `PersonaStore.swift`).
- **OutputRouter** — LOR-15, dispatches persona output by strategy.

## Phase plan

| Phase | Linear | What ships |
|---|---|---|
| **P1** | LOR-17 + LOR-15 (clipboard, openURL) + LOR-16 | Selection reader/writer; OutputRouter abstraction with 3 active strategies + 3 stubs; selected-text editor panel as the demo entry point |
| P2 | LOR-18 + LOR-19 | Persona `contextSource` field; clipboard batch transformer persona with ⌥L hotkey + magic-wand button on each `ClipboardPanel` row |
| P3 | LOR-20 + LOR-15 (shell + iTerm activation) | Window OCR via Vision + ScreenCaptureKit; `.runShell` confirmation sheet; `.writeToITermPane` via AppleScript |
| P4 | LOR-21 | Phone "whisper mode" — local HTTPS server + QR pairing + WebSocket text relay |
| P5 | LOR-22 (spike first) | Agent / Skill layer above persona; skilllite integration research |

## P1 specs (shipped)

- [Selected Text Reader (LOR-17)](2026-05-21-lor-17-selected-text-reader.md) — upgrade `SelectionTextProvider` to `SelectedTextReader` with `isEditable` detection and `replaceSelection(with:) -> Bool`.
- [Output Router (LOR-15)](2026-05-21-lor-15-output-router.md) — single dispatch layer over all injection destinations; 3 active P1 strategies, 3 stubbed for later phases.
- [Selected Text Editor Panel (LOR-16)](2026-05-21-lor-16-selected-text-editor-panel.md) — the user-visible demo: ⌥E pops a panel near the selection, voice/text instruction, in-place rewrite or clipboard fallback.

## P2 specs (shipped)

- [Persona Context Sources (LOR-18)](2026-05-22-lor-18-context-sources.md) — replace `Persona.contextMode` with `contextSources: Set<ContextSource>` so personas can declare fine-grained context (selection, clipboard top, clipboard history, future window OCR).
- [Clipboard Transformer (LOR-19)](2026-05-22-lor-19-clipboard-transformer.md) — built-in persona that takes N selected clipboard items and produces one synthesised output; triggered by ⌥L global hotkey or a per-row magic-wand button in the ClipboardPanel.

## P3 specs (this phase)

- [Window OCR Context Provider (LOR-20)](2026-05-23-lor-20-window-ocr.md) — `WindowOCRProvider` captures the focused window via ScreenCaptureKit and runs Vision OCR to populate `PersonaContext.windowOCR`. Pairs with `PersonaContextBuilder`, the new async context-assembly entry point that conditionally fetches each source declared by the active persona.
- [Shell + iTerm Output Strategies (LOR-15 P3)](2026-05-23-lor-15-shell-and-iterm-output.md) — replace the P1 stubs for `.runShell(commandTemplate:)` and `.writeToITermPane(paneIndex:)`. Mandatory confirmation sheet for shell (default = Cancel); AppleScript bridge for iTerm with Automation-permission handling. `builtin-cli` persona flips to `.runShell`.

## Implementation order (P3)

```
LOR-20 WindowOCRProvider ──→ PersonaContextBuilder ──→ AppDelegate wiring

LOR-15 ShellRunner + ShellConfirmationSheet ──┐
                                              ├──→ OutputRouter unstubbing + builtin-cli migration
LOR-15 ITermBridge + ITermAvailability     ───┘
```

LOR-20 and the LOR-15 P3 extension are independent and can ship in parallel.

LOR-17 and LOR-15 can be implemented in parallel. LOR-16 starts as soon as either lands and is finalised when both are merged.

## Conventions used in these specs

- Each spec opens with status, Linear link, dependencies, and phase.
- **Public API** sections show the exact Swift types callers will use.
- **Behavior** sections describe what each method does, including failure modes.
- **Test Strategy** sections enumerate what's covered by `make test-*` runners (no XCTest) plus a manual smoke matrix per spec.
- **Open Questions** list calls out the parts the spec deliberately leaves to the implementer's judgement; resolve in the PR rather than amending the spec.
- **Acceptance Criteria** is the merge checklist.

## Out-of-scope linkage

- `HotkeySettingsStore` is referenced as a dependency but specified separately in `docs/superpowers/specs/2026-05-10-hotkey-settings-store-design.md`.
- `PersonaStore` / `Persona` are the already-shipped LOR-14 deliverable. LOR-15 amends `Persona` with one `injectionStrategy` field — see the OutputRouter spec §4.2.
