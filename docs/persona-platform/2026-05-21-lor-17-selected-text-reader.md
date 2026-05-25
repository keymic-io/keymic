# Selected Text Reader (LOR-17 / R2.1)

> **Status:** Draft · 2026-05-21
> **Linear:** https://linear.app/lorne/issue/LOR-17
> **Parent epic:** [LOR-23 Voice + LLM Persona Platform](https://linear.app/lorne/issue/LOR-23)
> **Phase:** P1
> **Dependencies:** Accessibility permission (already granted by KeyMic)
> **Consumers:** [LOR-16 Selected Text Editor Panel](2026-05-21-lor-16-selected-text-editor-panel.md), any `Persona` with selection context

---

## 1. Context

The current `Sources/KeyMic/LLM/SelectionTextProvider.swift` is a 27-line read-only helper:

```swift
enum SelectionTextProvider {
    static func currentSelection() -> String?
}
```

It is used today by personas in `ContextMode = .selectionAndClipboard` to **read** the focused element's selection. It cannot:

1. Tell whether the focused element's selection is **editable**.
2. **Write back** to the selection (replace).

The Persona Platform (LOR-23) introduces two new requirements:

- **LOR-15 OutputRouter** needs to choose between `replaceSelection` (when editable) and `clipboard` fallback (when not).
- **LOR-16 Selected Text Editor Panel** must read the selection, send it to an LLM, and write the result back into the same field — or fall back to clipboard if the field rejects writes.

This spec defines the upgraded reader/writer module.

## 2. Goals

- Provide a single source of truth for "what is selected, and can I replace it?"
- Hide AX failure modes behind a clean API. Callers should never touch `AXUIElement` directly.
- Stay synchronous on the main thread (calls are sub-millisecond in normal cases).
- Graceful degradation: never throw, never crash. Return a meaningful nil/false instead.

## 3. Non-Goals

- Reading selections from non-focused windows.
- Multi-range selections (treat as a single concatenated range).
- Rich-text / attributed-string selections (return plain text only).
- Polling or observing selection changes (callers invoke on demand).
- Cross-process editing via paste fallback — that belongs to `OutputRouter`.

## 4. Public API

**File:** `Sources/KeyMic/Context/SelectedTextReader.swift` (new — moves out of `LLM/`).

```swift
import ApplicationServices

/// A snapshot of the focused element's selected text and editability.
struct TextSelection: Equatable {
    /// The selected text. Always non-empty when this value exists.
    let text: String

    /// Whether `replaceSelection(with:)` is expected to succeed for this element.
    /// Derived from kAXRoleAttribute + settability of kAXSelectedTextAttribute.
    let isEditable: Bool

    /// Bundle id of the frontmost app at capture time. Used for telemetry & known-quirk handling.
    let appBundleID: String?
}

enum SelectedTextReader {
    /// Reads the current selection from the focused UI element.
    /// Returns nil when:
    ///   - Accessibility permission is missing
    ///   - No focused element
    ///   - Focused element does not expose kAXSelectedTextAttribute
    ///   - Selection is empty
    static func currentSelection() -> TextSelection?

    /// Attempts to replace the focused element's selected text in place.
    /// Returns true only on confirmed success (AXUIElementSetAttributeValue == .success).
    /// On failure callers MUST fall back to clipboard injection.
    @discardableResult
    static func replaceSelection(with text: String) -> Bool
}
```

### Legacy compatibility

`Sources/KeyMic/LLM/SelectionTextProvider.swift` becomes a thin shim:

```swift
@available(*, deprecated, renamed: "SelectedTextReader.currentSelection")
enum SelectionTextProvider {
    static func currentSelection() -> String? {
        SelectedTextReader.currentSelection()?.text
    }
}
```

Migrate `AppDelegate.buildUserText` to call `SelectedTextReader.currentSelection()?.text` and delete the shim once no callers remain.

## 5. Behavior

### 5.1 `currentSelection()`

1. Request `kAXFocusedUIElementAttribute` on `AXUIElementCreateSystemWide()`.
2. CFGetTypeID-guarded cast to `AXUIElement` (preserve existing safety pattern).
3. Request `kAXSelectedTextAttribute`. If empty string or missing → return nil.
4. Compute `isEditable`:
   - `kAXRoleAttribute` ∈ {`AXTextField`, `AXTextArea`, `AXComboBox`} → likely editable.
   - Probe `AXUIElementIsAttributeSettable(_, kAXSelectedTextAttribute as CFString, &settable)`.
   - `isEditable = settable == true` (AND role is not on the read-only allowlist below).
5. Read frontmost app bundle id via `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`.
6. Return `TextSelection(text:, isEditable:, appBundleID:)`.

**Known read-only quirks (force isEditable = false even if settable claims true):**

| App | Why |
|---|---|
| iTerm / Terminal (`com.googlecode.iterm2`, `com.apple.Terminal`) | Selection is a pseudo-element; writes get swallowed or corrupt the buffer |
| Safari / Chrome / Edge inside `<input type=text>` regions: settable usually true → leave alone, **don't blanket-disable browsers** |
| Safari / Chrome read-only webview text (settable false naturally) | Caught by the settable probe |

The allowlist lives as `private static let forceReadOnlyBundleIDs: Set<String>` so it can grow without code changes elsewhere.

### 5.2 `replaceSelection(with:)`

1. Re-resolve the focused element (do **not** cache between read & write — focus may have moved).
2. Call `AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)`.
3. Return `true` only on `.success`. Log non-success codes via `os.Logger` at `.debug`.

**Important:** Do **not** verify by re-reading. Some clients (notably Electron) accept the write but defer reflection by one runloop tick; a verifying read would falsely report failure.

### 5.3 Permissions

Surface a single helper for the rest of the app:

```swift
extension SelectedTextReader {
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }
}
```

Callers (`OutputRouter`, `SelectedTextEditorPanel`) check this before invoking; the reader itself silently returns nil/false if denied (existing behavior).

## 6. Test Strategy

Follow KeyMic's `make test-*` standalone-runner pattern (no XCTest).

**File:** `Tests/SelectedTextReader/SelectedTextReaderTests.swift` (new runner).
**Makefile target:** `test-selected-text-reader`.

### What's testable without UI

Pure-logic shims, isolated from `AXUIElement`:

- `SelectedTextReader.Role.isEditableRole(_:)` — given a role string, returns the expected editable bias.
- `SelectedTextReader.QuirkList.shouldForceReadOnly(bundleID:)` — exercises the bundle-id allowlist.

Extract the decision logic into a pure helper:

```swift
struct EditabilityDecision {
    static func decide(role: String?, settable: Bool, bundleID: String?) -> Bool
}
```

The runner asserts:

1. `decide(role: "AXTextArea", settable: true, bundleID: nil) == true`
2. `decide(role: "AXStaticText", settable: true, bundleID: nil) == false`
3. `decide(role: "AXTextArea", settable: false, bundleID: nil) == false`
4. `decide(role: "AXTextArea", settable: true, bundleID: "com.googlecode.iterm2") == false`
5. `decide(role: nil, settable: true, bundleID: nil) == false`

### What requires manual smoke

End-to-end AX behavior is environment-dependent and not unit-testable. Smoke checklist (run before merging):

| App | Action | Expected |
|---|---|---|
| TextEdit (rich/plain) | select text, call `replaceSelection` | text replaced in place, returns true |
| Notes.app | select text, replace | replaced, true |
| VS Code (Electron) | select text, replace | replaced (may lag a tick), true |
| Safari `<textarea>` | select, replace | replaced, true |
| Safari read-only page text | select, replace | returns false (settable=false) |
| iTerm2 | select, replace | returns false (quirk list) |
| No focused element | call both APIs | returns nil/false, no crash |
| AX permission revoked | call both APIs | returns nil/false, no prompt |

## 7. Logging

Subsystem: `io.keymic.app`. Category: `SelectedTextReader`.

- `.debug` — every call, with bundle id + isEditable result.
- `.error` — non-success AX result codes on write (include `.cannotComplete`, `.attributeUnsupported`, etc. so we can iterate on the quirk list from real logs).
- **No PII**: never log selection text content; log `text.count` instead.

## 8. Migration Plan

1. Create `Sources/KeyMic/Context/SelectedTextReader.swift` with the new API.
2. Add deprecation shim to `SelectionTextProvider`.
3. Migrate the only existing caller (`AppDelegate.buildUserText` building `[Selected text]` block) to `SelectedTextReader.currentSelection()?.text`.
4. Delete `SelectionTextProvider` once `OutputRouter` & `SelectedTextEditorPanel` land.
5. Wire `test-selected-text-reader` into `Makefile`'s `test-all` chain.

## 9. Open Questions

- **Should the reader auto-strip trailing newlines** that some apps (Mail, Notes) include in `kAXSelectedTextAttribute`? Proposal: **no**, that is the caller's responsibility — but document in the API doc-comment.
- **Should `replaceSelection` debounce rapid repeated calls?** Probably not at this layer; if needed, the editor panel can rate-limit.

## 10. Acceptance Criteria

- [ ] `SelectedTextReader.currentSelection()` returns a `TextSelection` with correct `isEditable` for all rows in §6 smoke matrix.
- [ ] `SelectedTextReader.replaceSelection(with:)` writes successfully in TextEdit / Notes / VS Code / `<textarea>`.
- [ ] iTerm and read-only webviews report `isEditable = false`; `replaceSelection` returns false without side effects.
- [ ] `make test-selected-text-reader` passes (pure-logic decisions).
- [ ] No log line contains selected text content; only metadata.
- [ ] `SelectionTextProvider` shim still compiles & returns the same string `currentSelection()` returned before.
