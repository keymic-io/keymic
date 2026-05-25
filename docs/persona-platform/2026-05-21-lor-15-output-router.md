# Output Router (LOR-15 / R3)

> **Status:** Draft · 2026-05-21
> **Linear:** https://linear.app/lorne/issue/LOR-15
> **Parent epic:** [LOR-23 Voice + LLM Persona Platform](https://linear.app/lorne/issue/LOR-23)
> **Phase:** P1 (clipboard / openURL) → P3 (shell / iTerm)
> **Dependencies:** [LOR-14 Persona system (Done)](https://linear.app/lorne/issue/LOR-14), [LOR-17 Selected Text Reader](2026-05-21-lor-17-selected-text-reader.md)
> **Consumers:** Voice main pipeline (`AppDelegate.finishTranscription`), [LOR-16 Selected Text Editor](2026-05-21-lor-16-selected-text-editor-panel.md), [LOR-19 Clipboard Transformer](https://linear.app/lorne/issue/LOR-19), [LOR-21 Phone Bridge](https://linear.app/lorne/issue/LOR-21)

---

## 1. Context

Today every persona ends in **the same** output path:

```
LLMRefiner.refine(...) → TextInjector.inject(text) → clipboard + Cmd+V
```

The epic introduces personas that need different destinations:

| Persona use case | Destination |
|---|---|
| Voice transcription correction (default) | Focused text field (current behavior) |
| Selected-text edit panel | Replace selection if editable, else clipboard |
| Search assistant / map / opener | Open URL in browser |
| CLI Wizard | Terminal or iTerm pane, **with confirmation** |
| Clipboard batch transform | Top of clipboard history |

Routing logic currently lives implicitly in `TextInjector` and the call site. We need a single, declarative abstraction that:

1. The persona model can reference by name (`injectionStrategy`).
2. Centralizes all destination-specific quirks (input-source switching, pasteboard restore, AppleScript permission, shell confirmation).
3. Lets every consumer call **one** function regardless of destination.

## 2. Goals

- One `OutputRouter` entry point: `route(_ output: PersonaOutput) async throws -> RouteResult`.
- Six concrete strategies, **but P1 only requires three** (`replaceFocusedText`, `replaceSelection`, `clipboard`). The rest land at later phases — but the type system is built for them now so personas can declare them in JSON without code churn.
- Per-strategy preconditions (e.g. shell requires confirmation UI; iTerm requires AppleScript permission).
- All strategies funnel through the same logging + ignored-pasteboard-changeCount tracking that `TextInjector` does today.
- `TextInjector` stays as the **mechanism** for `replaceFocusedText`; `OutputRouter` is the **policy** above it.

## 3. Non-Goals

- Streaming output (one-shot only).
- Multi-target fanout (route to clipboard AND browser).
- User-defined custom strategies (only the built-in cases below).
- Undo. The user already has Cmd+Z in the destination app for editor strategies; shell/URL strategies are inherently irreversible.

## 4. Public API

### 4.1 Types

**File:** `Sources/KeyMic/Output/OutputRouter.swift` (new).

```swift
import AppKit

/// What gets routed.
struct PersonaOutput {
    /// The final text produced by the persona (post-LLM).
    let text: String

    /// Strategy declared by the persona that produced this output.
    let strategy: InjectionStrategy

    /// Frontmost app at the time the persona was triggered.
    /// OutputRouter restores focus to this app before injecting where applicable.
    let originatingApp: NSRunningApplication?

    /// Optional context payload for templating (openURL placeholders, etc.).
    let context: PersonaContext?
}

/// How to inject. Persisted on `Persona`. Codable.
enum InjectionStrategy: Codable, Equatable {
    case replaceFocusedText                    // current default — clipboard + Cmd+V
    case replaceSelection                      // edit in place, fallback to clipboard
    case clipboard                             // pasteboard only, no paste
    case openURL(template: String)             // template with {query} {clipboard} {selection}
    case runShell(commandTemplate: String)     // P3 — confirmation REQUIRED
    case writeToITermPane(paneIndex: Int)      // P3 — AppleScript / iTerm Python API
}

/// What happened.
enum RouteResult: Equatable {
    case injected                              // success
    case fellBackToClipboard(reason: FallbackReason)
    case userCancelled                         // confirmation dialog dismissed
    case failed(message: String)
}

enum FallbackReason: String, Equatable {
    case selectionNotEditable
    case noFocusedElement
    case axPermissionMissing
    case strategyNotImplemented                // for stub strategies still in dev
}

enum OutputRouterError: Error {
    case invalidURLTemplate(String)
    case unsupportedStrategy(InjectionStrategy)
}

/// The router itself.
final class OutputRouter {
    static let shared: OutputRouter

    /// Dependencies are injected for testability. AppDelegate constructs the shared instance.
    init(textInjector: TextInjector,
         selectedTextReader: SelectedTextReader.Type = SelectedTextReader.self,
         pasteboard: NSPasteboard = .general,
         workspace: NSWorkspace = .shared,
         confirmShellRun: @escaping (String) async -> Bool)

    /// Main entry point.
    @MainActor
    func route(_ output: PersonaOutput) async -> RouteResult
}
```

`PersonaContext` is the same struct already used in `Persona.execute`'s context plumbing (selected text, clipboard top, OCR text, etc.). Add it here if it doesn't yet exist as a struct — today it's an inline string in `AppDelegate.buildUserText`. Extract to `Sources/KeyMic/LLM/PersonaContext.swift` as part of this work.

### 4.2 Persona model changes

**File:** `Sources/KeyMic/LLM/Persona.swift`

Add one optional field. Default value preserves current behavior.

```swift
struct Persona: Codable, Identifiable, Equatable {
    // ...existing fields...
    var injectionStrategy: InjectionStrategy   // NEW, default `.replaceFocusedText`
}
```

Add `Codable` migration: when decoding existing `personas.json` rows that lack `injectionStrategy`, default to `.replaceFocusedText`. Bump no schema version; absent field decoding handles backward compat (per `Codable` default behavior with custom `init(from:)`).

Update built-in seeds in `Persona.builtInSeeds()`:

| id | injectionStrategy |
|---|---|
| `builtin-default` | `.replaceFocusedText` |
| `builtin-translate` | `.replaceFocusedText` |
| `builtin-cli` | `.replaceFocusedText` *(P1)* / `.runShell(commandTemplate: "{query}")` *(P3, gated by feature flag)* |
| `builtin-context` | `.replaceFocusedText` |

### 4.3 AppDelegate wiring

**File:** `Sources/KeyMic/AppDelegate.swift` — `finishTranscription(text:)` callsite (currently around lines 314–370).

Replace the direct `textInjector.inject(...)` call with:

```swift
let output = PersonaOutput(
    text: refined,
    strategy: persona.injectionStrategy,
    originatingApp: originatingApp,
    context: builtContext
)
let result = await OutputRouter.shared.route(output)
overlay.showRouteResult(result)   // toast text varies per case (see §5.5)
```

## 5. Behavior

### 5.1 `.replaceFocusedText` (P1, current default)

Equivalent to today's `TextInjector.inject(text)`. Same input-source switching, clipboard save/restore, ignored-changeCount marking. **No behavior change.**

### 5.2 `.replaceSelection` (P1)

1. Call `SelectedTextReader.currentSelection()`.
2. If `selection?.isEditable == true`: call `SelectedTextReader.replaceSelection(with: output.text)`.
   - On `true` → return `.injected`.
   - On `false` → fall through to clipboard fallback.
3. Else (no selection, not editable, or AX denied): execute the clipboard fallback path (§5.3) and return `.fellBackToClipboard(reason:)`.

The fallback **does not paste** — it only puts text on the pasteboard, because the user's focus is likely on a non-editable surface and a synthetic Cmd+V would do something surprising. The overlay must tell the user "copied to clipboard" (see §5.5).

### 5.3 `.clipboard` (P1)

1. Save current pasteboard string (for restore-on-no-change parity with `TextInjector`).
2. `pasteboard.clearContents(); pasteboard.setString(output.text, forType: .string)`.
3. Call `textInjector.onMarkIgnored?(output.text)` so `ClipboardMonitor` doesn't ingest this as a new history entry — **the persona output IS already saved as a new entry by the consumer**, see §6.
4. Return `.injected`.

**Do not** paste. `.clipboard` exists for personas that explicitly want clipboard-only output (e.g. clipboard batch transformer writing the result back as the new top of history).

### 5.4 `.openURL(template:)` (P1)

1. Template substitution. Allowed placeholders:
   - `{query}` → `output.text` URL-encoded
   - `{selection}` → `output.context?.selection ?? ""` URL-encoded
   - `{clipboard}` → `output.context?.clipboardTop ?? ""` URL-encoded
2. Construct `URL(string: substituted)`. If nil → return `.failed(message: "invalid URL after template substitution")`.
3. Validate scheme is `http`, `https`, or `mailto`. Other schemes (`file://`, `javascript:`, custom URL handlers) are **rejected** unless explicitly allowlisted later — protects against persona prompt injection writing `javascript:alert(...)`.
4. `NSWorkspace.shared.open(url)`. Return `.injected`.

### 5.5 `.runShell(commandTemplate:)` (P3 — stub at P1)

P1: implement as `return .failed(message: "shell strategy not yet available")`. Return type is final so personas can declare it without breaking decoding.

P3 contract (drafted now so we don't repaint the router later):

1. Template-substitute (same placeholders as openURL, but **without** URL encoding).
2. Show a modal `NSAlert`-style sheet: command preview (monospace), "Run" / "Cancel" buttons, default = Cancel. The sheet ships as `Sources/KeyMic/Output/ShellConfirmationSheet.swift`.
3. On confirm: `Process` with `/bin/zsh -c <command>`, capture stdout. Pipe stdout into the focused field via `TextInjector` if non-empty. Pipe stderr into the overlay error toast.
4. On cancel: return `.userCancelled`.
5. Personas using this strategy MUST set a per-call confirmation; there is **no remember-my-choice** option. Prompt-injection resistance is more important than ergonomics.

### 5.6 `.writeToITermPane(paneIndex:)` (P3 — stub at P1)

P1: stub `.failed(message: "iterm strategy not yet available")`.

P3 contract:

1. AppleScript bridge to iTerm2 (`tell application "iTerm" to tell session at paneIndex to write text ...`).
2. First call triggers macOS Automation permission prompt for iTerm — surface a one-time setup flow in Settings.
3. Falls back to `.failed(.missingAutomationPermission)` if denied.

### 5.7 App focus restore

Before any injecting strategy (`replaceFocusedText`, `replaceSelection`) the router calls `output.originatingApp?.activate(options: [])` and waits one runloop tick (`await Task.yield()`). Today this is duplicated in `ClipboardController.paste`; this work consolidates it into `OutputRouter.activateOriginatingApp()` and `ClipboardController` is migrated to call it.

### 5.8 Overlay feedback

Add to `OverlayPanel`:

```swift
func showRouteResult(_ result: RouteResult)
```

Mapping:

| RouteResult | Toast |
|---|---|
| `.injected` | (no toast — silent success, matches today) |
| `.fellBackToClipboard(.selectionNotEditable)` | "Copied — couldn't edit in place" |
| `.fellBackToClipboard(.noFocusedElement)` | "Copied — no focused field" |
| `.fellBackToClipboard(.axPermissionMissing)` | "Copied — Accessibility permission needed" + link to Settings |
| `.fellBackToClipboard(.strategyNotImplemented)` | "Copied — strategy coming soon" |
| `.userCancelled` | (no toast) |
| `.failed(message:)` | error toast with `message` |

## 6. Clipboard accounting

The clipboard fallback path and the `.clipboard` strategy both write to the pasteboard. To keep `ClipboardStore` consistent:

- The router emits `textInjector.onMarkIgnored?(text)` on every pasteboard write it performs.
- `ClipboardMonitor` already filters by that hook.
- The **consumer** (not the router) is responsible for explicitly calling `ClipboardStore.shared.upsert(text, source: .persona(personaID))` when the persona's intent is "produce a new history entry" (clipboard batch transformer in LOR-19). The router does not know which writes are user-visible history vs. transient.

## 7. Test Strategy

`make test-output-router` (new standalone runner under `Tests/OutputRouter/`).

### Pure-logic tests (no AppKit / AX)

- `InjectionStrategy` Codable round-trip for every case (incl. `.openURL(template:)` and `.runShell(commandTemplate:)`).
- `OutputRouter.URLTemplate.substitute(template:context:text:)` — extract as a static helper; assert:
  - `{query}` → URL-encoded text
  - `{selection}` → URL-encoded selection (nil → empty)
  - Unknown placeholder → left literal
  - Scheme validation: rejects `javascript:`, `file://`, custom schemes
- Persona `Codable` migration: decode a JSON blob lacking `injectionStrategy` → defaults to `.replaceFocusedText`.

### Integration tests with stub dependencies

Inject a stub `TextInjector` (records calls), stub `SelectedTextReader` (returns canned selection), and a fake `confirmShellRun` (always returns false for P1).

- `.replaceFocusedText` → exactly one `TextInjector.inject` call with the text.
- `.replaceSelection` + editable selection → one `SelectedTextReader.replaceSelection` call, zero `TextInjector.inject`.
- `.replaceSelection` + non-editable selection → zero replace, one pasteboard write, returns `.fellBackToClipboard(.selectionNotEditable)`.
- `.clipboard` → one pasteboard write, zero inject, returns `.injected`.
- `.openURL("https://example.com?q={query}")` with text `"hello world"` → `workspace.open` called with `https://example.com?q=hello%20world`.
- `.openURL("javascript:alert(1)")` → returns `.failed`, `workspace.open` not called.

### Manual smoke

| Strategy | App | Expectation |
|---|---|---|
| `.replaceFocusedText` | TextEdit | text pastes (regression check vs today) |
| `.replaceSelection` | TextEdit, select text | replaced in place |
| `.replaceSelection` | Safari read-only page, select text | toast "couldn't edit in place", clipboard set |
| `.clipboard` | anything | clipboard set, no paste |
| `.openURL` | default browser | opens URL |

## 8. Logging

Subsystem `io.keymic.app`, category `OutputRouter`.

- `.debug` per call: strategy case, originating bundle id, route result enum case, **no text content**.
- `.error` on URL template parse failure (includes the template string, but not the substituted result, to avoid leaking persona output).

## 9. Open Questions

- **Should `.openURL` validate against an allowlist of domains?** Probably no in P1 (user owns the persona templates). Revisit if we ship a persona marketplace.
- **Where does the ShellConfirmationSheet live in the menu-bar app's window hierarchy?** As an `NSAlert` attached to a transient borderless panel, the same way `OverlayPanel` floats. To be specified in the P3 spec.
- **Does `.replaceSelection` need a per-app override** for VS Code's known one-tick lag? If a follow-up replace fires before the lag resolves, the second write may stomp the first. Mitigation: rate-limit `replaceSelection` to 1 call per 200ms inside the router.

## 10. Acceptance Criteria — P1

- [ ] `Persona` decodes existing `~/Library/Application Support/KeyMic/personas.json` without loss; new field defaults to `.replaceFocusedText`.
- [ ] Voice main pipeline (`AppDelegate.finishTranscription`) routes through `OutputRouter` instead of calling `TextInjector` directly; default behavior unchanged.
- [ ] `.replaceSelection` works in TextEdit / Notes / VS Code; falls back to clipboard in Safari read-only pages with a toast.
- [ ] `.clipboard` strategy never triggers Cmd+V.
- [ ] `.openURL` opens the URL in the default browser; rejects `javascript:` / `file://` schemes.
- [ ] `.runShell` and `.writeToITermPane` cleanly return `.failed("…not yet available")` and personas declaring them load without errors.
- [ ] `make test-output-router` passes.
- [ ] Manual smoke matrix in §7 fully green.

## 11. Acceptance Criteria — P3 (deferred)

- [ ] `.runShell` shows confirmation sheet, runs only on explicit user approval, captures stderr to overlay.
- [ ] `.writeToITermPane` writes to the specified iTerm pane after one-time Automation permission grant.
- [ ] Shell command preview in confirmation sheet is rendered in monospace and shows the **substituted** command (after template expansion).
- [ ] Refuse to run if any required placeholder in the command template resolves to empty (e.g. `{selection}` is empty).
