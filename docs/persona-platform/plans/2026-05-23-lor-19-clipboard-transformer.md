# LOR-19 Clipboard Transformer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the "Clipboard Transformer" feature — a built-in persona that N-to-1 reduces selected clipboard items into one new top-of-history entry. Triggered by ⌥L global hotkey or per-row magic-wand button. Adds multi-select to `ClipboardPanel`.

**Architecture:** New `ClipboardTransformController` orchestrates the LLM call and writes the result into `ClipboardStore` + system pasteboard via `OutputRouter`. A small `ClipboardPanelSelectionBridge` (`@Observable @MainActor`) carries the multi-selection from the SwiftUI view back to `ClipboardController`. Hotkey infrastructure mirrors the LOR-16 pattern: `HotkeyFeature.clipboardTransform`, `HotkeyRegistry.Owner.clipboardTransform`, `KeyMonitor.onClipboardTransformHotkey`.

**Tech Stack:** Swift 5.9, SwiftPM single target, Foundation-only test runners under `Tests/`, AppKit + SwiftUI for the panel UI, `LLMRefiner.shared` (callback) wrapped in `withCheckedContinuation`. macOS 14.

**Source spec:** `docs/persona-platform/2026-05-22-lor-19-clipboard-transformer.md`

**Depends on:** [LOR-18 Context Sources plan](2026-05-23-lor-18-context-sources.md) (`Persona.contextSources` field must exist).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/KeyMic/Hotkey/HotkeySettingsStore.swift` | Modify | Add `case clipboardTransform` + `"alt+l"` default. |
| `Sources/KeyMic/Hotkey/HotkeyRegistry.swift` | Modify | Add `case clipboardTransform` to `Owner`. |
| `Sources/KeyMic/KeyMonitor.swift` | Modify | New `onClipboardTransformHotkey` callback + dispatch on keyDown + F-row. |
| `Sources/KeyMic/Clipboard/ClipboardTransformPrompt.swift` | Create | Pure helpers — `composeBatchUserMessage` + `validateSize`. |
| `Sources/KeyMic/Clipboard/ClipboardTransformController.swift` | Create | LLM dispatch + ClipboardStore write + pasteboard sync. |
| `Sources/KeyMic/Clipboard/ClipboardPanelSelectionBridge.swift` | Create | `@Observable @MainActor` shared selection model. |
| `Sources/KeyMic/Clipboard/ClipboardController.swift` | Modify | New `transformSelected()` + bridge wiring + transformController retain. |
| `Sources/KeyMic/Clipboard/ClipboardHistoryView.swift` | Modify | Replace `selectedID` with `selectedIDs: Set<UUID>` via bridge; ⌘/⇧ click handlers; Transform button; magic-wand row button. |
| `Sources/KeyMic/LLM/Persona.swift` | Modify | Add `builtin-clipboard-transformer` seed. |
| `Sources/KeyMic/AppDelegate.swift` | Modify | Construct `ClipboardTransformController`; wire hotkey; register in HotkeyRegistry. |
| `Sources/KeyMic/SettingsUI/SettingsRoot.swift` | Modify | Clipboard tab gains "Transform: ⌥L" row. |
| `Tests/ClipboardTransformPromptTests.swift` | Create | Pure-logic helpers. |
| `Tests/PersonaTests.swift` | Modify | 6 built-in seeds expected. |
| `Tests/PersonaStoreTests.swift` | Modify | seed-count assertions go 5 → 6. |
| `Tests/PersonaInjectionStrategyTests.swift` | Modify | New seed expected with `.clipboard` strategy. |
| `Makefile` | Modify | `test-clipboard-transform` target; thread into `test-all`. |

---

## Task 1: Hotkey infrastructure (HotkeyFeature + Owner + KeyMonitor)

Mirrors `feat(hotkey): register selectedTextEditor feature with ⌥E default` (commit `f4b8d58`). No consumer wires it yet — that's Task 9.

**Files:**
- Modify: `Sources/KeyMic/Hotkey/HotkeySettingsStore.swift`
- Modify: `Sources/KeyMic/Hotkey/HotkeyRegistry.swift`
- Modify: `Sources/KeyMic/KeyMonitor.swift`

- [ ] **Step 1: Add `clipboardTransform` case to `HotkeyFeature`**

Edit `Sources/KeyMic/Hotkey/HotkeySettingsStore.swift`. Find the `enum HotkeyFeature` block (lines 8-32).

Add `case clipboardTransform` after `case selectedTextEditor`.

Add to `displayName` switch:

```swift
case .clipboardTransform: return String(localized: "Clipboard transformer")
```

Add to `defaults` dictionary:

```swift
HotkeyFeature.clipboardTransform.rawValue: "alt+l",       // Transform selected clipboard items via LLM.
```

- [ ] **Step 2: Add `clipboardTransform` to `HotkeyRegistry.Owner`**

Edit `Sources/KeyMic/Hotkey/HotkeyRegistry.swift`. Find `enum Owner` (lines 10-19). Add `case clipboardTransform` after `case selectedTextEditor`.

- [ ] **Step 3: Add `onClipboardTransformHotkey` callback to KeyMonitor**

Edit `Sources/KeyMic/KeyMonitor.swift`. Locate the public callback declarations around lines 25-27. Add after `onSelectedTextEditorHotkey`:

```swift
var onClipboardTransformHotkey: (() -> Void)?
```

Locate the private hotkey config storage around lines 52-57. Add after `private var selectedTextEditorHotkey: HotkeyConfig?`:

```swift
private var clipboardTransformHotkey: HotkeyConfig?
```

In `reloadHotkeys()` (around line 230), add after `selectedTextEditorHotkey = hotkeys.hotkey(for: .selectedTextEditor)`:

```swift
clipboardTransformHotkey = hotkeys.hotkey(for: .clipboardTransform)
```

In the regular keyDown dispatch block (around the existing "Selected Text Editor hotkey" block, after it), add:

```swift
// Clipboard Transform hotkey
if let cfg = clipboardTransformHotkey,
   !cfg.isPureModifier,
   cfg.matches(keyCode: keyCode, flags: event.flags) {
    DispatchQueue.main.async { [weak self] in self?.onClipboardTransformHotkey?() }
    return nil
}
```

In the F-row dispatch helper `dispatchFRowHotkey(keyCode:flags:)` (near the existing selectedTextEditor F-row block), add after it:

```swift
if let cfg = clipboardTransformHotkey, !cfg.isPureModifier,
   cfg.matches(keyCode: keyCode, flags: flags) {
    DispatchQueue.main.async { [weak self] in self?.onClipboardTransformHotkey?() }
    return true
}
```

- [ ] **Step 4: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 5: Run hotkey-related tests**

Run: `make test-hotkey-settings-store test-hotkey-config test-hotkey-registry 2>&1 | grep -E "passed|❌|FAIL"`

Expected: all passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/Hotkey/HotkeySettingsStore.swift \
        Sources/KeyMic/Hotkey/HotkeyRegistry.swift \
        Sources/KeyMic/KeyMonitor.swift
git commit -m "feat(hotkey): register clipboardTransform feature with ⌥L default (LOR-19)"
```

---

## Task 2: `ClipboardTransformPrompt` pure helpers + tests

**Files:**
- Create: `Sources/KeyMic/Clipboard/ClipboardTransformPrompt.swift`
- Create: `Tests/ClipboardTransformPromptTests.swift`
- Modify: `Makefile`

- [ ] **Step 1: Write failing test**

`Tests/ClipboardTransformPromptTests.swift`:

```swift
import Foundation

@main
struct ClipboardTransformPromptTestRunner {
    static func main() {
        testComposeEmpty()
        testComposeSingle()
        testComposeMultiple()
        testComposeOrdering()
        testValidateSize_underCap()
        testValidateSize_perItemOverCap()
        testValidateSize_combinedOverCap()
        testSystemPromptFallbackNonEmpty()
        print("ClipboardTransformPromptTests passed")
    }

    static func testComposeEmpty() {
        let got = ClipboardTransformPrompt.composeBatchUserMessage(items: [])
        if got != "" {
            fail("empty items should produce empty string, got: \(got)")
        }
    }

    static func testComposeSingle() {
        let got = ClipboardTransformPrompt.composeBatchUserMessage(items: ["one"])
        let want = "[Item 1]\none"
        if got != want { fail("single mismatch:\ngot: \(got)\nwant: \(want)") }
    }

    static func testComposeMultiple() {
        let got = ClipboardTransformPrompt.composeBatchUserMessage(items: ["a", "b"])
        let want = "[Item 1]\na\n\n[Item 2]\nb"
        if got != want { fail("multi mismatch:\ngot: \(got)\nwant: \(want)") }
    }

    static func testComposeOrdering() {
        let got = ClipboardTransformPrompt.composeBatchUserMessage(items: ["x", "y", "z"])
        let want = "[Item 1]\nx\n\n[Item 2]\ny\n\n[Item 3]\nz"
        if got != want { fail("order mismatch:\ngot: \(got)\nwant: \(want)") }
    }

    static func testValidateSize_underCap() {
        let result = ClipboardTransformPrompt.validateSize(items: ["short", "also short"])
        if result != nil { fail("under-cap should return nil, got: \(result!)") }
    }

    static func testValidateSize_perItemOverCap() {
        let big = String(repeating: "a", count: 60_000)   // > 50K
        let result = ClipboardTransformPrompt.validateSize(items: [big])
        if result == nil { fail("per-item over cap should return error, got nil") }
    }

    static func testValidateSize_combinedOverCap() {
        let item = String(repeating: "b", count: 49_000)
        let items = [item, item, item]                     // ~147K combined > 100K
        let result = ClipboardTransformPrompt.validateSize(items: items)
        if result == nil { fail("combined over cap should return error, got nil") }
    }

    static func testSystemPromptFallbackNonEmpty() {
        if ClipboardTransformPrompt.systemPromptFallback.isEmpty {
            fail("systemPromptFallback should be non-empty")
        }
    }

    static func fail(_ msg: String) {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails (no source file yet)**

Run: `mkdir -p .build && swiftc Tests/ClipboardTransformPromptTests.swift -o .build/clipboard-transform-prompt-tests 2>&1 | head -3`

Expected: `cannot find 'ClipboardTransformPrompt' in scope`.

- [ ] **Step 3: Write implementation**

`Sources/KeyMic/Clipboard/ClipboardTransformPrompt.swift`:

```swift
import Foundation

/// Pure helpers for the Clipboard Transformer LLM call.
/// Foundation-only so the standalone test runner can exercise it without AppKit/SwiftData.
enum ClipboardTransformPrompt {
    /// Per-item cap (UTF-16 units).
    static let perItemCap: Int = 50_000
    /// Combined input cap (UTF-16 units).
    static let combinedCap: Int = 100_000

    /// Fallback system prompt when the `builtin-clipboard-transformer` persona is missing.
    /// Mirrors the seed in `Persona.builtInSeeds()`.
    static let systemPromptFallback: String = """
        You will receive N clipboard items, each labelled [Item k]. Produce ONE concise output \
        that synthesises / summarises / reformats them according to the implicit user intent \
        (default: summarise into a single clear paragraph). Return ONLY the result — no preamble, \
        no item labels, no markdown fences. Preserve the dominant language of the inputs.
        """

    /// Builds the user message: `[Item k]\n<text>` blocks, blank-line separated.
    static func composeBatchUserMessage(items: [String]) -> String {
        items.enumerated()
            .map { idx, text in "[Item \(idx + 1)]\n\(text)" }
            .joined(separator: "\n\n")
    }

    /// Returns nil if within caps, else a localized error string.
    static func validateSize(items: [String]) -> String? {
        for (idx, text) in items.enumerated() {
            if text.utf16.count > perItemCap {
                return String(localized: "Item \(idx + 1) too large (\(text.utf16.count / 1024) KB > \(perItemCap / 1024) KB cap)")
            }
        }
        let combined = items.reduce(0) { $0 + $1.utf16.count }
        if combined > combinedCap {
            return String(localized: "Combined input too large (\(combined / 1024) KB > \(combinedCap / 1024) KB cap)")
        }
        return nil
    }
}
```

- [ ] **Step 4: Add Makefile target**

Append after `test-context-source` (or after `test-selection-copy-wait` if Task 1 of the LOR-18 plan hasn't shipped yet):

```makefile
test-clipboard-transform:
	mkdir -p .build
	swiftc Sources/KeyMic/Clipboard/ClipboardTransformPrompt.swift \
	       Tests/ClipboardTransformPromptTests.swift \
	       -o .build/clipboard-transform-prompt-tests
	.build/clipboard-transform-prompt-tests
```

Append `test-clipboard-transform` to the `test-all:` chain.

- [ ] **Step 5: Run test to verify it passes**

Run: `make test-clipboard-transform`

Expected: `ClipboardTransformPromptTests passed`.

- [ ] **Step 6: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/Clipboard/ClipboardTransformPrompt.swift \
        Tests/ClipboardTransformPromptTests.swift Makefile
git commit -m "feat(clipboard): add ClipboardTransformPrompt pure helpers (LOR-19)"
```

---

## Task 3: Seed `builtin-clipboard-transformer` persona

**Files:**
- Modify: `Sources/KeyMic/LLM/Persona.swift` (`builtInSeeds()`)
- Modify: `Tests/PersonaTests.swift` (6-seed assertion)
- Modify: `Tests/PersonaStoreTests.swift` (5 → 6)
- Modify: `Tests/PersonaInjectionStrategyTests.swift` (canonical-strategy mapping)

- [ ] **Step 1: Add the seed**

In `Persona.swift` `builtInSeeds()`, append AFTER the existing `builtin-general-editor` entry:

```swift
            Persona(
                id: "builtin-clipboard-transformer",
                name: "Clipboard Transformer",
                icon: "wand.and.stars",
                stylePrompt: """
                    You will receive N clipboard items, each labelled [Item k]. Produce ONE concise output \
                    that synthesises / summarises / reformats them according to the implicit user intent \
                    (default: summarise into a single clear paragraph). Return ONLY the result — no preamble, \
                    no item labels, no markdown fences. Preserve the dominant language of the inputs.
                    """,
                temperature: 0.4,
                hotkey: nil,
                contextSources: [.clipboardHistory],
                builtIn: true,
                createdAt: now,
                updatedAt: now,
                injectionStrategy: .clipboard
            ),
```

(Note: `contextMode:` is gone post-LOR-18; if LOR-18 cleanup hasn't shipped, also add `contextMode: .none,` before `contextSources:`.)

- [ ] **Step 2: Update `Tests/PersonaTests.swift` — 5 → 6 seeds**

Find the existing `seeds.count == 5` assertion and update to `6`. Update the canonical `ids` array to include `"builtin-clipboard-transformer"` at the end.

```swift
        expect(seeds.count == 6, "exactly 6 built-in seeds")
        let ids = seeds.map(\.id)
        expect(ids == [
            "builtin-default",
            "builtin-translate",
            "builtin-cli",
            "builtin-context",
            "builtin-general-editor",
            "builtin-clipboard-transformer",
        ], "built-in ids in canonical order")
        // ... existing assertions (seeds[3], seeds[4], etc.) stay valid by index.
        expect(seeds[5].injectionStrategy == .clipboard,
               "clipboard-transformer persona uses clipboard strategy")
        expect(seeds[5].contextSources == [.clipboardHistory],
               "clipboard-transformer declares [.clipboardHistory]")
```

- [ ] **Step 3: Update `Tests/PersonaStoreTests.swift` — count 5 → 6**

Find the two `expect(store.personas.count == 5, ...)` assertions (around lines 14 and 22). Update to `6`. The `add custom → 6` assertion at line 39 becomes `7`.

```swift
        expect(store1.personas.count == 6, "first load seeds 6 built-ins")
        // ...
        expect(store2.personas.count == 6, "reload keeps 6 personas")
        // ...
        store3.add(custom)
        expect(store3.personas.count == 7, "add appends")
```

- [ ] **Step 4: Update `Tests/PersonaInjectionStrategyTests.swift` — add seed to expected map**

In `testBuiltInSeedsHaveCanonicalStrategy`, append to the `expected` dictionary:

```swift
            "builtin-clipboard-transformer": .clipboard,
```

- [ ] **Step 5: Run dependent tests**

Run: `make test-persona test-persona-store test-persona-injection-strategy 2>&1 | grep -E "passed|❌|FAIL"`

Expected: all 3 passed.

- [ ] **Step 6: Run full build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/LLM/Persona.swift \
        Tests/PersonaTests.swift Tests/PersonaStoreTests.swift Tests/PersonaInjectionStrategyTests.swift
git commit -m "feat(persona): seed builtin-clipboard-transformer for LOR-19"
```

---

## Task 4: `ClipboardPanelSelectionBridge` — shared selection model

**Files:**
- Create: `Sources/KeyMic/Clipboard/ClipboardPanelSelectionBridge.swift`

The SwiftUI view needs to publish its selection back to `ClipboardController` so the global ⌥L hotkey can read it. Use a small `@Observable @MainActor` model owned by `ClipboardController` and `@Bindable`-bound into the view.

- [ ] **Step 1: Write the bridge**

```swift
import AppKit
import Foundation
import Observation

/// Carries clipboard-panel multi-selection state from the SwiftUI view back to
/// `ClipboardController`, so the global ⌥L hotkey can read current selection
/// without poking into the view. Owned by `ClipboardController`.
@MainActor
@Observable
final class ClipboardPanelSelectionBridge {
    /// IDs of currently-selected ClipboardItems (multi-select aware).
    var selectedIDs: Set<UUID> = []

    /// Anchor for shift-click range selection.
    var lastClickedID: UUID?

    /// Snapshot used by global hotkey: returns selection in *current visual order*
    /// — the view writes this whenever its filtered list changes.
    var visibleOrderedIDs: [UUID] = []

    /// Single-select consumer helper: nil unless exactly one item is selected.
    var primarySelection: UUID? {
        selectedIDs.count == 1 ? selectedIDs.first : nil
    }

    /// Returns the selection in visual order; falls back to empty when nothing selected.
    func orderedSelection() -> [UUID] {
        visibleOrderedIDs.filter { selectedIDs.contains($0) }
    }

    func reset() {
        selectedIDs.removeAll()
        lastClickedID = nil
        visibleOrderedIDs.removeAll()
    }
}
```

- [ ] **Step 2: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`. (No consumer yet; that's fine.)

- [ ] **Step 3: Commit**

```bash
git add Sources/KeyMic/Clipboard/ClipboardPanelSelectionBridge.swift
git commit -m "feat(clipboard): add @Observable ClipboardPanelSelectionBridge (LOR-19)"
```

---

## Task 5: `ClipboardTransformController` — LLM dispatch + write-back

**Files:**
- Create: `Sources/KeyMic/Clipboard/ClipboardTransformController.swift`

- [ ] **Step 1: Write the controller**

```swift
import AppKit
import Foundation
import os.log

private let transformerLogger = Logger(subsystem: "io.keymic.app", category: "ClipboardTransformer")

/// Coordinates a single Clipboard Transformer LLM call against a batch of items.
/// One instance lives on AppDelegate; called by `ClipboardController.transformSelected()`.
@MainActor
final class ClipboardTransformController {
    static let personaID = "builtin-clipboard-transformer"

    private let store: ClipboardStore
    private let llm: LLMRefiner
    private let outputRouter: () -> OutputRouter
    private weak var overlayPanel: OverlayPanel?

    private var inFlight: Bool = false

    init(store: ClipboardStore,
         llm: LLMRefiner = .shared,
         outputRouter: @autoclosure @escaping () -> OutputRouter = OutputRouter.shared,
         overlayPanel: OverlayPanel? = nil) {
        self.store = store
        self.llm = llm
        self.outputRouter = outputRouter
        self.overlayPanel = overlayPanel
    }

    func attach(overlayPanel: OverlayPanel) {
        self.overlayPanel = overlayPanel
    }

    /// Public entry point. Called by ClipboardController.transformSelected().
    /// Items should be in user-selection / visual order (top-of-history first).
    func transform(items: [ClipboardItem]) {
        guard !inFlight else {
            transformerLogger.debug("transform: ignored, already in flight")
            return
        }
        guard !items.isEmpty else {
            overlayPanel?.showTransientToast(
                String(localized: "Select at least one clipboard item"),
                durationSeconds: 2.0
            )
            return
        }

        let texts = items.map(\.text)
        if let sizeError = ClipboardTransformPrompt.validateSize(items: texts) {
            transformerLogger.debug("transform: size validation failed")
            overlayPanel?.showTransientToast(sizeError, durationSeconds: 3.0)
            return
        }

        let userMessage = ClipboardTransformPrompt.composeBatchUserMessage(items: texts)
        let (systemPrompt, temperature) = resolvePersonaSettings()

        inFlight = true
        overlayPanel?.showTransientToast(
            String(localized: "Transforming \(items.count) item(s)…"),
            durationSeconds: 1.5
        )
        transformerLogger.debug("transform: count=\(items.count, privacy: .public) chars=\(userMessage.utf16.count, privacy: .public)")

        Task { @MainActor in
            defer { inFlight = false }
            do {
                let result: String = try await withCheckedThrowingContinuation { cont in
                    llm.refine(userMessage, systemPrompt: systemPrompt, temperature: temperature) { res in
                        cont.resume(with: res)
                    }
                }
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    overlayPanel?.showTransientToast(
                        String(localized: "Transform produced no output"),
                        durationSeconds: 3.0
                    )
                    return
                }

                // 1. Insert at top of history.
                store.add(
                    text: trimmed,
                    sourceBundleID: Bundle.main.bundleIdentifier,
                    sourceAppName: "Clipboard Transformer"
                )

                // 2. Sync to system pasteboard via OutputRouter.
                let output = PersonaOutput(
                    text: trimmed,
                    strategy: .clipboard,
                    originatingApp: nil,
                    context: nil
                )
                _ = await outputRouter().route(output)

                overlayPanel?.showTransientToast(
                    String(localized: "Transformed \(items.count) item(s)"),
                    durationSeconds: 1.8
                )
                transformerLogger.debug("transform: success out_chars=\(trimmed.utf16.count, privacy: .public)")
            } catch {
                overlayPanel?.showTransientToast(
                    String(localized: "Transform failed: \(error.localizedDescription)"),
                    durationSeconds: 3.0
                )
                transformerLogger.error("transform: LLM failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func resolvePersonaSettings() -> (systemPrompt: String, temperature: Double) {
        if let persona = PersonaStore.shared.persona(id: Self.personaID) {
            return (persona.stylePrompt, persona.temperature)
        }
        return (ClipboardTransformPrompt.systemPromptFallback, 0.4)
    }
}
```

- [ ] **Step 2: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/KeyMic/Clipboard/ClipboardTransformController.swift
git commit -m "feat(clipboard): add ClipboardTransformController (LOR-19)"
```

---

## Task 6: `ClipboardController.transformSelected()` wiring

**Files:**
- Modify: `Sources/KeyMic/Clipboard/ClipboardController.swift`

- [ ] **Step 1: Add bridge + transformController properties**

Near the top of `ClipboardController` (after the existing stored properties), add:

```swift
    /// Multi-selection bridge between ClipboardPanel and external triggers (hotkey, magic-wand).
    let selectionBridge = ClipboardPanelSelectionBridge()

    /// Injected by AppDelegate after construction. Optional so the controller is testable
    /// without an LLM dependency.
    var transformController: ClipboardTransformController?

    /// Strong reference to the SwiftData store — exposed for the transformer's writeback path.
    var store: ClipboardStore {
        // ClipboardController owns the SwiftData container; surface its store.
        // (If `store` is already a property, this getter is unnecessary — confirm before editing.)
        return _store
    }
```

NOTE: Look at the existing `ClipboardController` source first — it already holds a `ClipboardStore`. If there's an existing `private let store: ClipboardStore` (or similar), expose it as `internal` instead of adding a getter. Read lines 1-30 first.

- [ ] **Step 2: Add `transformSelected()` method**

Append inside the class:

```swift
    /// Triggered by ⌥L hotkey, the Transform button, and the per-row magic-wand button.
    func transformSelected() {
        guard let transformer = transformController else { return }

        // 1. panel open + non-empty selectedIDs → those items in visual order
        // 2. panel open + empty selectedIDs → cursor row (selectionBridge.lastClickedID
        //    OR the first visible item if no cursor — keeps single-keystroke ergonomics)
        // 3. panel closed → open it to clipboard tab + toast; do not invoke LLM
        if !isPanelVisible {
            toggle(initialTab: .clipboard)
            overlayPanel?.showTransientToast(
                String(localized: "Select items to transform"),
                durationSeconds: 2.0
            )
            return
        }

        let items = currentSelectedItems()
        transformer.transform(items: items)
    }

    private func currentSelectedItems() -> [ClipboardItem] {
        // Resolve IDs to actual ClipboardItems through the SwiftData store.
        let visible = selectionBridge.visibleOrderedIDs
        let selected = selectionBridge.selectedIDs

        let idsToTransform: [UUID]
        if !selected.isEmpty {
            // Preserve visual order.
            idsToTransform = visible.filter { selected.contains($0) }
        } else if let cursor = selectionBridge.lastClickedID {
            idsToTransform = [cursor]
        } else if let firstVisible = visible.first {
            idsToTransform = [firstVisible]
        } else {
            idsToTransform = []
        }

        // Look up the actual items. SwiftData lookup pattern:
        return idsToTransform.compactMap { id in
            store.itemsLookup[id]
        }
    }
```

If `ClipboardStore` doesn't expose `itemsLookup`, add a small read helper. Read lines 1-100 of `ClipboardStore.swift` and add (if missing):

```swift
    /// O(N) read for the transformer wire-up. Returns nil if id not found.
    func item(id: UUID) -> ClipboardItem? {
        items.first { $0.id == id }
    }
```

Then `currentSelectedItems()` does `store.item(id: id)`.

- [ ] **Step 3: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
git add Sources/KeyMic/Clipboard/ClipboardController.swift Sources/KeyMic/Clipboard/ClipboardStore.swift
git commit -m "feat(clipboard): ClipboardController.transformSelected() routing (LOR-19)"
```

---

## Task 7: `ClipboardHistoryView` multi-select rewrite

**Files:**
- Modify: `Sources/KeyMic/Clipboard/ClipboardHistoryView.swift`

This is the biggest UI change. The view's existing `@State var selectedID: UUID?` becomes derived from `selectionBridge.selectedIDs`. The bridge is passed in via `@Bindable`.

- [ ] **Step 1: Read the view to understand current structure**

```bash
grep -n "selectedID" Sources/KeyMic/Clipboard/ClipboardHistoryView.swift | head -20
```

(There are ~12 occurrences. Plan: replace single-select reads with `bridge.primarySelection` and writes with `bridge.selectedIDs = [id]` etc.)

- [ ] **Step 2: Add bridge parameter to the view**

Find the existing `struct ClipboardHistoryView: View {` declaration (line 11). Add an injected bridge:

```swift
struct ClipboardHistoryView: View {
    @Bindable var selectionBridge: ClipboardPanelSelectionBridge
    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]
    // ...
}
```

Remove `@State private var selectedID: UUID?` (line 16).

Define a computed convenience to keep diff small:

```swift
    private var selectedIDs: Set<UUID> { selectionBridge.selectedIDs }
    private var primaryID: UUID? { selectionBridge.primarySelection }
```

- [ ] **Step 3: Replace every `selectedID` read**

Read occurrences (from initial grep): lines 89, 95, 117, 121-122, 205, 207, 234, 257, 299, 321-323, 334-336, 341, 346, 351.

Replace patterns:

| Old | New |
|---|---|
| `selectedID = filtered.all.first?.id` | `selectionBridge.selectedIDs = [filtered.all.first?.id].compactMap { $0 }.reduce(into: Set()) { $0.insert($1) }` *(simpler: `if let id = filtered.all.first?.id { selectionBridge.selectedIDs = [id]; selectionBridge.lastClickedID = id }`)* |
| `selectedID != firstID` | `primaryID != firstID` |
| `selectedID != item.id` (read) | `primaryID != item.id` |
| `selectedID = item.id` (write) | `selectionBridge.selectedIDs = [item.id]; selectionBridge.lastClickedID = item.id` |
| `item.id == selectedID` (Bool) | `selectedIDs.contains(item.id)` |
| `.firstIndex(where: { $0.id == selectedID })` | `.firstIndex(where: { selectedIDs.contains($0.id) })` |
| `guard let id = selectedID` | `guard let id = primaryID` (since single-select consumers like quick paste / enter use primary) |

After all replacements, do `grep -n "selectedID" Sources/KeyMic/Clipboard/ClipboardHistoryView.swift` and verify it returns no matches.

- [ ] **Step 4: Update visibleOrderedIDs**

In the `body` (or wherever filtered items are computed), add an `.onChange(of: filtered)` that pushes the visible IDs back to the bridge:

```swift
            .onChange(of: filtered.all) { _, newValue in
                selectionBridge.visibleOrderedIDs = newValue.map(\.id)
            }
            .onAppear {
                selectionBridge.visibleOrderedIDs = filtered.all.map(\.id)
            }
```

(`filtered.all` may be a computed; if it's not Equatable, use `filtered.all.map(\.id)` in the comparison.)

- [ ] **Step 5: Add ⌘/⇧ click handlers**

Find the existing `.onTapGesture { onPaste(item) }` block (line 210 or 226). The current behavior is "click pastes". Per spec, multi-select needs to override this: click should *select*, not paste. But pasting on click is the dominant existing UX — preserving it means click+paste collides with multi-select.

Resolution: **click = select only**; double-click = paste (already present? check). Otherwise the existing onPaste-on-tap stays but we add an ⌘+click handler on top:

```swift
                            .onTapGesture(count: 2) { onPaste(item) }
                            .simultaneousGesture(
                                TapGesture(count: 1).modifiers(.command).onEnded {
                                    if selectedIDs.contains(item.id) {
                                        selectionBridge.selectedIDs.remove(item.id)
                                    } else {
                                        selectionBridge.selectedIDs.insert(item.id)
                                    }
                                    selectionBridge.lastClickedID = item.id
                                }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 1).modifiers(.shift).onEnded {
                                    extendRange(to: item.id)
                                }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 1).onEnded {
                                    selectionBridge.selectedIDs = [item.id]
                                    selectionBridge.lastClickedID = item.id
                                }
                            )
```

This is fiddly with SwiftUI gesture priority — be ready to iterate. If `simultaneousGesture` priority breaks the existing single-tap-to-paste behavior, fall back to a custom `Button` style or use `.onTapGesture(perform:)` with the modifier-aware NSEvent peeking trick from `KeyEventMonitor`. (KeyMic's clipboard panel already has a `KeyEventMonitor` NSView inside the SwiftUI view — leverage it for click modifiers via a dedicated NSEvent-tracking subview if SwiftUI gesture composition proves unreliable.)

Helper:

```swift
    private func extendRange(to targetID: UUID) {
        guard let anchor = selectionBridge.lastClickedID,
              let aIdx = filtered.all.firstIndex(where: { $0.id == anchor }),
              let tIdx = filtered.all.firstIndex(where: { $0.id == targetID }) else {
            selectionBridge.selectedIDs = [targetID]
            selectionBridge.lastClickedID = targetID
            return
        }
        let range = aIdx <= tIdx ? aIdx...tIdx : tIdx...aIdx
        let ids = filtered.all[range].map(\.id)
        selectionBridge.selectedIDs.formUnion(ids)
        // anchor unchanged
    }
```

- [ ] **Step 6: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete" | head -5`

Expected: `Build complete!`.

If errors mention `Bindable` / `@Observable` macro misuse, check the bridge import & that the view file imports `Observation`.

- [ ] **Step 7: Run clipboard panel tests**

Run: `make test-keymonitor-clipboard-panel 2>&1 | tail -5`

Expected: passes. (The test target builds a stripped subset — verify multi-select changes don't break its compile graph; update its Makefile rule if the rule lists `ClipboardHistoryView.swift` and now misses `ClipboardPanelSelectionBridge.swift`.)

- [ ] **Step 8: Commit**

```bash
git add Sources/KeyMic/Clipboard/ClipboardHistoryView.swift Makefile
git commit -m "feat(clipboard-panel): multi-select via ClipboardPanelSelectionBridge (LOR-19)"
```

---

## Task 8: Add "Transform" footer button + per-row magic-wand button

**Files:**
- Modify: `Sources/KeyMic/Clipboard/ClipboardHistoryView.swift`

- [ ] **Step 1: Locate the footer (bottom bar)**

Find the bottom area of the SwiftUI body (likely the last `HStack` in the `body` containing the existing Paste button + dismissal hints). If no existing footer exists, add one.

- [ ] **Step 2: Add Transform button next to Paste**

Inside the footer `HStack`:

```swift
                Button {
                    onTransformSelected()
                } label: {
                    Label("Transform", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("l", modifiers: .option)
                .disabled(selectedIDs.isEmpty)
                .help(String(localized: "Transform selected items via LLM (⌥L)"))
```

Add the closure parameter to the `ClipboardHistoryView` initializer:

```swift
    let onTransformSelected: () -> Void
```

Wired through where `ClipboardHistoryView` is constructed (in `ClipboardController.toggle` or wherever the panel root view is built):

```swift
ClipboardHistoryView(
    selectionBridge: selectionBridge,
    // ... existing args ...
    onTransformSelected: { [weak self] in self?.transformSelected() }
)
```

- [ ] **Step 3: Add per-row magic-wand button**

Locate the row view (likely a private `struct ClipboardRow: View` around line 380+). Add a small button visible on hover (matches existing per-row affordances like the Pin button):

```swift
                Button {
                    onTransformRow(item.id)
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Transform this item"))
                .opacity(isHovered ? 1.0 : 0.0)
```

Where `onTransformRow: (UUID) -> Void` is a row-level callback. In `ClipboardHistoryView.body`, define:

```swift
                let transformRow: (UUID) -> Void = { id in
                    selectionBridge.selectedIDs = [id]
                    selectionBridge.lastClickedID = id
                    onTransformSelected()
                }
```

Pass `transformRow` down to each row constructor.

- [ ] **Step 4: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KeyMic/Clipboard/ClipboardHistoryView.swift Sources/KeyMic/Clipboard/ClipboardController.swift
git commit -m "feat(clipboard-panel): add Transform button + per-row magic-wand (LOR-19)"
```

---

## Task 9: AppDelegate construction + hotkey wiring + HotkeyRegistry registration

**Files:**
- Modify: `Sources/KeyMic/AppDelegate.swift`

- [ ] **Step 1: Add controller property**

After the existing `private var selectedTextEditorController: SelectedTextEditorController!` line (~line 30), add:

```swift
    private var clipboardTransformController: ClipboardTransformController!
```

- [ ] **Step 2: Construct in `applicationDidFinishLaunching`**

Find the existing `selectedTextEditorController = SelectedTextEditorController(...)` block. Right after it, add:

```swift
        clipboardTransformController = ClipboardTransformController(
            store: clipboardController.store,
            overlayPanel: overlayPanel
        )
        clipboardController.transformController = clipboardTransformController
        keyMonitor.onClipboardTransformHotkey = { [weak self] in
            self?.clipboardController.transformSelected()
        }
```

- [ ] **Step 3: Register in HotkeyRegistry seed list**

Find the `let builtIns: [(HotkeyFeature, HotkeyRegistry.Owner, String)] = [` block. Add a tuple after the selectedTextEditor row:

```swift
            (.clipboardTransform, .clipboardTransform, "Clipboard transformer"),
```

- [ ] **Step 4: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KeyMic/AppDelegate.swift
git commit -m "feat(editor): wire ClipboardTransformController into AppDelegate (LOR-19)"
```

---

## Task 10: Settings UI — Clipboard tab "Transform" hotkey row

**Files:**
- Modify: `Sources/KeyMic/SettingsUI/SettingsRoot.swift`

- [ ] **Step 1: Find ClipboardSettings view**

```bash
grep -n "ClipboardSettingsView\|clipboardPanel\.rawValue\|vaultPanel\.rawValue" Sources/KeyMic/SettingsUI/SettingsRoot.swift | head -8
```

The existing ClipboardSettingsView (around line 620+) renders the ⌥V and ⌥B hotkeys. We add a third row for ⌥L.

- [ ] **Step 2: Add binding helper + state**

Inside `ClipboardSettingsView`, add:

```swift
    @State private var clipboardTransformHotkeyResetError: String?
    private var clipboardTransformHotkey: Binding<String> { hotkeyBinding(hotkeyStore, for: .clipboardTransform) }
```

- [ ] **Step 3: Add the row inside the existing Hotkey section**

After the existing `vaultHotkey` row, append:

```swift
                LabeledContent("Transform:") {
                    HotkeyRecorderWithClear(
                        encoded: clipboardTransformHotkey,
                        defaultEncoded: HotkeyFeature.defaults[HotkeyFeature.clipboardTransform.rawValue]!,
                        mode: .combo,
                        validator: { cfg in hotkeyStore.validationMessage(for: cfg, owner: .feature(.clipboardTransform)) },
                        recorderWidth: 200,
                        resetAction: { clipboardTransformHotkeyResetError = resetHotkey(hotkeyStore, for: .clipboardTransform) }
                    )
                }
                if let clipboardTransformHotkeyResetError {
                    Text(clipboardTransformHotkeyResetError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
```

(Mirror the existing `vaultHotkey` row exactly, including its footer text if any.)

- [ ] **Step 4: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KeyMic/SettingsUI/SettingsRoot.swift
git commit -m "feat(settings): add Clipboard Transformer hotkey row (LOR-19)"
```

---

## Task 11: Final verification

- [ ] **Step 1: Full clean rebuild**

Run: `make clean && make build 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 2: Full test suite**

Run: `script -q /dev/null make test-all 2>&1 | tail -3`

Expected: `✅ All tests passed`.

- [ ] **Step 3: Manual smoke matrix (spec §8)**

Open `KeyMic.app`. Verify each row of the matrix in `docs/persona-platform/2026-05-22-lor-19-clipboard-transformer.md` §8:

- [ ] Panel closed + ⌥L → panel opens to clipboard tab + "Select items to transform" toast; no LLM call.
- [ ] Panel open + no selection + ⌥L → first visible row gets transformed (cursor fallback).
- [ ] Panel open + click 1 item + ⌥L → N=1 transform; new top row + pasteboard set.
- [ ] Panel open + ⌘+click 3 items + ⌥L → spinner toast → result row at top + pasteboard + "Transformed 3 items" toast.
- [ ] Hover row + click magic-wand → row becomes sole selection, transform runs.
- [ ] Multi-select state + Enter → ignored or status hint shown.
- [ ] Multi-select state + ↑/↓ → falls back to single select on new row.
- [ ] Combined input > 100 KB → error toast "Combined input too large", no LLM call.
- [ ] LLM offline / no API key → error toast with LLMRefiner's error, history untouched.

- [ ] **Step 4: Acceptance criteria checklist (spec §10)**

Walk every item in `docs/persona-platform/2026-05-22-lor-19-clipboard-transformer.md` §10. Each must be checkable.

---

## Notes for the implementer

- `HotkeySettingsStore.validationMessage(for:owner:.feature(.clipboardTransform))` returns nil/string — same shape as other features.
- `LLMRefiner.refine` is callback-based; wrap via `withCheckedContinuation` per the LOR-16 controller pattern.
- `OutputRouter.shared` must be initialised by AppDelegate before `ClipboardTransformController.transform` runs. AppDelegate already initializes it earlier in `applicationDidFinishLaunching`; the autoclosure default `OutputRouter.shared` defers the lookup until first use.
- Hover affordances on `ClipboardRow` likely use `@State private var isHovered: Bool`. If the row is a separate struct, the `onTransformRow` closure goes into its initializer.
- `ClipboardStore.add` already exists; no schema changes needed for this PR.
- The transformer uses `injectionStrategy: .clipboard` declaratively but the controller bypasses persona-resolved strategy — it routes via `.clipboard` directly. Consistent with the spec's "consumer decides whether to record history" rule (§6 of LOR-15 spec).
- Commits each independently build + test green. `make test-all` is the canonical green-light command — pipe through `script -q /dev/null` if rtk's tee wrapper truncates output.
