# LOR-18 Context Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Persona.contextMode: ContextMode` with `Persona.contextSources: Set<ContextSource>` so personas can declare fine-grained, multi-valued context (selection, clipboard top, clipboard history, future window OCR). Backward-compatible Codable migration preserves existing on-disk personas.

**Architecture:** Additive-first: introduce `ContextSource` enum + new PersonaContext fields + new `buildPrompt(transcript:sources:)` overload alongside the existing API. Migrate consumers one by one. Then drop the legacy `ContextMode` symbol and old overload in a final cleanup task. Every commit compiles and `make test-all` green.

**Tech Stack:** Swift 5.9, SwiftPM single target (KeyMic), Foundation-only standalone `swiftc` test runners under `Tests/`. No XCTest. macOS 14.

**Source spec:** `docs/persona-platform/2026-05-22-lor-18-context-sources.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/KeyMic/LLM/ContextSource.swift` | Create | `enum ContextSource` (selection/clipboardTop/clipboardHistory/windowOCR) + `displayName` |
| `Sources/KeyMic/LLM/PersonaContext.swift` | Modify | Add `clipboardHistory: [String]?` + `windowOCR: String?` fields. Add `buildPrompt(transcript:sources:)`. Remove old overload in cleanup task. |
| `Sources/KeyMic/LLM/Persona.swift` | Modify | Replace `contextMode` with `contextSources: Set<ContextSource>`. Update 5 builtin seeds. Remove `enum ContextMode`. |
| `Sources/KeyMic/LLM/PersonaStore.swift` | Modify | Switch `merge` to copy `contextSources` instead of `contextMode`. |
| `Sources/KeyMic/SettingsUI/PersonasView.swift` | Modify | Replace contextMode Picker with read-only label (UI editor is a follow-up). |
| `Sources/KeyMic/AppDelegate.swift` | Modify | Callsite at `finishTranscription` switches to `buildPrompt(transcript:sources:)`. |
| `Tests/ContextSourceTests.swift` | Create | Codable round-trip + buildPrompt section ordering + migration cases. |
| `Tests/PersonaTests.swift` | Modify | Update 5-seed assertions, remove contextMode references. |
| `Tests/PersonaStoreTests.swift` | Modify | Replace `contextMode:` in custom Persona constructors. |
| `Tests/PersonaContextTests.swift` | Modify | Migrate to `buildPrompt(transcript:sources:)`. |
| `Tests/PersonaInjectionStrategyTests.swift` | Modify | JSON literal updates legacy-decode migration test. |
| `Tests/HotkeySettingsStoreTests.swift` | Modify | One Persona constructor — replace `contextMode:` arg. |
| `Makefile` | Modify | Add `test-context-source` target; thread into `test-all`. |

---

## Task 1: Create `ContextSource` enum + tests + Makefile target

**Files:**
- Create: `Sources/KeyMic/LLM/ContextSource.swift`
- Create: `Tests/ContextSourceTests.swift`
- Modify: `Makefile` (new `test-context-source` target, append to `test-all` line)

- [ ] **Step 1: Write failing test**

`Tests/ContextSourceTests.swift`:

```swift
import Foundation

@main
struct ContextSourceTestRunner {
    static func main() {
        testAllCases()
        testCodableRoundTrip()
        testCodableArrayEncoding()
        testDisplayNameNonEmpty()
        print("ContextSourceTests passed")
    }

    static func testAllCases() {
        let expected: [ContextSource] = [.selection, .clipboardTop, .clipboardHistory, .windowOCR]
        let got = ContextSource.allCases
        if got != expected {
            FileHandle.standardError.write(Data("FAIL: ContextSource.allCases order changed\n  got: \(got)\n  expected: \(expected)\n".utf8))
            exit(1)
        }
    }

    static func testCodableRoundTrip() {
        for src in ContextSource.allCases {
            let data = try! JSONEncoder().encode(src)
            let decoded = try! JSONDecoder().decode(ContextSource.self, from: data)
            if decoded != src {
                FileHandle.standardError.write(Data("FAIL: Codable round-trip for \(src) gave \(decoded)\n".utf8))
                exit(1)
            }
        }
    }

    static func testCodableArrayEncoding() {
        // Persona's contextSources is Set<ContextSource>; encoded form is JSON array of rawValues
        // since Set<RawRepresentable> uses unkeyed container.
        let set: Set<ContextSource> = [.selection, .clipboardTop]
        let data = try! JSONEncoder().encode(set)
        let decoded = try! JSONDecoder().decode(Set<ContextSource>.self, from: data)
        if decoded != set {
            FileHandle.standardError.write(Data("FAIL: Set<ContextSource> round-trip mismatch: \(decoded) vs \(set)\n".utf8))
            exit(1)
        }
    }

    static func testDisplayNameNonEmpty() {
        for src in ContextSource.allCases {
            if src.displayName.isEmpty {
                FileHandle.standardError.write(Data("FAIL: \(src) has empty displayName\n".utf8))
                exit(1)
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails (no ContextSource source file yet)**

Run: `mkdir -p .build && swiftc Tests/ContextSourceTests.swift -o .build/context-source-tests 2>&1 | head -5`

Expected: compile fails with "cannot find 'ContextSource' in scope".

- [ ] **Step 3: Write implementation**

`Sources/KeyMic/LLM/ContextSource.swift`:

```swift
import Foundation

/// Where a persona pulls context from when assembling its LLM prompt.
/// Declared on `Persona.contextSources: Set<ContextSource>`. Order in this enum
/// defines the canonical section order in `PersonaContext.buildPrompt`.
enum ContextSource: String, Codable, CaseIterable, Hashable {
    /// Focused element's selected text (via SelectionTextProvider / LOR-17 SelectedTextReader).
    case selection
    /// Current `NSPasteboard.general.string(forType: .string)`.
    case clipboardTop
    /// Recent N items from ClipboardStore; N supplied by the consumer at prompt-build time.
    case clipboardHistory
    /// Placeholder — provider lands with LOR-20.
    case windowOCR

    var displayName: String {
        switch self {
        case .selection: return String(localized: "Selected text")
        case .clipboardTop: return String(localized: "Clipboard")
        case .clipboardHistory: return String(localized: "Clipboard history")
        case .windowOCR: return String(localized: "Window text")
        }
    }
}
```

- [ ] **Step 4: Add Makefile target**

Append after `test-selection-copy-wait` in `Makefile` (around line 506):

```makefile
test-context-source:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/ContextSource.swift \
	       Tests/ContextSourceTests.swift \
	       -o .build/context-source-tests
	.build/context-source-tests
```

Modify the `test-all:` line — append `test-context-source` to the dependency list:

Find `test-all: test test-clipboard-store …` and add `test-context-source` to the end of the chain (right before the `\n✅ All tests passed` line — i.e. the last target listed).

- [ ] **Step 5: Run test to verify it passes**

Run: `make test-context-source`

Expected: `ContextSourceTests passed`.

- [ ] **Step 6: Run full build to confirm no other breakage**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!` and no errors. (`ContextSource.swift` is unused for now — that's fine; Swift doesn't warn about unused types.)

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/LLM/ContextSource.swift Tests/ContextSourceTests.swift Makefile
git commit -m "feat(persona): add ContextSource enum (LOR-18 model foundation)"
```

---

## Task 2: Extend `PersonaContext` with new fields + new `buildPrompt(transcript:sources:)`

**Files:**
- Modify: `Sources/KeyMic/LLM/PersonaContext.swift`
- Modify: `Tests/PersonaContextTests.swift`

Goal: introduce additive API. Existing `buildPrompt(transcript:contextMode:)` stays for now so AppDelegate continues to compile.

- [ ] **Step 1: Write failing tests in `Tests/PersonaContextTests.swift` for the new overload**

Append before the closing brace of the existing test runner. Find the `static func main()` and add the new test calls in the list, then add the new test methods:

```swift
        testBuildPromptSources_empty()
        testBuildPromptSources_selectionOnly()
        testBuildPromptSources_selectionAndClipboardTop()
        testBuildPromptSources_clipboardHistoryOnly()
        testBuildPromptSources_sectionOrder()
        testBuildPromptSources_selectionEqualsClipboardTopDropsClip()
        testBuildPromptSources_emptyProvidersOmitSections()
```

Then add the methods at the bottom of the struct (before the closing brace):

```swift
    static func testBuildPromptSources_empty() {
        let ctx = PersonaContext(selection: "S", clipboardTop: "C", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [])
        expect(prompt == "T", "empty sources should return transcript only, got: \(prompt)")
    }

    static func testBuildPromptSources_selectionOnly() {
        let ctx = PersonaContext(selection: "S body", clipboardTop: "C", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.selection])
        let expected = "[Selected text]\nS body\n\n[User said]\nT"
        expect(prompt == expected, "selection-only mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_selectionAndClipboardTop() {
        let ctx = PersonaContext(selection: "S", clipboardTop: "C", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.selection, .clipboardTop])
        let expected = "[Selected text]\nS\n\n[Recent clipboard]\nC\n\n[User said]\nT"
        expect(prompt == expected, "selection+clipboardTop mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_clipboardHistoryOnly() {
        let ctx = PersonaContext(selection: nil, clipboardTop: nil, clipboardHistory: ["a", "b", "c"], windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.clipboardHistory])
        let expected = "[Clipboard history]\n1. a\n2. b\n3. c\n\n[User said]\nT"
        expect(prompt == expected, "history mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_sectionOrder() {
        // Canonical order: selection → clipboardTop → clipboardHistory → windowOCR → user
        let ctx = PersonaContext(selection: "S", clipboardTop: "C", clipboardHistory: ["h1"], windowOCR: "W")
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.windowOCR, .clipboardHistory, .clipboardTop, .selection])
        let expected = "[Selected text]\nS\n\n[Recent clipboard]\nC\n\n[Clipboard history]\n1. h1\n\n[Window text]\nW\n\n[User said]\nT"
        expect(prompt == expected, "section order mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_selectionEqualsClipboardTopDropsClip() {
        let ctx = PersonaContext(selection: "same", clipboardTop: "same", clipboardHistory: nil, windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.selection, .clipboardTop])
        let expected = "[Selected text]\nsame\n\n[User said]\nT"
        expect(prompt == expected, "duplicate dedup mismatch:\ngot: \(prompt)\nwant: \(expected)")
    }

    static func testBuildPromptSources_emptyProvidersOmitSections() {
        let ctx = PersonaContext(selection: nil, clipboardTop: "  ", clipboardHistory: [], windowOCR: nil)
        let prompt = ctx.buildPrompt(transcript: "T", sources: [.selection, .clipboardTop, .clipboardHistory, .windowOCR])
        expect(prompt == "T", "empty providers should produce no sections, got: \(prompt)")
    }
```

Also update the `PersonaContext(...)` initializer calls in the existing tests (currently only pass `selection:` and `clipboardTop:`) to add the two new parameters. Use replace_all for `PersonaContext(selection: "S", clipboardTop: nil)` → `PersonaContext(selection: "S", clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)` etc. — touch each `PersonaContext(...)` call site.

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-persona-context 2>&1 | tail -5`

Expected: fails with either compile error (missing fields/method) or "FAIL" message.

- [ ] **Step 3: Write implementation in `PersonaContext.swift`**

Replace the existing struct definition (keep the `#if canImport(AppKit)` block at the bottom). Final `PersonaContext.swift`:

```swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Raw context inputs gathered around a persona invocation.
/// Owned by the LLM layer because two consumers read it: LLMRefiner prompt building
/// and OutputRouter `.openURL` template substitution.
struct PersonaContext: Equatable {
    let selection: String?
    let clipboardTop: String?
    let clipboardHistory: [String]?
    let windowOCR: String?

    static let empty = PersonaContext(selection: nil, clipboardTop: nil, clipboardHistory: nil, windowOCR: nil)

    /// Legacy P1 entry point. Kept for backward compatibility during the LOR-18 migration.
    /// Removed in a later cleanup task once all callers move to `buildPrompt(transcript:sources:)`.
    func buildPrompt(transcript: String, contextMode: ContextMode) -> String {
        let sources: Set<ContextSource>
        switch contextMode {
        case .none: sources = []
        case .selectionAndClipboard: sources = [.selection, .clipboardTop]
        }
        return buildPrompt(transcript: transcript, sources: sources)
    }

    /// Builds the labelled user prompt for an LLM call.
    /// Sections are emitted in canonical order when present:
    ///   [Selected text] → [Recent clipboard] → [Clipboard history] → [Window text] → [User said]
    /// Empty / nil providers produce no section even when their source is in `sources`.
    /// Result capped at 7500 UTF-16 units, snapped to character boundary.
    func buildPrompt(transcript: String, sources: Set<ContextSource>) -> String {
        let sel = sources.contains(.selection)
            ? (selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""
        let clip = sources.contains(.clipboardTop)
            ? (clipboardTop?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""
        let history: [String] = sources.contains(.clipboardHistory)
            ? (clipboardHistory?.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
              } ?? [])
            : []
        let ocr = sources.contains(.windowOCR)
            ? (windowOCR?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            : ""

        var sections: [String] = []
        var includeTranscript = true

        if !sel.isEmpty {
            sections.append("[Selected text]\n\(sel)")
            if transcript == sel || sel.utf16.count > 2000 {
                includeTranscript = false
            }
        }
        if !clip.isEmpty && clip != sel {
            sections.append("[Recent clipboard]\n\(clip)")
        }
        if !history.isEmpty {
            let numbered = history.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            sections.append("[Clipboard history]\n\(numbered)")
        }
        if !ocr.isEmpty {
            sections.append("[Window text]\n\(ocr)")
        }
        if includeTranscript {
            sections.append("[User said]\n\(transcript)")
        }

        let result = sections.joined(separator: "\n\n")
        if result.utf16.count > 7500 {
            var capped = ""
            for ch in result {
                if capped.utf16.count + ch.utf16.count > 7500 { break }
                capped.append(ch)
            }
            return capped
        }
        return result
    }

    #if canImport(AppKit)
    /// Snapshots the current environment using existing providers.
    /// Captures selection + clipboard top only. `clipboardHistory` and `windowOCR`
    /// are caller-provided when needed.
    static func snapshotCurrent() -> PersonaContext {
        let sel = SelectionTextProvider.currentSelection()
        let clip = NSPasteboard.general.string(forType: .string)
        return PersonaContext(selection: sel, clipboardTop: clip, clipboardHistory: nil, windowOCR: nil)
    }
    #endif
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test-persona-context 2>&1 | tail -5`

Expected: `✅ PersonaContextTests passed`.

- [ ] **Step 5: Run full build to confirm no other breakage**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/LLM/PersonaContext.swift Tests/PersonaContextTests.swift
git commit -m "feat(persona): add PersonaContext.buildPrompt(transcript:sources:) overload (LOR-18)"
```

---

## Task 3: Add `contextSources` field to `Persona` alongside `contextMode`

**Files:**
- Modify: `Sources/KeyMic/LLM/Persona.swift`
- Modify: `Tests/PersonaTests.swift` (new assertions)

Goal: additive — old `contextMode` field still there, all 5 seeds get a `contextSources` value, init has a default so existing call sites compile.

- [ ] **Step 1: Write failing test**

Append at end of `Tests/PersonaTests.swift` `main()` (before `print("✅ PersonaTests passed")`):

```swift
        // LOR-18: contextSources derived from contextMode by default
        let seedsBuiltIn = Persona.builtInSeeds()
        expect(seedsBuiltIn[0].contextSources == [], "default persona contextSources should be empty")
        expect(seedsBuiltIn[1].contextSources == [], "translate persona contextSources should be empty")
        expect(seedsBuiltIn[2].contextSources == [], "cli persona contextSources should be empty")
        expect(seedsBuiltIn[3].contextSources == [.selection, .clipboardTop], "context persona contextSources should be [selection, clipboardTop]")
        expect(seedsBuiltIn[4].contextSources == [.selection], "general-editor persona contextSources should be [selection]")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test-persona 2>&1 | tail -5`

Expected: compile error "value of type 'Persona' has no member 'contextSources'".

- [ ] **Step 3: Update `Persona.swift`**

Add `contextSources` field declaration (insert AFTER `var contextMode: ContextMode` ~line 22):

```swift
    var contextMode: ContextMode
    var contextSources: Set<ContextSource>
```

Update designated initializer signature (insert `contextSources:` parameter with a default that maps from `contextMode`, AFTER `contextMode:` param). Replace the `init` block:

```swift
    init(id: String, name: String, icon: String, stylePrompt: String,
         temperature: Double, hotkey: String?, contextMode: ContextMode,
         contextSources: Set<ContextSource>? = nil,
         builtIn: Bool, createdAt: Date, updatedAt: Date,
         injectionStrategy: InjectionStrategy = .replaceFocusedText) {
        self.id = id
        self.name = name
        self.icon = icon
        self.stylePrompt = stylePrompt
        self.temperature = temperature
        self.hotkey = hotkey
        self.contextMode = contextMode
        self.contextSources = contextSources ?? Self.defaultSources(for: contextMode)
        self.builtIn = builtIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.injectionStrategy = injectionStrategy
    }

    /// Maps the legacy `contextMode` enum to the canonical set, used as the default
    /// when callers don't pass `contextSources` explicitly. Mirrors §5.3 of the LOR-18 spec.
    static func defaultSources(for mode: ContextMode) -> Set<ContextSource> {
        switch mode {
        case .none: return []
        case .selectionAndClipboard: return [.selection, .clipboardTop]
        }
    }
```

Update CodingKeys (append `contextSources`):

```swift
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, stylePrompt, temperature, hotkey
        case contextMode, contextSources, builtIn, createdAt, updatedAt, injectionStrategy
    }
```

Update `init(from decoder:)` — replace the body (around lines 52-66):

```swift
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.icon = try c.decode(String.self, forKey: .icon)
        self.stylePrompt = try c.decode(String.self, forKey: .stylePrompt)
        self.temperature = try c.decode(Double.self, forKey: .temperature)
        self.hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey)
        self.contextMode = try c.decode(ContextMode.self, forKey: .contextMode)
        // LOR-18: contextSources is the canonical field. Older personas.json lacks it;
        // fall back to a mapping derived from contextMode.
        if let stored = try c.decodeIfPresent(Set<ContextSource>.self, forKey: .contextSources) {
            self.contextSources = stored
        } else {
            self.contextSources = Self.defaultSources(for: self.contextMode)
        }
        self.builtIn = try c.decode(Bool.self, forKey: .builtIn)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.injectionStrategy = try c.decodeIfPresent(InjectionStrategy.self,
                                                       forKey: .injectionStrategy) ?? .replaceFocusedText
    }
```

Update the 5 built-in seeds to explicitly pass `contextSources`. Replace the 5 occurrences using the canonical mapping from spec §5.3:

| Persona id | Existing `contextMode:` line | Add after it |
|---|---|---|
| `builtin-default` | `contextMode: .none,` | `contextSources: [],` |
| `builtin-translate` | `contextMode: .none,` | `contextSources: [],` |
| `builtin-cli` | `contextMode: .none,` | `contextSources: [],` |
| `builtin-context` | `contextMode: .selectionAndClipboard,` | `contextSources: [.selection, .clipboardTop],` |
| `builtin-general-editor` | `contextMode: .none,` | `contextSources: [.selection],` |

For each of the 5 `Persona(` initializer literals in `builtInSeeds()`, inject the `contextSources:` argument right after `contextMode:`.

- [ ] **Step 4: Run test to verify it passes**

Run: `make test-persona 2>&1 | tail -5`

Expected: `✅ PersonaTests passed`.

- [ ] **Step 5: Run full test suite to confirm no Codable regressions**

Run: `make test-persona test-persona-store test-persona-context test-persona-injection-strategy test-hotkey-settings-store 2>&1 | grep -E "passed|❌|FAIL"`

Expected: all 5 lines show passed.

- [ ] **Step 6: Run `make build`**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/LLM/Persona.swift Tests/PersonaTests.swift
git commit -m "feat(persona): add contextSources field with default mapped from contextMode (LOR-18)"
```

---

## Task 4: Codable migration test — legacy JSON decodes correctly

**Files:**
- Modify: `Tests/PersonaInjectionStrategyTests.swift` (add legacy-decode case)

The existing test at line 40-53 already feeds a JSON literal with only `contextMode`. Verify it still works AND assert `contextSources` is populated by the migration.

- [ ] **Step 1: Modify the test in `Tests/PersonaInjectionStrategyTests.swift`**

Find `testDecodeMissingFieldDefaults`. Update it so that after the existing assertion on `injectionStrategy`, it also checks `contextSources`. Replace the function body:

```swift
    static func testDecodeMissingFieldDefaults() {
        // Legacy JSON: pre-LOR-15 (no injectionStrategy) and pre-LOR-18 (no contextSources).
        // contextMode == "selectionAndClipboard" should map to [.selection, .clipboardTop].
        let json = """
          {
          "id":"x","name":"X","icon":"star","stylePrompt":"sp",
          "temperature":0.5,"hotkey":null,"contextMode":"selectionAndClipboard","builtIn":false,
          "createdAt":000000.0,"updatedAt":000000.0
          }
          """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let d = try c.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: d)
        }
        let p = try! dec.decode(Persona.self, from: json)
        expect(p.injectionStrategy == .replaceFocusedText,
               "missing field should default to .replaceFocusedText, got \(p.injectionStrategy)")
        expect(p.contextSources == [.selection, .clipboardTop],
               "legacy contextMode=selectionAndClipboard should migrate to [.selection, .clipboardTop], got \(p.contextSources)")
    }
```

Add an additional `.none` migration test method. Append to the runner after the existing assertion calls in `main()`:

```swift
        testLegacyDecodeNoneContextModeMaps()
```

And add the new method:

```swift
    static func testLegacyDecodeNoneContextModeMaps() {
        let json = """
          {
          "id":"y","name":"Y","icon":"star","stylePrompt":"sp",
          "temperature":0.5,"hotkey":null,"contextMode":"none","builtIn":false,
          "createdAt":000000.0,"updatedAt":000000.0
          }
          """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let d = try c.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: d)
        }
        let p = try! dec.decode(Persona.self, from: json)
        expect(p.contextSources == [], "legacy contextMode=none should migrate to empty set, got \(p.contextSources)")
    }
```

- [ ] **Step 2: Run test to verify it passes**

Run: `make test-persona-injection-strategy 2>&1 | tail -5`

Expected: `✅ PersonaInjectionStrategyTests passed`.

- [ ] **Step 3: Commit**

```bash
git add Tests/PersonaInjectionStrategyTests.swift
git commit -m "test(persona): verify legacy JSON contextMode migrates to contextSources (LOR-18)"
```

---

## Task 5: Switch `AppDelegate` callsite to new `buildPrompt` overload

**Files:**
- Modify: `Sources/KeyMic/AppDelegate.swift` (line ~383)

- [ ] **Step 1: Update the callsite**

Find line 383 in `AppDelegate.swift`:

```swift
let userText = context.buildPrompt(transcript: trimmed, contextMode: persona.contextMode)
```

Replace with:

```swift
let userText = context.buildPrompt(transcript: trimmed, sources: persona.contextSources)
```

- [ ] **Step 2: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 3: Run dependent tests**

Run: `make test-persona test-persona-context 2>&1 | grep -E "passed|❌|FAIL"`

Expected: both passed.

- [ ] **Step 4: Commit**

```bash
git add Sources/KeyMic/AppDelegate.swift
git commit -m "refactor(persona): AppDelegate uses buildPrompt(transcript:sources:) (LOR-18)"
```

---

## Task 6: Switch `PersonaStore.merge` to copy `contextSources`

**Files:**
- Modify: `Sources/KeyMic/LLM/PersonaStore.swift` (line ~80)

- [ ] **Step 1: Inspect the merge logic**

Read lines 70-100 of `PersonaStore.swift` to find the existing `merge` (it copies persona fields). The line of interest is currently:

```swift
contextMode: source.contextMode,
```

- [ ] **Step 2: Update the merge to pass `contextSources` instead**

Replace that line with:

```swift
contextMode: source.contextMode,
contextSources: source.contextSources,
```

(Keep `contextMode` for now — it's still a field. Cleanup task drops it later.)

- [ ] **Step 3: Build and test**

Run: `make build && make test-persona-store 2>&1 | tail -5`

Expected: `Build complete!` and `✅ PersonaStoreTests passed`.

- [ ] **Step 4: Commit**

```bash
git add Sources/KeyMic/LLM/PersonaStore.swift
git commit -m "refactor(persona): PersonaStore.merge copies contextSources (LOR-18)"
```

---

## Task 7: Replace `PersonasView` contextMode Picker with read-only label

**Files:**
- Modify: `Sources/KeyMic/SettingsUI/PersonasView.swift` (lines ~183-185, ~417)

Per spec §3 Non-Goals: "UI for editing contextSources in PersonasView — covered in a follow-up; this spec only ships the model layer." So we replace the Picker with a static label that shows what the persona declares.

- [ ] **Step 1: Read current Picker code**

Lines 180-190 currently render a Picker for `contextMode`. Read the existing block to capture surrounding context (`LabeledContent`, `Form` field).

- [ ] **Step 2: Replace Picker with read-only label**

Find the block (around lines 180-190):

```swift
                LabeledContent("Context:") {
                    Picker("", selection: model.binding(\.contextMode, for: persona)) {
                        ForEach(ContextMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
```

Replace with:

```swift
                LabeledContent("Context:") {
                    Text(contextSourcesDescription(persona.contextSources))
                        .foregroundStyle(.secondary)
                }
```

Add a helper method at the bottom of the same view struct (`PersonaDetailForm` or wherever the Picker block lives — same struct as the surrounding `var body`):

```swift
    private func contextSourcesDescription(_ sources: Set<ContextSource>) -> String {
        if sources.isEmpty { return String(localized: "None") }
        // Display in canonical enum order.
        let ordered = ContextSource.allCases.filter { sources.contains($0) }
        return ordered.map(\.displayName).joined(separator: ", ")
    }
```

- [ ] **Step 3: Update the line ~417 default-persona Persona constructor**

Find the line with `contextMode: .none,` near line 417 (it's inside a "create new persona" defaults block). Add a `contextSources: []` line right after:

```swift
            contextMode: .none,
            contextSources: [],
```

- [ ] **Step 4: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KeyMic/SettingsUI/PersonasView.swift
git commit -m "refactor(personas-ui): replace contextMode Picker with read-only contextSources label (LOR-18)"
```

---

## Task 8: Update remaining test fixtures

**Files:**
- Modify: `Tests/PersonaStoreTests.swift`
- Modify: `Tests/HotkeySettingsStoreTests.swift`

Both files construct `Persona` literally; they need a `contextSources:` value for the explicit Persona literals. Since the Persona init currently auto-derives `contextSources` from `contextMode` when not passed, this MIGHT compile without change — but we want to be explicit before the next cleanup task drops `contextMode`.

- [ ] **Step 1: `Tests/PersonaStoreTests.swift` — two `Persona(` literals**

Find both `Persona(...)` literals (lines ~32-37 and ~56-61). After each `contextMode: .none,` add `contextSources: [],`. Example:

```swift
        let custom = Persona(
            id: "user-1", name: "Mine", icon: "star",
            stylePrompt: "test", temperature: 0.8, hotkey: nil,
            contextMode: .none, contextSources: [],
            builtIn: false,
            createdAt: now, updatedAt: now
        )
```

- [ ] **Step 2: `Tests/HotkeySettingsStoreTests.swift` — one `Persona(` literal at line ~58**

Same edit: add `contextSources: [],` after `contextMode: .none,`.

- [ ] **Step 3: Run tests**

Run: `make test-persona-store test-hotkey-settings-store 2>&1 | grep -E "passed|❌|FAIL"`

Expected: both passed.

- [ ] **Step 4: Commit**

```bash
git add Tests/PersonaStoreTests.swift Tests/HotkeySettingsStoreTests.swift
git commit -m "test(persona): explicit contextSources in test fixtures (LOR-18)"
```

---

## Task 9: Cleanup — remove `ContextMode`, old `contextMode` field, old `buildPrompt` overload

**Files:**
- Modify: `Sources/KeyMic/LLM/Persona.swift` (remove ContextMode + contextMode field + Codable key)
- Modify: `Sources/KeyMic/LLM/PersonaContext.swift` (remove old buildPrompt overload)
- Modify: `Sources/KeyMic/LLM/PersonaStore.swift` (drop the `contextMode: source.contextMode,` line)
- Modify: `Tests/PersonaTests.swift` (remove `contextMode ==` assertions)
- Modify: `Tests/PersonaContextTests.swift` (remove old-overload tests, keep new-overload tests)
- Modify: `Tests/PersonaStoreTests.swift` (drop `contextMode:` arg from Persona literals)
- Modify: `Tests/HotkeySettingsStoreTests.swift` (drop `contextMode:` arg)
- Modify: `Tests/PersonaInjectionStrategyTests.swift` (legacy JSON kept as a migration regression test; do NOT remove)
- Modify: `Sources/KeyMic/SettingsUI/PersonasView.swift` (drop `contextMode:` from default constructor)

- [ ] **Step 1: Remove `enum ContextMode` from `Persona.swift`**

Delete lines 3-13 (the entire `enum ContextMode { … }` definition + its `displayName`).

- [ ] **Step 2: Remove `var contextMode: ContextMode` field**

Delete the declaration (after the earlier addition, lines ~22).

- [ ] **Step 3: Update `init` signature** — drop `contextMode:` parameter, make `contextSources:` non-optional with no default:

```swift
    init(id: String, name: String, icon: String, stylePrompt: String,
         temperature: Double, hotkey: String?,
         contextSources: Set<ContextSource>,
         builtIn: Bool, createdAt: Date, updatedAt: Date,
         injectionStrategy: InjectionStrategy = .replaceFocusedText) {
        self.id = id
        // ...
        self.contextSources = contextSources
        // (no more self.contextMode)
        // ...
    }
```

Delete the `defaultSources(for:)` static helper (no longer used).

- [ ] **Step 4: Update `CodingKeys` — drop `contextMode`**

```swift
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, stylePrompt, temperature, hotkey
        case contextSources, builtIn, createdAt, updatedAt, injectionStrategy
    }
```

- [ ] **Step 5: Update `init(from decoder:)` — migrate inline from legacy `"contextMode"` JSON key**

```swift
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        // ...
        // LOR-18: contextSources is canonical. Migrate from legacy "contextMode" string if absent.
        if let stored = try c.decodeIfPresent(Set<ContextSource>.self, forKey: .contextSources) {
            self.contextSources = stored
        } else {
            self.contextSources = try Self.decodeLegacyContextMode(decoder)
        }
        // ...
    }

    private static func decodeLegacyContextMode(_ decoder: Decoder) throws -> Set<ContextSource> {
        // Legacy "contextMode" was a top-level string.
        struct Legacy: Decodable { let contextMode: String? }
        let legacy = try? Legacy(from: decoder)
        switch legacy?.contextMode {
        case "selectionAndClipboard":
            return [.selection, .clipboardTop]
        default:
            return []
        }
    }
```

- [ ] **Step 6: Update all 5 built-in seeds — drop `contextMode:` argument**

In each `Persona(` initializer call in `builtInSeeds()`, remove the `contextMode: ...,` line entirely. Keep the `contextSources: ...,` line that was added in Task 3.

- [ ] **Step 7: Update `PersonaContext.swift` — remove old `buildPrompt(transcript:contextMode:)` overload**

Delete the method block (the one that takes `contextMode:` and forwards to `sources:`).

Also delete the comment line that says "when contextMode is `.selectionAndClipboard`" if it remains.

- [ ] **Step 8: Update `PersonaStore.swift` merge call — drop `contextMode: source.contextMode,`**

Find the merge block, remove that one line.

- [ ] **Step 9: Update `Tests/PersonaTests.swift`**

Delete the JSON `contextMode` assertion lines added in the original test (line 22, 36, 37). Replace with `contextSources` assertions (Task 3 already added these — verify they're present):

```swift
        expect(seeds[3].contextSources == [.selection, .clipboardTop], "context persona contextSources")
        expect(seeds[0].contextSources == [], "default persona contextSources empty")
```

Remove the old `expect(decoded.contextMode == .selectionAndClipboard, …)` line.

Also update the `let p = Persona(...)` literal at line ~14 — drop `contextMode: .selectionAndClipboard,` and add `contextSources: [.selection, .clipboardTop],`.

- [ ] **Step 10: Update `Tests/PersonaContextTests.swift`**

Remove the old-overload tests (those calling `buildPrompt(transcript:, contextMode:)`). All new-overload tests added in Task 2 stay.

The `testNoneContextMode` method goes away. Remove it from `main()` and from the struct body.

- [ ] **Step 11: Update `Tests/PersonaStoreTests.swift`**

Both `Persona(` literals: delete the `contextMode: .none,` line (keep `contextSources: [],` added in Task 8).

- [ ] **Step 12: Update `Tests/HotkeySettingsStoreTests.swift`**

Same — delete `contextMode: .none,` line.

- [ ] **Step 13: Update `Tests/PersonaInjectionStrategyTests.swift`**

The legacy-JSON tests added in Task 4 should KEEP the `"contextMode":` key in the JSON literal — that's testing the migration path. Do NOT delete those JSON fragments.

- [ ] **Step 14: Update `Sources/KeyMic/SettingsUI/PersonasView.swift` line ~417**

Drop `contextMode: .none,` from the default-persona Persona constructor (keep `contextSources: [],` added in Task 7).

- [ ] **Step 15: Run full build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 16: Run full test suite**

Run: `script -q /dev/null make test-all 2>&1 | tail -3`

Expected: `✅ All tests passed`.

- [ ] **Step 17: Commit**

```bash
git add Sources/KeyMic/LLM/Persona.swift \
        Sources/KeyMic/LLM/PersonaContext.swift \
        Sources/KeyMic/LLM/PersonaStore.swift \
        Sources/KeyMic/SettingsUI/PersonasView.swift \
        Tests/PersonaTests.swift \
        Tests/PersonaContextTests.swift \
        Tests/PersonaStoreTests.swift \
        Tests/HotkeySettingsStoreTests.swift
git commit -m "$(cat <<'EOF'
refactor(persona): drop ContextMode in favor of contextSources (LOR-18 cleanup)

Removes the legacy `ContextMode` enum, the `contextMode` field on Persona,
the deprecated `PersonaContext.buildPrompt(transcript:contextMode:)` overload,
and all dependent test references. The Codable migration moves into
`Persona.decodeLegacyContextMode(_:)` so existing on-disk personas.json files
still decode cleanly into `contextSources`.

LOR-18 model layer complete.
EOF
)"
```

---

## Task 10: Final verification

- [ ] **Step 1: Full rebuild from clean**

Run: `make clean && make build 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 2: Full test suite**

Run: `script -q /dev/null make test-all 2>&1 | tail -3`

Expected: `✅ All tests passed`.

- [ ] **Step 3: Verify no `contextMode` / `ContextMode` references remain in Sources/**

Run: `grep -rn "contextMode\|ContextMode" Sources/ Tests/ 2>&1 | grep -v "decodeLegacyContextMode\|//\|\"contextMode\""`

Expected: empty (only the migration helper name and JSON string literals in tests should remain).

- [ ] **Step 4: Sanity-check personas.json migration (manual)**

If you have a personas.json on disk from a pre-LOR-18 build, copy a sample row:

```bash
plutil -convert json -r ~/Library/Application\ Support/KeyMic/personas.json -o - | head -30
```

After launching the rebuilt app, the file should re-save with `contextSources` populated; the old `contextMode` key may still be present (we don't actively remove it on encode, but `init(from:)` no longer reads it).

- [ ] **Step 5: Acceptance criteria checklist (spec §10)**

Self-verify each item in `docs/persona-platform/2026-05-22-lor-18-context-sources.md` §10. Anything not green → file a follow-up task.

---

## Notes for the implementer

- All steps follow KeyMic's standalone-runner convention: no XCTest, no SwiftPM `swift test`. Use `make test-*`.
- `@main`-style test files print `… passed` on success and `exit(1)` on failure. Match the pattern of `Tests/PasteboardSnapshotTests.swift`.
- Logger subsystem is `io.keymic.app`. No new log lines need adding for this PR — `PersonaStore` already logs decode failures.
- Commit messages follow conventional-commits (`feat`, `refactor`, `test`). Each commit must independently build + test green.
- `make test-all` is the canonical green-light command. Pipe through `script -q /dev/null` if the rtk tee wrapper truncates output.
