# PersonaPlatform Module Skeleton + Voice Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the `Sources/KeyMic/PersonaPlatform/` module (core types, PersonaEngine, ContextResolver, OutputRouter, 4 output strategies, 3 real context sources + OCR stub, LLMClient extraction, SpeechSessionHost) and migrate the inline voice path in `AppDelegate` onto it via `VoiceTrigger`. After this plan, the app behaves identically for voice users but the architecture is ready for R4/R5/R6/R7 triggers to plug in as drop-in additions.

**Architecture:** Single SwiftPM target. Protocol-driven module with one entry point `PersonaEngine.run(Invocation) async throws -> InvocationResult`. All inputs normalized to `TextFragment { source, text, meta }`. Output strategy carried on `Persona`, with optional per-invocation override. `LLMRefiner` is renamed and split: behavior moves to `OpenAICompatibleLLMClient` behind an `LLMClient` protocol so `PersonaEngine` is testable with a stub. `AppDelegate` shrinks from 777 → ~450 lines.

**Tech Stack:** Swift 5.9, macOS 14, SwiftPM single target. AX (`ApplicationServices`) for selection r/w. `URLSession` async/await for LLM HTTP. Standalone `swiftc` test runners (one `@main` per file) wired into Makefile rules.

**Scope NOT covered (later plans):**

- R4 `SelectionEditTrigger` + floating panel UI (LOR-16)
- R5 `ClipboardTransformTrigger` + `Edit` / `ClipboardTransformer` built-in personas (LOR-19, included only as referenced; built-in seeds land with the trigger that uses them)
- R6 `PhoneTrigger` (LOR-21)
- R7 `SkillRunner` (LOR-22)
- Real `WindowOCRSource` implementation (LOR-20 — only a stub-returning-nil ships here)
- `.runShell` / `.iTermPane` output strategies (deferred to a P3 plan together with R2.3)
- Settings UI for editing per-Persona `outputStrategy` (separate UI plan)

**Reference spec:** `docs/superpowers/specs/2026-05-20-persona-platform-decoupled-module-design.md`

---

## File Structure

**Created:**

```
Sources/KeyMic/PersonaPlatform/
  Engine/
    PersonaEngine.swift              ← run(Invocation) pipeline + nested enum Progress
    Invocation.swift                 ← Invocation + InvocationResult + BypassReason
                                       + InvocationError + TextFragment + TextSource
    LLMClient.swift                  ← protocol LLMClient + final OpenAICompatibleLLMClient
  Persona/
    Persona.swift                    ← moved from Sources/KeyMic/LLM/, extended
    PersonaStore.swift               ← moved from Sources/KeyMic/LLM/, migration v1→v2
  Context/
    ContextResolver.swift            ← protocol ContextSource + ContextResolver class
    SelectionSource.swift            ← AX read + replaceSelection(with:) (LOR-17)
    ClipboardSource.swift            ← current clipboard
    ClipboardHistorySource.swift     ← N most recent items
    WindowOCRSource.swift            ← stub returning nil (real impl in P3 plan)
  Output/
    OutputRouter.swift               ← protocol OutputStrategyHandler + OutputRouter class
    FocusedTextStrategy.swift        ← wraps existing TextInjector
    ReplaceSelectionStrategy.swift   ← AX write + fallback to focused-text
    ClipboardStrategy.swift          ← NSPasteboard.setString + markPasteboardWrite
    OpenURLStrategy.swift            ← {query} template + percent-encoding
  Triggers/
    VoiceTrigger.swift               ← replaces AppDelegate inline voice path
    SpeechSessionHost.swift          ← protocol + DefaultSpeechSessionHost class
```

**Modified:**

- `Sources/KeyMic/AppDelegate.swift` — delete `triggerDown`/`triggerUp`/`cancelRecording`/`finishTranscription`/`buildUserText`/`injectAfterPop`/`setupSpeechCallbacks`; construct PersonaPlatform; wire `KeyMonitor` callbacks to `VoiceTrigger`; forward `SpeechEngine` callbacks via `SpeechSessionHost`.
- `Makefile` — add `test-persona-engine`, `test-invocation`, `test-output-router`, `test-context-resolver`, `test-llm-client`, `test-selection-source`. Append all to `test-all`. Update `test-persona:` and `test-persona-store:` to point at new file paths. Update `test-speech-engine:` if its source list referenced the old `LLM/` path.

**Deleted:**

- `Sources/KeyMic/LLMRefiner.swift` — replaced by `Sources/KeyMic/PersonaPlatform/Engine/LLMClient.swift`. `LLMRefiner.shared` singleton removed; `LLMClient` instances are injected.
- `Sources/KeyMic/LLM/` directory (after files moved to `PersonaPlatform/Persona/`).

**Test files added** (under `Tests/`):

- `Tests/InvocationTests.swift` — `TextFragment` / `TextSource` codable round-trip; `BypassReason` / `InvocationError` shape sanity.
- `Tests/LLMClientTests.swift` — `OpenAICompatibleLLMClient.isReady`; response parsing (reuses `extractContent`/`extractErrorMessage` from old `LLMRefiner` — just verifying nothing regressed in the move).
- `Tests/SelectionSourceTests.swift` — `replaceSelection(with:)` error path (write on a non-settable element returns `.notSettable`). AX-read tests can't run headless reliably and are skipped here (covered manually).
- `Tests/ContextResolverTests.swift` — resolve table for every `ContextMode` case; trigger-prefilled fragments win.
- `Tests/OutputRouterTests.swift` — each of 4 strategies dispatches; `.replaceSelection` falls back to focused-text on `notSettable`; `.openURL` percent-encodes `{query}`.
- `Tests/PersonaEngineTests.swift` — full 5-step pipeline; `.bypassed(.emptyInput)`; `.bypassed(.llmNotConfigured)`; `.injected`; cancellation; trigger-prefilled fragments preserved.

`Tests/PersonaTests.swift` and `Tests/PersonaStoreTests.swift` already exist and need to be updated for the new fields + migration.

---

### Task 1: Move LLM/ to PersonaPlatform/Persona/ and create module directories

**Files:**
- Create directory: `Sources/KeyMic/PersonaPlatform/Engine/`
- Create directory: `Sources/KeyMic/PersonaPlatform/Persona/`
- Create directory: `Sources/KeyMic/PersonaPlatform/Context/`
- Create directory: `Sources/KeyMic/PersonaPlatform/Output/`
- Create directory: `Sources/KeyMic/PersonaPlatform/Triggers/`
- Move: `Sources/KeyMic/LLM/Persona.swift` → `Sources/KeyMic/PersonaPlatform/Persona/Persona.swift`
- Move: `Sources/KeyMic/LLM/PersonaStore.swift` → `Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift`
- Delete (after extraction in Task 6): `Sources/KeyMic/LLM/SelectionTextProvider.swift`
- Delete directory: `Sources/KeyMic/LLM/` (after Task 6)
- Modify: `Makefile` — repath `test-persona:` and `test-persona-store:` to the new file location.

This is a pure file-relocation task. No code changes inside the files. Confirms `make build` and `make test-persona test-persona-store` still pass before any logic changes.

- [ ] **Step 1: Create the new module directories**

```bash
mkdir -p Sources/KeyMic/PersonaPlatform/Engine \
         Sources/KeyMic/PersonaPlatform/Persona \
         Sources/KeyMic/PersonaPlatform/Context \
         Sources/KeyMic/PersonaPlatform/Output \
         Sources/KeyMic/PersonaPlatform/Triggers
ls -d Sources/KeyMic/PersonaPlatform/*/
```

Expected: 5 subdirectories listed.

- [ ] **Step 2: Move Persona.swift and PersonaStore.swift**

```bash
git mv Sources/KeyMic/LLM/Persona.swift Sources/KeyMic/PersonaPlatform/Persona/Persona.swift
git mv Sources/KeyMic/LLM/PersonaStore.swift Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift
ls Sources/KeyMic/LLM/
```

Expected: only `SelectionTextProvider.swift` remains in `LLM/`.

- [ ] **Step 3: Update Makefile paths for the two affected tests**

In `Makefile`, find the `test-persona:` rule and replace `Sources/KeyMic/LLM/Persona.swift` with `Sources/KeyMic/PersonaPlatform/Persona/Persona.swift`. Find `test-persona-store:` and update both source lines the same way:

```make
test-persona:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Tests/PersonaTests.swift \
	       -o .build/persona-tests
	.build/persona-tests

test-persona-store:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift \
	       Tests/PersonaStoreTests.swift \
	       -o .build/persona-store-tests
	.build/persona-store-tests
```

- [ ] **Step 4: Run the build to confirm Swift sees the moved files**

Run: `make build`
Expected: build succeeds (SwiftPM globs `Sources/KeyMic/**` so the move is transparent).

- [ ] **Step 5: Run the two affected tests**

Run: `make test-persona test-persona-store`
Expected: both print `… passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
        Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift \
        Sources/KeyMic/LLM/ \
        Makefile
git commit -m "refactor(persona): move Persona + PersonaStore into PersonaPlatform/Persona"
```

---

### Task 2: Add core types (Invocation.swift)

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift`
- Create: `Tests/InvocationTests.swift`
- Modify: `Makefile` — add `test-invocation:` rule; append to `test-all`.

Defines `TextSource`, `TextFragment`, `Invocation`, `InvocationResult`, `BypassReason`, `InvocationError`. These have no dependency on `Persona` beyond the type reference, so they compile against the existing `Persona.swift`.

`OutputStrategy` is referenced by `Invocation.outputOverride`. Since `OutputStrategy` lives on `Persona` (defined in Task 3), this task forward-declares it via a placeholder typealias inside `Invocation.swift` that Task 3 will remove. That keeps each task independently compileable.

- [ ] **Step 1: Write the failing test (Tests/InvocationTests.swift)**

```swift
import Foundation

@main
struct InvocationTestRunner {
    static func main() {
        // TextFragment codable round-trip preserves all fields.
        let frag = TextFragment(
            source: .clipboardItem,
            text: "hello",
            meta: ["index": "0"]
        )
        let data = try! JSONEncoder().encode(frag)
        let decoded = try! JSONDecoder().decode(TextFragment.self, from: data)
        expect(decoded == frag, "TextFragment round-trip preserves all fields")

        // TextSource raw values are stable strings (kept in sync with the spec).
        expect(TextSource.voice.rawValue == "voice",        "voice rawValue")
        expect(TextSource.selectedText.rawValue == "selectedText", "selectedText rawValue")
        expect(TextSource.clipboardItem.rawValue == "clipboardItem", "clipboardItem rawValue")
        expect(TextSource.userTyped.rawValue == "userTyped", "userTyped rawValue")
        expect(TextSource.phoneInput.rawValue == "phoneInput", "phoneInput rawValue")
        expect(TextSource.ocrWindow.rawValue == "ocrWindow", "ocrWindow rawValue")

        // BypassReason cases compile.
        let reasons: [BypassReason] = [.llmNotConfigured, .emptyInput, .shellConfirmDenied]
        expect(reasons.count == 3, "BypassReason has 3 cases")

        print("InvocationTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
mkdir -p .build
swiftc Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
       Tests/InvocationTests.swift \
       -o .build/invocation-tests
```

Expected: error — `Invocation.swift` does not exist yet (no such file or directory).

- [ ] **Step 3: Write Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift**

```swift
import Foundation

/// Origin tag for a TextFragment. Persona prompt building keys on this.
enum TextSource: String, Codable {
    case voice           // SpeechEngine transcript
    case selectedText    // AX kAXSelectedTextAttribute
    case clipboardItem   // ClipboardStore current/history
    case userTyped       // R4 panel keystroke input
    case phoneInput      // R6 phone push
    case ocrWindow       // R2.3 focused window OCR
}

struct TextFragment: Equatable, Codable {
    let source: TextSource
    let text: String
    let meta: [String: String]

    init(source: TextSource, text: String, meta: [String: String] = [:]) {
        self.source = source
        self.text = text
        self.meta = meta
    }
}

/// One Persona invocation. Triggers construct, Engine consumes.
struct Invocation {
    let persona: Persona
    let fragments: [TextFragment]
    let originAppBundleID: String?
    let outputOverride: OutputStrategy?
}

enum InvocationResult {
    case injected(text: String, via: OutputStrategy)
    case bypassed(reason: BypassReason)
}

enum BypassReason {
    case llmNotConfigured
    case emptyInput
    case shellConfirmDenied
}

enum InvocationError: Error {
    case llmFailed(underlying: Error)
    case contextResolveFailed(source: TextSource, underlying: Error)
    case outputFailed(strategy: OutputStrategy, underlying: Error)
    case cancelled
}
```

- [ ] **Step 4: Add a placeholder OutputStrategy in Persona.swift so this file compiles**

This is removed at Task 3 step 3. For now, append to the bottom of `Sources/KeyMic/PersonaPlatform/Persona/Persona.swift`:

```swift
// Placeholder — replaced by full enum in Task 3.
enum OutputStrategy: Codable, Equatable {
    case replaceFocusedText
}
```

- [ ] **Step 5: Add the test-invocation rule to Makefile**

Insert after `test-persona-store:`:

```make
test-invocation:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
	       Tests/InvocationTests.swift \
	       -o .build/invocation-tests
	.build/invocation-tests
```

Edit the `test-all:` line and append `test-invocation` to the list of dependencies.

- [ ] **Step 6: Run the test to verify it passes**

Run: `make test-invocation`
Expected: `InvocationTests passed`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
        Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
        Tests/InvocationTests.swift \
        Makefile
git commit -m "feat(persona): add Invocation, TextFragment, Result, Error types"
```

---

### Task 3: Extend Persona model + ContextMode + OutputStrategy

**Files:**
- Modify: `Sources/KeyMic/PersonaPlatform/Persona/Persona.swift`
- Modify: `Tests/PersonaTests.swift`

Adds `outputStrategy` and `contextCount` fields. Extends `ContextMode` with `.selection`, `.clipboard`, `.clipboardHistory`, `.windowOCR`. Replaces the placeholder `OutputStrategy` from Task 2 with the full enum. Updates the built-in seeds to set explicit defaults. Updates existing `PersonaTests.swift` for the new field shape.

- [ ] **Step 1: Update the failing test (Tests/PersonaTests.swift)**

Replace the entire file with:

```swift
import Foundation

@main
struct PersonaTestRunner {
    static func main() {
        // Codable round-trip preserves all fields including new ones.
        let p = Persona(
            id: "test",
            name: "Test",
            icon: "sparkles",
            stylePrompt: "do nothing",
            temperature: 0.5,
            hotkey: "alt+q",
            contextMode: .selectionAndClipboard,
            contextCount: 3,
            outputStrategy: .openURL(template: "https://example.com/?q={query}"),
            builtIn: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let data = try! JSONEncoder().encode(p)
        let decoded = try! JSONDecoder().decode(Persona.self, from: data)
        expect(decoded == p, "full round-trip")

        // OutputStrategy cases survive round-trip.
        for strat in allStrategies() {
            let pp = Persona(
                id: "s",
                name: "s",
                icon: "x",
                stylePrompt: "",
                temperature: 0.0,
                hotkey: nil,
                contextMode: .none,
                contextCount: 1,
                outputStrategy: strat,
                builtIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
            let d = try! JSONEncoder().encode(pp)
            let r = try! JSONDecoder().decode(Persona.self, from: d)
            expect(r.outputStrategy == strat, "OutputStrategy round-trip: \(strat)")
        }

        // ContextMode case count.
        expect(ContextMode.allCases.count == 6, "ContextMode has 6 cases")

        // Built-in seeds default to .replaceFocusedText with contextCount 1.
        for seed in Persona.builtInSeeds() {
            expect(seed.outputStrategy == .replaceFocusedText,
                "built-in \(seed.id) defaults to .replaceFocusedText")
            expect(seed.contextCount == 1,
                "built-in \(seed.id) defaults to contextCount = 1")
        }

        print("PersonaTests passed")
    }

    static func allStrategies() -> [OutputStrategy] {
        [
            .replaceFocusedText,
            .replaceSelection,
            .clipboard,
            .openURL(template: "https://x.test/{query}"),
            .runShell(command: "echo", confirm: true),
            .iTermPane(confirm: true),
        ]
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test-persona`
Expected: compile errors — `contextCount` / `outputStrategy` not in `Persona` init, new `OutputStrategy` cases not found.

- [ ] **Step 3: Replace Sources/KeyMic/PersonaPlatform/Persona/Persona.swift**

Replace the entire file with:

```swift
import Foundation

enum ContextMode: String, Codable, CaseIterable {
    case none
    case selection
    case clipboard
    case clipboardHistory          // count comes from persona.contextCount
    case selectionAndClipboard
    case windowOCR

    var displayName: String {
        switch self {
        case .none: return String(localized: "None")
        case .selection: return String(localized: "Selected text")
        case .clipboard: return String(localized: "Clipboard")
        case .clipboardHistory: return String(localized: "Clipboard history")
        case .selectionAndClipboard: return String(localized: "Selection + Clipboard")
        case .windowOCR: return String(localized: "Window OCR")
        }
    }
}

enum OutputStrategy: Codable, Equatable {
    case replaceFocusedText
    case replaceSelection
    case clipboard
    case openURL(template: String)
    case runShell(command: String, confirm: Bool)
    case iTermPane(confirm: Bool)
}

struct Persona: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var icon: String
    var stylePrompt: String
    var temperature: Double
    var hotkey: String?
    var contextMode: ContextMode
    var contextCount: Int
    var outputStrategy: OutputStrategy
    var builtIn: Bool
    var createdAt: Date
    var updatedAt: Date

    static let temperatureRange: ClosedRange<Double> = 0.0 ... 2.0

    static func builtInSeeds() -> [Persona] {
        let now = Date()
        return [
            Persona(
                id: "builtin-default",
                name: "Default",
                icon: "sparkles",
                stylePrompt: """
                    You are a conservative speech recognition error corrector. \
                    ONLY fix clear, obvious transcription mistakes. When in doubt, leave the text unchanged.

                    What to fix:
                    - English words/acronyms wrongly rendered as sound-alike tokens \
                    (e.g. "pie-thon" → "Python", "jay-son" → "JSON", "A P eye" → "API")
                    - Obvious Chinese homophone errors where context makes the correct character clear
                    - Broken English words or phrases split/merged incorrectly by the recognizer

                    What NOT to do:
                    - Do NOT rephrase, rewrite, or "improve" any text
                    - Do NOT add or remove words beyond fixing recognition errors
                    - Do NOT change text that could plausibly be correct
                    - Do NOT alter punctuation unless clearly wrong

                    If the input appears correct, return it exactly as-is. Return ONLY the text, nothing else.
                    """,
                temperature: 0.3,
                hotkey: nil,
                contextMode: .none,
                contextCount: 1,
                outputStrategy: .replaceFocusedText,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-translate",
                name: "Auto Translate",
                icon: "globe",
                stylePrompt: "Automatically detect the input language and translate it into English. Keep the tone professional and fluent. Return ONLY the translated text.",
                temperature: 0.6,
                hotkey: nil,
                contextMode: .none,
                contextCount: 1,
                outputStrategy: .replaceFocusedText,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-cli",
                name: "CLI Wizard",
                icon: "terminal",
                stylePrompt: "Convert voice transcription into executable shell commands. Be concise and accurate for technical users. Return ONLY the command, with no markdown fences.",
                temperature: 0.1,
                hotkey: nil,
                contextMode: .none,
                contextCount: 1,
                outputStrategy: .replaceFocusedText,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
            Persona(
                id: "builtin-context",
                name: "Context",
                icon: "text.quote",
                stylePrompt: """
                    You will receive three inputs:
                    1. [Selected text] — text currently selected in the foreground app (may be empty)
                    2. [Recent clipboard] — the most recent clipboard text (may be empty)
                    3. [User said] — the user's speech transcription

                    Use the context to infer the intent of [User said], then rewrite it into clearer and more accurate text.\
                    If context is empty, perform normal transcription correction. Return ONLY the rewritten text.
                    """,
                temperature: 0.5,
                hotkey: nil,
                contextMode: .selectionAndClipboard,
                contextCount: 1,
                outputStrategy: .replaceFocusedText,
                builtIn: true,
                createdAt: now,
                updatedAt: now
            ),
        ]
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test-persona`
Expected: `PersonaTests passed`.

- [ ] **Step 5: Run the dependent tests to confirm nothing else broke**

Run: `make test-invocation test-persona-store`
Expected: both pass. (PersonaStore still works because `mergeWithBuiltIns` only matches on `id` — see Task 4 for the explicit migration.)

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Persona/Persona.swift Tests/PersonaTests.swift
git commit -m "feat(persona): add outputStrategy + contextCount + extended ContextMode"
```

---

### Task 4: PersonaStore v1 → v2 migration

**Files:**
- Modify: `Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift`
- Modify: `Tests/PersonaStoreTests.swift`

A user upgrading from the shipped LOR-14 build has a v1 envelope on disk: `{ version: 1, personas: [...], activePersonaId: ... }` where each persona lacks `contextCount` and `outputStrategy`. The migration: bump `currentVersion` to 2, and on decode fill missing fields with defaults (`contextCount = 1`, `outputStrategy = .replaceFocusedText`).

Strategy: keep using `Envelope.version` for the file-level version, but introduce a custom `Persona` decode path inside `PersonaStore.load()` that decodes JSON via untyped dictionaries when the envelope version is 1, then rewrites with defaults. Cleaner approach: decode `Envelope` as `LegacyEnvelope` first (where `Persona` is `LegacyPersona` lacking new fields), upgrade to the new `Persona`, save back out at version 2.

- [ ] **Step 1: Add a failing migration test to Tests/PersonaStoreTests.swift**

Append before the closing brace of `static func main()`:

```swift
        // --- v1 → v2 migration ---
        let migTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-store-migration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: migTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: migTmp) }
        let migURL = migTmp.appendingPathComponent("personas.json")

        // Write a v1 envelope on disk (no contextCount, no outputStrategy).
        let v1Json = """
        {
          "version": 1,
          "personas": [
            {
              "id": "user-legacy",
              "name": "Legacy",
              "icon": "sparkles",
              "stylePrompt": "legacy",
              "temperature": 0.3,
              "hotkey": null,
              "contextMode": "none",
              "builtIn": false,
              "createdAt": "2026-01-01T00:00:00.000Z",
              "updatedAt": "2026-01-01T00:00:00.000Z"
            }
          ],
          "activePersonaId": null
        }
        """
        try! v1Json.data(using: .utf8)!.write(to: migURL)

        let migrated = PersonaStore(storeURL: migURL)
        let legacy = migrated.persona(id: "user-legacy")!
        expect(legacy.contextCount == 1, "v1 migration: contextCount defaults to 1")
        expect(legacy.outputStrategy == .replaceFocusedText,
            "v1 migration: outputStrategy defaults to .replaceFocusedText")

        // Reload the same file: it should now decode as v2 with no migration.
        let reloaded = PersonaStore(storeURL: migURL)
        expect(reloaded.persona(id: "user-legacy") != nil,
            "v2 reload preserves migrated user persona")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test-persona-store`
Expected: failure on the new migration assertion (either decode crash or default value not applied).

- [ ] **Step 3: Update PersonaStore.swift load() to handle v1**

Replace the `load()` method and add the migration helper. Inside `Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift`:

```swift
private static let currentVersion = 2

private func load() {
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
        seedFirstLaunch()
        return
    }
    do {
        let data = try Data(contentsOf: storeURL)
        let envelopeVersion = peekVersion(data) ?? Self.currentVersion
        let personas: [Persona]
        let activeId: String?
        if envelopeVersion < 2 {
            let upgraded = try Self.decodeLegacyV1(data)
            personas = upgraded.personas
            activeId = upgraded.activePersonaId
        } else {
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            personas = envelope.personas
            activeId = envelope.activePersonaId
        }
        self.personas = mergeWithBuiltIns(loaded: personas)
        self.activePersonaId = activeId
        if let id = activePersonaId, persona(id: id) == nil {
            activePersonaId = nil
        }
        // Always re-save: this normalizes a v1 file to v2 on disk and is a no-op for v2.
        save()
    } catch {
        logger.error("load failed: \(error.localizedDescription, privacy: .public). Re-seeding.")
        seedFirstLaunch()
    }
}

private func peekVersion(_ data: Data) -> Int? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj["version"] as? Int
}

/// Decode a v1 envelope (Personas without contextCount or outputStrategy)
/// and fill defaults: contextCount = 1, outputStrategy = .replaceFocusedText.
private static func decodeLegacyV1(_ data: Data) throws -> Envelope {
    struct LegacyPersona: Decodable {
        var id: String
        var name: String
        var icon: String
        var stylePrompt: String
        var temperature: Double
        var hotkey: String?
        var contextMode: ContextMode
        var builtIn: Bool
        var createdAt: Date
        var updatedAt: Date
    }
    struct LegacyEnvelope: Decodable {
        var version: Int
        var personas: [LegacyPersona]
        var activePersonaId: String?
    }
    let legacy = try Self.decoder.decode(LegacyEnvelope.self, from: data)
    let upgraded: [Persona] = legacy.personas.map { lp in
        Persona(
            id: lp.id,
            name: lp.name,
            icon: lp.icon,
            stylePrompt: lp.stylePrompt,
            temperature: lp.temperature,
            hotkey: lp.hotkey,
            contextMode: lp.contextMode,
            contextCount: 1,
            outputStrategy: .replaceFocusedText,
            builtIn: lp.builtIn,
            createdAt: lp.createdAt,
            updatedAt: lp.updatedAt
        )
    }
    return Envelope(
        version: 2,
        personas: upgraded,
        activePersonaId: legacy.activePersonaId
    )
}
```

(Leave `mergeWithBuiltIns`, `seedFirstLaunch`, `save`, and the encoder/decoder helpers unchanged.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test-persona-store`
Expected: all existing PersonaStore tests + the new migration test pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift Tests/PersonaStoreTests.swift
git commit -m "feat(persona): migrate PersonaStore v1 → v2 with default outputStrategy + contextCount"
```

---

### Task 5: Extract LLMClient from LLMRefiner

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Engine/LLMClient.swift`
- Create: `Tests/LLMClientTests.swift`
- Modify: `Makefile` — add `test-llm-client`; append to `test-all`.
- Leave `Sources/KeyMic/LLMRefiner.swift` and its `LLMRefiner.shared` *alone* for this task. AppDelegate still uses it. Task 15 deletes it once nothing else references it.

`OpenAICompatibleLLMClient` absorbs `apiBaseURL` / `apiKey` / `model` / `complete` / `cancel` / `extractContent` / `pickContent` / `parseFirstJSONObject` / `extractErrorMessage` verbatim from `LLMRefiner.swift`. The only behavioral change: `complete` uses `async throws -> String` instead of completion-handler form, built on `URLSession.shared.data(for:)`. UserDefaults keys (`llmAPIBaseURL` / `llmAPIKey` / `llmModel`) and logger subsystem/category stay the same.

- [ ] **Step 1: Write the failing test (Tests/LLMClientTests.swift)**

```swift
import Foundation

@main
struct LLMClientTestRunner {
    static func main() {
        // Pristine UserDefaults under a non-default suite → isReady is false.
        let suite = "io.keymic.app.llm-client.tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let client = OpenAICompatibleLLMClient(defaults: defaults)
        expect(!client.isReady, "fresh defaults → not ready")

        // Configure: ready iff URL + key + model all non-empty.
        defaults.set("https://api.example.com/v1", forKey: "llmAPIBaseURL")
        defaults.set("sk-xxxxx", forKey: "llmAPIKey")
        defaults.set("gpt-4o-mini", forKey: "llmModel")
        expect(client.isReady, "configured → ready")

        // extractContent handles OpenAI chat shape.
        let chat = #"{"choices":[{"message":{"content":"hi"}}]}"#.data(using: .utf8)!
        expect(OpenAICompatibleLLMClient.extractContent(from: chat) == "hi",
            "extractContent: OpenAI chat shape")

        // extractErrorMessage handles { error: { message: ... } }.
        let errJson = #"{"error":{"message":"rate limited"}}"#.data(using: .utf8)!
        expect(OpenAICompatibleLLMClient.extractErrorMessage(from: errJson) == "rate limited",
            "extractErrorMessage: nested .error.message")

        print("LLMClientTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
mkdir -p .build
swiftc Sources/KeyMic/PersonaPlatform/Engine/LLMClient.swift \
       Tests/LLMClientTests.swift \
       -o .build/llm-client-tests
```

Expected: `LLMClient.swift` not found.

- [ ] **Step 3: Write Sources/KeyMic/PersonaPlatform/Engine/LLMClient.swift**

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "LLMClient")

protocol LLMClient: AnyObject {
    var isReady: Bool { get }
    func complete(systemPrompt: String,
                  userText: String,
                  temperature: Double) async throws -> String
    func cancel()
}

final class OpenAICompatibleLLMClient: LLMClient {
    private let defaults: UserDefaults
    private var currentTask: URLSessionDataTask?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var apiBaseURL: String {
        get { defaults.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: "llmAPIBaseURL") }
    }
    var apiKey: String {
        get { defaults.string(forKey: "llmAPIKey") ?? "" }
        set { defaults.set(newValue, forKey: "llmAPIKey") }
    }
    var model: String {
        get { defaults.string(forKey: "llmModel") ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: "llmModel") }
    }

    var isReady: Bool {
        !apiKey.isEmpty && !apiBaseURL.isEmpty && !model.isEmpty
    }

    func complete(systemPrompt: String,
                  userText: String,
                  temperature: Double) async throws -> String {
        guard isReady else { throw LLMClientError.notReady }

        let base = apiBaseURL.hasSuffix("/") ? String(apiBaseURL.dropLast()) : apiBaseURL
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw LLMClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            "temperature": temperature,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.info("request — host=\(url.host ?? "?", privacy: .public) model=\(self.model, privacy: .public) temp=\(temperature, privacy: .public) userTextLen=\(userText.count, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let httpOK = (200..<300).contains(status)
        if httpOK, let content = Self.extractContent(from: data) {
            let refined = content.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("response — len=\(refined.count, privacy: .public)")
            return refined
        }
        let errMsg = Self.extractErrorMessage(from: data) ?? ""
        let preview = String(data: data.prefix(1024), encoding: .utf8) ?? "<non-utf8>"
        logger.error("invalid response — status=\(status, privacy: .public) bytes=\(data.count, privacy: .public) err=\(errMsg, privacy: .public) preview=\(preview, privacy: .public)")
        throw LLMClientError.invalidResponse(message: errMsg.isEmpty ? nil : errMsg)
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Parsers (verbatim from old LLMRefiner)

    static func extractContent(from data: Data) -> String? {
        if let json = parseFirstJSONObject(data), let s = pickContent(from: json) { return s }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.contains("data:") && text.contains("\n") {
            var acc = ""
            var fallback: String? = nil
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload.isEmpty || payload == "[DONE]" { continue }
                guard let d = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let chunk = pickDelta(from: obj) { acc += chunk }
                else if let full = pickContent(from: obj) { fallback = full }
            }
            if !acc.isEmpty { return acc }
            if let fallback { return fallback }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") { return trimmed }
        return nil
    }

    private static func pickContent(from json: [String: Any]) -> String? {
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let msg = first["message"] as? [String: Any], let c = msg["content"] as? String { return c }
            if let t = first["text"] as? String { return t }
            if let d = first["delta"] as? [String: Any], let c = d["content"] as? String { return c }
        }
        if let arr = json["content"] as? [[String: Any]] {
            let parts = arr.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }
            if !parts.isEmpty { return parts.joined() }
        }
        for key in ["content", "output", "response", "text", "message", "result"] {
            if let s = json[key] as? String { return s }
        }
        return nil
    }

    private static func pickDelta(from json: [String: Any]) -> String? {
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first,
           let d = first["delta"] as? [String: Any], let c = d["content"] as? String { return c }
        if let d = json["delta"] as? [String: Any], let c = d["text"] as? String { return c }
        return nil
    }

    private static func parseFirstJSONObject(_ data: Data) -> [String: Any]? {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
            return json
        }
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(of: 0x7B) else { return nil }
        var depth = 0; var inStr = false; var esc = false
        for i in start..<bytes.count {
            let b = bytes[i]
            if esc { esc = false; continue }
            if inStr {
                if b == 0x5C { esc = true; continue }
                if b == 0x22 { inStr = false }
                continue
            }
            switch b {
            case 0x22: inStr = true
            case 0x7B: depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0 {
                    let slice = data.subdata(in: start..<(i + 1))
                    return try? JSONSerialization.jsonObject(with: slice) as? [String: Any]
                }
            default: break
            }
        }
        return nil
    }

    static func extractErrorMessage(from data: Data) -> String? {
        guard let json = parseFirstJSONObject(data) else { return nil }
        if let err = json["error"] as? [String: Any] {
            return (err["message"] as? String) ?? (err["type"] as? String) ?? (err["code"] as? String)
        }
        if let s = json["error"] as? String { return s }
        if let s = json["message"] as? String { return s }
        return nil
    }
}

enum LLMClientError: LocalizedError {
    case notReady
    case invalidURL
    case invalidResponse(message: String?)

    var errorDescription: String? {
        switch self {
        case .notReady: return "LLM endpoint not configured"
        case .invalidURL: return "Invalid API base URL"
        case .invalidResponse(let m):
            return m.map { "Invalid response: \($0)" } ?? "Invalid response from LLM API"
        }
    }
}
```

- [ ] **Step 4: Add the Makefile rule**

```make
test-llm-client:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Engine/LLMClient.swift \
	       Tests/LLMClientTests.swift \
	       -o .build/llm-client-tests
	.build/llm-client-tests
```

Append `test-llm-client` to `test-all`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `make test-llm-client`
Expected: `LLMClientTests passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Engine/LLMClient.swift Tests/LLMClientTests.swift Makefile
git commit -m "feat(persona): extract LLMClient protocol + OpenAICompatibleLLMClient"
```

---

### Task 6: SelectionSource (AX read + write — LOR-17)

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift`
- Delete: `Sources/KeyMic/LLM/SelectionTextProvider.swift`
- Create: `Tests/SelectionSourceTests.swift`
- Modify: `Makefile` — add `test-selection-source`; append to `test-all`.

Wraps AX read (moved from `SelectionTextProvider`) and adds `replaceSelection(with:) throws` writing via `AXUIElementSetAttributeValue` against `kAXSelectedTextAttribute`. Throws `SelectionWriteError.notSettable` when the focused element does not implement the attribute as settable (browsers, terminals).

`ContextSource` protocol lives in `ContextResolver.swift` (Task 9). For this task we define a minimal version inline at the top of `SelectionSource.swift` and remove it in Task 9. Alternative: declare the protocol now. Choosing inline declaration keeps task ordering clean — Task 9's first step is "move the protocol into ContextResolver.swift".

- [ ] **Step 1: Write the failing test (Tests/SelectionSourceTests.swift)**

```swift
import Foundation

@main
struct SelectionSourceTestRunner {
    static func main() {
        // Provided kind sanity.
        let src = SelectionSource()
        expect(src.providedKind == .selectedText, "providedKind == .selectedText")

        // SelectionWriteError shape.
        let err = SelectionWriteError.notSettable
        expect("\(err)" == "notSettable", "SelectionWriteError.notSettable description")

        // AX-touching paths (currentSelection / replaceSelection) require a focused
        // editable element in another app and AX trust; they're exercised manually
        // and via the running app, not in headless CI.

        print("SelectionSourceTests passed")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
mkdir -p .build
swiftc Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift \
       Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
       Tests/SelectionSourceTests.swift \
       -o .build/selection-source-tests
```

Expected: `SelectionSource.swift` not found.

- [ ] **Step 3: Write Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift**

```swift
import ApplicationServices
import Foundation

// Temporary minimal protocol — moved into ContextResolver.swift in Task 9.
protocol ContextSource {
    var providedKind: TextSource { get }
    func read() async throws -> TextFragment?
}

enum SelectionWriteError: Error, CustomStringConvertible {
    case notSettable
    case axCallFailed(AXError)

    var description: String {
        switch self {
        case .notSettable: return "notSettable"
        case .axCallFailed(let e): return "axCallFailed(\(e.rawValue))"
        }
    }
}

final class SelectionSource: ContextSource {
    var providedKind: TextSource { .selectedText }

    func read() async throws -> TextFragment? {
        guard let s = Self.currentSelection(), !s.isEmpty else { return nil }
        return TextFragment(source: .selectedText, text: s, meta: [:])
    }

    /// Returns the focused element's selected text, or nil if no selection / no AX
    /// permission / the element does not implement kAXSelectedTextAttribute.
    static func currentSelection() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
              let any = focused,
              CFGetTypeID(any) == AXUIElementGetTypeID() else { return nil }
        let element = any as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selected
        ) == .success, let s = selected as? String, !s.isEmpty else { return nil }
        return s
    }

    /// Writes `text` to the focused element's selected-text attribute, replacing
    /// the current selection. Throws `SelectionWriteError.notSettable` when the
    /// element is not settable (webviews, terminal emulators), or `.axCallFailed`
    /// for other AX errors. Caller is expected to fall back (e.g. to
    /// `.replaceFocusedText` strategy) on `.notSettable`.
    static func replaceSelection(with text: String) throws {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success,
              let any = focused,
              CFGetTypeID(any) == AXUIElementGetTypeID() else {
            throw SelectionWriteError.notSettable
        }
        let element = any as! AXUIElement

        var settable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        )
        guard settableStatus == .success, settable.boolValue else {
            throw SelectionWriteError.notSettable
        }

        let status = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        guard status == .success else {
            throw SelectionWriteError.axCallFailed(status)
        }
    }
}
```

- [ ] **Step 4: Delete the old file**

```bash
git rm Sources/KeyMic/LLM/SelectionTextProvider.swift
```

This removes the last file in `Sources/KeyMic/LLM/`. Confirm the directory is empty afterward:

```bash
ls Sources/KeyMic/LLM/ 2>/dev/null || echo "(directory removed)"
```

- [ ] **Step 5: Update any remaining references**

Search for `SelectionTextProvider`:

```bash
grep -rn "SelectionTextProvider" Sources/ Tests/
```

In `Sources/KeyMic/AppDelegate.swift`, replace `SelectionTextProvider.currentSelection()` with `SelectionSource.currentSelection()` (one site, inside `buildUserText`). The line is unchanged otherwise — `buildUserText` still exists and still uses the static read; Task 14 retires `buildUserText` entirely.

```bash
grep -rn "SelectionTextProvider" Sources/ Tests/
```

Expected: no matches.

- [ ] **Step 6: Add Makefile rule**

```make
test-selection-source:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift \
	       Tests/SelectionSourceTests.swift \
	       -o .build/selection-source-tests
	.build/selection-source-tests
```

Append `test-selection-source` to `test-all`.

- [ ] **Step 7: Run build + test**

Run: `make build && make test-selection-source`
Expected: build succeeds, test prints `SelectionSourceTests passed`.

- [ ] **Step 8: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift \
        Sources/KeyMic/LLM/SelectionTextProvider.swift \
        Sources/KeyMic/AppDelegate.swift \
        Tests/SelectionSourceTests.swift \
        Makefile
git commit -m "feat(persona): add SelectionSource with AX read + write (LOR-17)"
```

---

### Task 7: ClipboardSource + ClipboardHistorySource

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Context/ClipboardSource.swift`
- Create: `Sources/KeyMic/PersonaPlatform/Context/ClipboardHistorySource.swift`

These read from the existing `ClipboardStore` (passed at init). `ClipboardSource` (current item) implements `ContextSource`. `ClipboardHistorySource` is a separate type because its API returns `[TextFragment]` instead of `TextFragment?`.

Behavioral contract:
- `ClipboardSource.read()` → returns `TextFragment(source: .clipboardItem, text: store.mostRecentText() ?? NSPasteboard fallback, meta: ["index": "0"])`, or `nil` if both sources are empty.
- `ClipboardHistorySource.read(count:)` → returns up to `count` most recent items from the store, each tagged with `meta: ["index": "<i>"]` where `i` is `0` for newest.

We don't have a unit test runner for these because they need `ClipboardStore` set up with SwiftData; covered by `ContextResolverTests` in Task 9 using a `StubClipboardSource`. So this task ships code only and is validated by `make build`.

Verified `ClipboardStore` API (this commit's repo state): `fetchAll() -> [ClipboardItem]` returns items sorted newest-first by `createdAt`. `ClipboardItem.text` is a non-optional `String`. `ClipboardItem.kind: ClipboardKind` enumerates `.plain`, `.richText`, `.image`, `.file`, `.secret`. For LLM context we want only `.plain` items — `.secret` is vault-controlled and must not leak; `.image`/`.file` have empty or placeholder text; `.richText` could include markup we don't want to send.

- [ ] **Step 1: Write Sources/KeyMic/PersonaPlatform/Context/ClipboardSource.swift**

```swift
import AppKit
import Foundation

final class ClipboardSource: ContextSource {
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    var providedKind: TextSource { .clipboardItem }

    func read() async throws -> TextFragment? {
        if let text = await mostRecentPlainText(), !text.isEmpty {
            return TextFragment(source: .clipboardItem, text: text, meta: ["index": "0"])
        }
        // Fallback to live pasteboard (covers items copied before app start).
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            return TextFragment(source: .clipboardItem, text: s, meta: ["index": "0"])
        }
        return nil
    }

    @MainActor
    private func mostRecentPlainText() -> String? {
        store.fetchAll()
            .first { $0.kind == .plain }?
            .text
    }
}
```

- [ ] **Step 2: Write Sources/KeyMic/PersonaPlatform/Context/ClipboardHistorySource.swift**

```swift
import Foundation

final class ClipboardHistorySource {
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Returns up to `count` most-recent `.plain` clipboard items, newest first,
    /// each tagged with meta["index"] = "<i>" (0 = newest).
    func read(count: Int) async throws -> [TextFragment] {
        guard count > 0 else { return [] }
        let texts = await fetchRecentPlainTexts(count: count)
        return texts.enumerated().map { (i, text) in
            TextFragment(source: .clipboardItem, text: text, meta: ["index": String(i)])
        }
    }

    @MainActor
    private func fetchRecentPlainTexts(count: Int) -> [String] {
        store.fetchAll()
            .lazy
            .filter { $0.kind == .plain }
            .prefix(count)
            .map(\.text)
            .filter { !$0.isEmpty }
    }
}
```

Both files use `ClipboardStore.fetchAll()` directly; no changes to `ClipboardStore` are needed for this task. (Future plans may add a dedicated `recent(kind:limit:)` if profiling shows the unfiltered fetch is hot — out of scope here.)

- [ ] **Step 3: Run the build**

Run: `make build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Context/ClipboardSource.swift \
        Sources/KeyMic/PersonaPlatform/Context/ClipboardHistorySource.swift
git commit -m "feat(persona): add ClipboardSource + ClipboardHistorySource"
```

---

### Task 8: WindowOCRSource stub

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Context/WindowOCRSource.swift`

Placeholder so the wiring compiles in P1 / P2. Real implementation lands in a P3 plan together with LOR-20. The stub always returns `nil`, never throws, and logs once that OCR is disabled.

- [ ] **Step 1: Write Sources/KeyMic/PersonaPlatform/Context/WindowOCRSource.swift**

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "WindowOCRSource")

/// Placeholder. Real focused-window OCR (ScreenCaptureKit + VNRecognizeTextRequest)
/// lands with LOR-20 in a separate plan. Returns nil so personas with
/// `contextMode = .windowOCR` degrade to LLM-only on the rest of the fragments.
final class WindowOCRSource: ContextSource {
    private var loggedDisabled = false

    var providedKind: TextSource { .ocrWindow }

    func read() async throws -> TextFragment? {
        if !loggedDisabled {
            loggedDisabled = true
            logger.info("OCR source not implemented yet — returning nil")
        }
        return nil
    }
}
```

- [ ] **Step 2: Run the build**

Run: `make build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Context/WindowOCRSource.swift
git commit -m "feat(persona): add WindowOCRSource stub (real impl deferred to LOR-20)"
```

---

### Task 9: ContextResolver

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Context/ContextResolver.swift`
- Modify: `Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift` — remove the inline `ContextSource` protocol declaration (Task 6 placed it here temporarily).
- Create: `Tests/ContextResolverTests.swift`
- Modify: `Makefile` — add `test-context-resolver`; append to `test-all`.

`ContextResolver` is constructed with four sources. `resolve(persona:prefilled:)` returns a complete `[TextFragment]` per the resolve table in spec §7.

- [ ] **Step 1: Write the failing test (Tests/ContextResolverTests.swift)**

```swift
import Foundation

@main
struct ContextResolverTestRunner {
    static func main() {
        runResolveTable()
        runTriggerPrefillWins()
        runClipboardHistoryCount()
        print("ContextResolverTests passed")
    }

    static func runResolveTable() {
        let res = makeResolver(
            selectionText: "SEL",
            clipboardText: "CLIP",
            historyTexts: ["H0", "H1", "H2"],
            ocrText: nil
        )

        // .none — nothing added
        var out = sync(res.resolve(persona: persona(.none), prefilled: []))
        expect(out.isEmpty, "contextMode .none → no fragments")

        // .selection
        out = sync(res.resolve(persona: persona(.selection), prefilled: []))
        expect(out.map(\.source) == [.selectedText], ".selection → [selectedText]")
        expect(out[0].text == "SEL", ".selection → text 'SEL'")

        // .clipboard
        out = sync(res.resolve(persona: persona(.clipboard), prefilled: []))
        expect(out.map(\.source) == [.clipboardItem], ".clipboard → [clipboardItem]")
        expect(out[0].text == "CLIP", ".clipboard → text 'CLIP'")

        // .clipboardHistory (default contextCount = 1)
        out = sync(res.resolve(persona: persona(.clipboardHistory, count: 2), prefilled: []))
        expect(out.count == 2, ".clipboardHistory count=2 → 2 fragments")
        expect(out[0].text == "H0" && out[1].text == "H1",
            ".clipboardHistory returns newest first")

        // .selectionAndClipboard
        out = sync(res.resolve(persona: persona(.selectionAndClipboard), prefilled: []))
        expect(out.map(\.source) == [.selectedText, .clipboardItem],
            ".selectionAndClipboard → both, selection first")

        // .windowOCR (stub returns nil → no fragment added)
        out = sync(res.resolve(persona: persona(.windowOCR), prefilled: []))
        expect(out.isEmpty, ".windowOCR with stub → no fragments")
    }

    static func runTriggerPrefillWins() {
        let res = makeResolver(
            selectionText: "SEL-FROM-AX",
            clipboardText: "CLIP",
            historyTexts: [],
            ocrText: nil
        )
        let prefilled = [TextFragment(source: .selectedText, text: "TRIGGER-WINS", meta: [:])]
        let out = sync(res.resolve(persona: persona(.selectionAndClipboard), prefilled: prefilled))
        let sel = out.first { $0.source == .selectedText }
        expect(sel?.text == "TRIGGER-WINS",
            "trigger-prefilled .selectedText wins over resolver AX read")
        expect(out.contains { $0.source == .clipboardItem && $0.text == "CLIP" },
            ".clipboard still resolved when not prefilled")
    }

    static func runClipboardHistoryCount() {
        let res = makeResolver(
            selectionText: nil,
            clipboardText: nil,
            historyTexts: ["A", "B", "C", "D"],
            ocrText: nil
        )
        let out = sync(res.resolve(persona: persona(.clipboardHistory, count: 3), prefilled: []))
        expect(out.count == 3, "clipboardHistory respects persona.contextCount")
    }

    // MARK: helpers

    static func makeResolver(
        selectionText: String?,
        clipboardText: String?,
        historyTexts: [String],
        ocrText: String?
    ) -> ContextResolver {
        ContextResolver(
            selection: StubSource(.selectedText, text: selectionText),
            clipboard: StubSource(.clipboardItem, text: clipboardText),
            clipboardHistory: StubClipboardHistorySource(texts: historyTexts),
            windowOCR: StubSource(.ocrWindow, text: ocrText)
        )
    }

    static func persona(_ mode: ContextMode, count: Int = 1) -> Persona {
        Persona(
            id: "test", name: "T", icon: "x", stylePrompt: "",
            temperature: 0.0, hotkey: nil,
            contextMode: mode, contextCount: count,
            outputStrategy: .replaceFocusedText,
            builtIn: false,
            createdAt: Date(), updatedAt: Date()
        )
    }

    static func sync<T>(_ work: @autoclosure () async -> T) -> T {
        // Synchronously run an async expression on a fresh Task — sufficient for
        // our pure in-memory stubs (no actual concurrency).
        var result: T?
        let sema = DispatchSemaphore(value: 0)
        Task { result = await work(); sema.signal() }
        sema.wait()
        return result!
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}

final class StubSource: ContextSource {
    let providedKind: TextSource
    private let text: String?
    init(_ kind: TextSource, text: String?) {
        self.providedKind = kind
        self.text = text
    }
    func read() async throws -> TextFragment? {
        guard let t = text, !t.isEmpty else { return nil }
        return TextFragment(source: providedKind, text: t, meta: [:])
    }
}

final class StubClipboardHistorySource: ClipboardHistorySourceProtocol {
    let texts: [String]
    init(texts: [String]) { self.texts = texts }
    func read(count: Int) async throws -> [TextFragment] {
        texts.prefix(count).enumerated().map { (i, t) in
            TextFragment(source: .clipboardItem, text: t, meta: ["index": String(i)])
        }
    }
}
```

(`ClipboardHistorySourceProtocol` is introduced in Step 3 below so tests can inject a stub; the real `ClipboardHistorySource` from Task 7 conforms via an extension.)

- [ ] **Step 2: Run the test to verify it fails**

```bash
mkdir -p .build
swiftc Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
       Sources/KeyMic/PersonaPlatform/Context/ContextResolver.swift \
       Tests/ContextResolverTests.swift \
       -o .build/context-resolver-tests
```

Expected: `ContextResolver.swift` missing.

- [ ] **Step 3: Write Sources/KeyMic/PersonaPlatform/Context/ContextResolver.swift**

```swift
import Foundation

protocol ContextSource {
    var providedKind: TextSource { get }
    func read() async throws -> TextFragment?
}

protocol ClipboardHistorySourceProtocol {
    func read(count: Int) async throws -> [TextFragment]
}

extension ClipboardHistorySource: ClipboardHistorySourceProtocol {}

final class ContextResolver {
    private let selection: ContextSource
    private let clipboard: ContextSource
    private let clipboardHistory: ClipboardHistorySourceProtocol
    private let windowOCR: ContextSource

    init(selection: ContextSource,
         clipboard: ContextSource,
         clipboardHistory: ClipboardHistorySourceProtocol,
         windowOCR: ContextSource) {
        self.selection = selection
        self.clipboard = clipboard
        self.clipboardHistory = clipboardHistory
        self.windowOCR = windowOCR
    }

    /// Fills gaps based on persona.contextMode. Existing fragments of the same
    /// source are kept (trigger wins over resolver).
    func resolve(persona: Persona, prefilled: [TextFragment]) async -> [TextFragment] {
        var out = prefilled
        let have: (TextSource) -> Bool = { kind in out.contains { $0.source == kind } }

        func addIfMissing(_ kind: TextSource, via src: ContextSource) async {
            guard !have(kind) else { return }
            if let frag = try? await src.read() { out.append(frag) }
        }

        switch persona.contextMode {
        case .none:
            break
        case .selection:
            await addIfMissing(.selectedText, via: selection)
        case .clipboard:
            await addIfMissing(.clipboardItem, via: clipboard)
        case .clipboardHistory:
            // History always resolved (even if prefilled has clipboard, history is
            // a distinct user request for N items).
            if let frags = try? await clipboardHistory.read(count: max(0, persona.contextCount)) {
                out.append(contentsOf: frags)
            }
        case .selectionAndClipboard:
            await addIfMissing(.selectedText, via: selection)
            await addIfMissing(.clipboardItem, via: clipboard)
        case .windowOCR:
            await addIfMissing(.ocrWindow, via: windowOCR)
        }
        return out
    }
}
```

- [ ] **Step 4: Remove the temporary protocol from SelectionSource.swift**

In `Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift`, delete the lines:

```swift
// Temporary minimal protocol — moved into ContextResolver.swift in Task 9.
protocol ContextSource {
    var providedKind: TextSource { get }
    func read() async throws -> TextFragment?
}
```

The class declaration `final class SelectionSource: ContextSource { ... }` stays — it now picks up the protocol from `ContextResolver.swift`.

- [ ] **Step 5: Update SelectionSource test rule to include ContextResolver.swift**

Replace the `test-selection-source` rule with:

```make
test-selection-source:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ContextResolver.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ClipboardHistorySource.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Tests/SelectionSourceTests.swift \
	       -o .build/selection-source-tests
	.build/selection-source-tests
```

(SelectionSource now needs `ContextSource` from `ContextResolver.swift`, and the file imports `ContextResolver.swift` transitively brings `ClipboardHistorySourceProtocol`; the simplest fix is to include the full chain in the test rule.)

- [ ] **Step 6: Add test-context-resolver to Makefile**

```make
test-context-resolver:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ClipboardSource.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ClipboardHistorySource.swift \
	       Sources/KeyMic/PersonaPlatform/Context/WindowOCRSource.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ContextResolver.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Tests/ContextResolverTests.swift \
	       -o .build/context-resolver-tests
	.build/context-resolver-tests
```

Append `test-context-resolver` to `test-all`.

- [ ] **Step 7: Run tests**

Run: `make test-context-resolver test-selection-source`
Expected: both pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Context/ContextResolver.swift \
        Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift \
        Tests/ContextResolverTests.swift \
        Makefile
git commit -m "feat(persona): add ContextResolver with all 6 contextMode resolve rules"
```

---

### Task 10: Output strategies (4 handlers)

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Output/FocusedTextStrategy.swift`
- Create: `Sources/KeyMic/PersonaPlatform/Output/ReplaceSelectionStrategy.swift`
- Create: `Sources/KeyMic/PersonaPlatform/Output/ClipboardStrategy.swift`
- Create: `Sources/KeyMic/PersonaPlatform/Output/OpenURLStrategy.swift`

Defines `OutputStrategyHandler` protocol in `FocusedTextStrategy.swift` (moved into `OutputRouter.swift` at Task 11), four concrete handlers. `.runShell` / `.iTermPane` are deferred. Each handler is testable by injecting its dependency (TextInjector, ClipboardController, NSWorkspace).

For testability, all UI-touching side effects are routed through small injected closures so the OutputRouterTests in Task 11 can spy on them.

- [ ] **Step 1: Write FocusedTextStrategy.swift (also declares OutputStrategyHandler temporarily)**

```swift
import Foundation
import AppKit

// Temporary location — moves into OutputRouter.swift in Task 11.
protocol OutputStrategyHandler {
    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws
}

struct StrategyOptions {
    let reactivateOrigin: Bool

    static let defaults = StrategyOptions(reactivateOrigin: true)
}

final class FocusedTextStrategy: OutputStrategyHandler {
    private let inject: (String) -> Void
    private let reactivate: (String) -> Void

    init(textInjector: TextInjector,
         reactivate: @escaping (String) -> Void = { bundleID in
             if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                 app.activate(options: [])
             }
         }) {
        self.inject = { text in textInjector.inject(text) }
        self.reactivate = reactivate
    }

    /// Test-only init that takes a custom inject closure.
    init(inject: @escaping (String) -> Void,
         reactivate: @escaping (String) -> Void) {
        self.inject = inject
        self.reactivate = reactivate
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        if options.reactivateOrigin, let bid = origin {
            await MainActor.run { self.reactivate(bid) }
        }
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms (matches existing injectAfterPop)
        await MainActor.run { self.inject(text) }
    }
}
```

- [ ] **Step 2: Write ReplaceSelectionStrategy.swift**

```swift
import Foundation

final class ReplaceSelectionStrategy: OutputStrategyHandler {
    private let writeSelection: (String) throws -> Void
    private let fallback: FocusedTextStrategy

    init(fallback: FocusedTextStrategy,
         writeSelection: @escaping (String) throws -> Void = { try SelectionSource.replaceSelection(with: $0) }) {
        self.writeSelection = writeSelection
        self.fallback = fallback
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        do {
            try writeSelection(text)
        } catch SelectionWriteError.notSettable {
            // Documented fallback to focused-text inject.
            try await fallback.dispatch(text: text, origin: origin, options: options)
        }
    }
}
```

- [ ] **Step 3: Write ClipboardStrategy.swift**

```swift
import AppKit
import Foundation

final class ClipboardStrategy: OutputStrategyHandler {
    private let write: (String) -> Void

    init(controller: ClipboardController) {
        self.write = { [weak controller] text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            controller?.markPasteboardWrite(text)
        }
    }

    /// Test-only init.
    init(write: @escaping (String) -> Void) {
        self.write = write
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        await MainActor.run { self.write(text) }
    }
}
```

- [ ] **Step 4: Write OpenURLStrategy.swift**

```swift
import AppKit
import Foundation

enum OpenURLError: Error, Equatable {
    case missingPlaceholder
    case invalidURL
}

final class OpenURLStrategy: OutputStrategyHandler {
    private let template: String
    private let opener: (URL) -> Void

    init(template: String,
         opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.template = template
        self.opener = opener
    }

    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws {
        guard template.contains("{query}") else { throw OpenURLError.missingPlaceholder }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let filled = template.replacingOccurrences(of: "{query}", with: encoded)
        guard let url = URL(string: filled) else { throw OpenURLError.invalidURL }
        await MainActor.run { self.opener(url) }
    }
}
```

Note: `OpenURLStrategy.template` is set per-instance because each Persona may use a different template. The `OutputRouter` (Task 11) chooses the right handler instance dynamically via the `.openURL(template:)` enum payload. Alternative: a single handler that takes the template at dispatch time. We use the dynamic-construction model in Task 11 to keep this file simple.

- [ ] **Step 5: Run the build to make sure all four files compile**

Run: `make build`
Expected: build succeeds. No tests yet — Task 11 adds the OutputRouter test which exercises all four handlers.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Output/FocusedTextStrategy.swift \
        Sources/KeyMic/PersonaPlatform/Output/ReplaceSelectionStrategy.swift \
        Sources/KeyMic/PersonaPlatform/Output/ClipboardStrategy.swift \
        Sources/KeyMic/PersonaPlatform/Output/OpenURLStrategy.swift
git commit -m "feat(persona): add 4 output strategies (focused, replaceSelection, clipboard, openURL)"
```

---

### Task 11: OutputRouter

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Output/OutputRouter.swift`
- Modify: `Sources/KeyMic/PersonaPlatform/Output/FocusedTextStrategy.swift` — delete the temporary `OutputStrategyHandler` and `StrategyOptions` declarations (they move into `OutputRouter.swift`).
- Create: `Tests/OutputRouterTests.swift`
- Modify: `Makefile` — add `test-output-router`; append to `test-all`.

Router is constructed with the four "primitive" handlers. `.openURL(template:)` is handled inline (the router constructs an `OpenURLStrategy` per dispatch from the template, since the template is part of the enum payload). `.runShell` / `.iTermPane` throw `OutputError.notSupportedYet` until their P3 plan lands.

- [ ] **Step 1: Write the failing test (Tests/OutputRouterTests.swift)**

```swift
import Foundation

@main
struct OutputRouterTestRunner {
    static func main() {
        Task {
            await runAll()
            print("OutputRouterTests passed")
            exit(0)
        }
        RunLoop.main.run()
    }

    static func runAll() async {
        // .replaceFocusedText dispatches via the focused-text handler.
        var injected: [String] = []
        let focused = FocusedTextStrategy(
            inject: { injected.append($0) },
            reactivate: { _ in }
        )
        var routerPasses: [String] = []
        let clipWrites: ArrayRef<String> = ArrayRef()
        let urlOpens: ArrayRef<URL> = ArrayRef()

        let router = OutputRouter(
            focusedText: focused,
            replaceSelection: ReplaceSelectionStrategy(
                fallback: focused,
                writeSelection: { _ in throw SelectionWriteError.notSettable }
            ),
            clipboard: ClipboardStrategy(write: { clipWrites.values.append($0) }),
            openURLFactory: { template in
                OpenURLStrategy(template: template, opener: { urlOpens.values.append($0) })
            }
        )

        try! await router.dispatch(.replaceFocusedText, text: "hello", origin: nil)
        expect(injected == ["hello"], ".replaceFocusedText → injects")

        // .replaceSelection with notSettable error falls back to focused-text.
        injected.removeAll()
        try! await router.dispatch(.replaceSelection, text: "bye", origin: nil)
        expect(injected == ["bye"], ".replaceSelection → fallback to focused-text on notSettable")

        // .clipboard writes via clipboard handler only (no inject).
        injected.removeAll()
        try! await router.dispatch(.clipboard, text: "clip", origin: nil)
        expect(clipWrites.values == ["clip"], ".clipboard → writes pasteboard")
        expect(injected.isEmpty, ".clipboard → does NOT inject")

        // .openURL percent-encodes {query} and opens.
        try! await router.dispatch(
            .openURL(template: "https://duck.test/?q={query}"),
            text: "hello world & co",
            origin: nil
        )
        expect(urlOpens.values.count == 1, ".openURL → opens URL")
        let opened = urlOpens.values[0].absoluteString
        expect(opened.contains("hello%20world"),
            ".openURL percent-encodes spaces: \(opened)")
        expect(opened.contains("%26"),
            ".openURL percent-encodes ampersand: \(opened)")

        // .openURL with no {query} throws missingPlaceholder.
        do {
            try await router.dispatch(
                .openURL(template: "https://no-placeholder.test/"),
                text: "x",
                origin: nil
            )
            expect(false, ".openURL without {query} should throw")
        } catch OpenURLError.missingPlaceholder {
            // expected
        } catch {
            expect(false, ".openURL missingPlaceholder expected, got \(error)")
        }

        // .runShell and .iTermPane throw notSupportedYet (P3 deferred).
        do {
            try await router.dispatch(.runShell(command: "echo", confirm: true),
                                      text: "x", origin: nil)
            expect(false, ".runShell should throw notSupportedYet")
        } catch OutputError.notSupportedYet { /* ok */ } catch { expect(false, "wrong err") }

        do {
            try await router.dispatch(.iTermPane(confirm: true), text: "x", origin: nil)
            expect(false, ".iTermPane should throw notSupportedYet")
        } catch OutputError.notSupportedYet { /* ok */ } catch { expect(false, "wrong err") }
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }
}

final class ArrayRef<T> { var values: [T] = [] }
```

- [ ] **Step 2: Write Sources/KeyMic/PersonaPlatform/Output/OutputRouter.swift**

```swift
import Foundation

enum OutputError: Error {
    case notSupportedYet
}

final class OutputRouter {
    private let focusedText: OutputStrategyHandler
    private let replaceSelection: OutputStrategyHandler
    private let clipboard: OutputStrategyHandler
    private let openURLFactory: (String) -> OutputStrategyHandler

    init(focusedText: OutputStrategyHandler,
         replaceSelection: OutputStrategyHandler,
         clipboard: OutputStrategyHandler,
         openURLFactory: @escaping (String) -> OutputStrategyHandler) {
        self.focusedText = focusedText
        self.replaceSelection = replaceSelection
        self.clipboard = clipboard
        self.openURLFactory = openURLFactory
    }

    func dispatch(_ strategy: OutputStrategy,
                  text: String,
                  origin: String?,
                  options: StrategyOptions = .defaults) async throws {
        switch strategy {
        case .replaceFocusedText:
            try await focusedText.dispatch(text: text, origin: origin, options: options)
        case .replaceSelection:
            try await replaceSelection.dispatch(text: text, origin: origin, options: options)
        case .clipboard:
            try await clipboard.dispatch(text: text, origin: origin, options: options)
        case .openURL(let template):
            let handler = openURLFactory(template)
            try await handler.dispatch(text: text, origin: origin, options: options)
        case .runShell, .iTermPane:
            // P3 plan implements these. Built-in personas do not use them.
            throw OutputError.notSupportedYet
        }
    }
}
```

- [ ] **Step 3: Remove the duplicate OutputStrategyHandler from FocusedTextStrategy.swift**

In `Sources/KeyMic/PersonaPlatform/Output/FocusedTextStrategy.swift`, delete:

```swift
// Temporary location — moves into OutputRouter.swift in Task 11.
protocol OutputStrategyHandler {
    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws
}

struct StrategyOptions {
    let reactivateOrigin: Bool

    static let defaults = StrategyOptions(reactivateOrigin: true)
}
```

These now live in `OutputRouter.swift`. The protocol declaration moves to the top of `OutputRouter.swift` (add it above `enum OutputError`):

```swift
protocol OutputStrategyHandler {
    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws
}

struct StrategyOptions {
    let reactivateOrigin: Bool

    static let defaults = StrategyOptions(reactivateOrigin: true)
}
```

- [ ] **Step 4: Add the Makefile rule**

```make
test-output-router:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Output/FocusedTextStrategy.swift \
	       Sources/KeyMic/PersonaPlatform/Output/ReplaceSelectionStrategy.swift \
	       Sources/KeyMic/PersonaPlatform/Output/ClipboardStrategy.swift \
	       Sources/KeyMic/PersonaPlatform/Output/OpenURLStrategy.swift \
	       Sources/KeyMic/PersonaPlatform/Output/OutputRouter.swift \
	       Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ContextResolver.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ClipboardHistorySource.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Sources/KeyMic/Clipboard/ClipboardController.swift \
	       Sources/KeyMic/TextInjector.swift \
	       Tests/OutputRouterTests.swift \
	       -o .build/output-router-tests
	.build/output-router-tests
```

If the build of `test-output-router` fails because `ClipboardController.swift` or `TextInjector.swift` drag in SwiftData/AppKit types the linker can't resolve in the standalone runner, switch the test rule to use only the spy-friendly inits (which take closures, not real `TextInjector` / `ClipboardController`). Concretely: drop the `Sources/KeyMic/Clipboard/ClipboardController.swift` and `Sources/KeyMic/TextInjector.swift` lines and instead build the test using only the strategy files plus `OutputRouter.swift`, `Invocation.swift`, `Persona.swift`, and `SelectionSource.swift`. The test uses the spy `inject`/`write`/`opener` closure inits exclusively, so the production-init paths are never linked.

Append `test-output-router` to `test-all`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `make test-output-router`
Expected: `OutputRouterTests passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Output/ \
        Tests/OutputRouterTests.swift \
        Makefile
git commit -m "feat(persona): add OutputRouter dispatching 4 strategies + .openURL factory"
```

---

### Task 12: PersonaEngine

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Engine/PersonaEngine.swift`
- Create: `Tests/PersonaEngineTests.swift`
- Modify: `Makefile` — add `test-persona-engine`; append to `test-all`.

Implements the 5-step pipeline. Holds `LLMClient`, `ContextResolver`, `OutputRouter` (all by protocol/abstract dependency).

- [ ] **Step 1: Write the failing test (Tests/PersonaEngineTests.swift)**

```swift
import Foundation

@main
struct PersonaEngineTestRunner {
    static func main() {
        Task {
            await runAll()
            print("PersonaEngineTests passed")
            exit(0)
        }
        RunLoop.main.run()
    }

    static func runAll() async {
        // 1. .bypassed(.emptyInput) when all fragments empty.
        let (engine1, _) = makeEngine(llmReady: true)
        let p = persona(.none)
        let inv1 = Invocation(persona: p, fragments: [], originAppBundleID: nil, outputOverride: nil)
        let r1 = try! await engine1.run(inv1)
        if case .bypassed(.emptyInput) = r1 {} else { fail("emptyInput expected, got \(r1)") }

        // 2. .bypassed(.llmNotConfigured) when LLM not ready.
        let (engine2, spy2) = makeEngine(llmReady: false)
        let inv2 = Invocation(
            persona: p,
            fragments: [TextFragment(source: .voice, text: "hi", meta: [:])],
            originAppBundleID: nil,
            outputOverride: nil
        )
        let r2 = try! await engine2.run(inv2)
        if case .bypassed(.llmNotConfigured) = r2 {} else { fail("llmNotConfigured expected") }
        // LLM should NOT have been called.
        expect(spy2.completeCalls == 0, "LLM not called when not ready")
        // Router should NOT have been called.
        expect(spy2.dispatchCalls.isEmpty, "Router not called when LLM not ready")

        // 3. .injected happy path: voice → LLM → focusedText.
        let (engine3, spy3) = makeEngine(llmReady: true, llmResponse: "refined")
        let inv3 = Invocation(
            persona: persona(.none, output: .replaceFocusedText),
            fragments: [TextFragment(source: .voice, text: "raw voice", meta: [:])],
            originAppBundleID: "com.example.foo",
            outputOverride: nil
        )
        let r3 = try! await engine3.run(inv3)
        if case .injected(let text, let via) = r3 {
            expect(text == "refined", ".injected returns refined text")
            expect(via == .replaceFocusedText, ".injected returns strategy")
        } else { fail("injected expected, got \(r3)") }
        expect(spy3.completeCalls == 1, "LLM called once")
        expect(spy3.dispatchCalls.count == 1, "Router called once")
        expect(spy3.dispatchCalls[0].text == "refined", "Router got refined text")
        expect(spy3.dispatchCalls[0].origin == "com.example.foo", "Router got origin")

        // 4. .outputOverride wins over persona.outputStrategy.
        let (engine4, spy4) = makeEngine(llmReady: true, llmResponse: "x")
        let inv4 = Invocation(
            persona: persona(.none, output: .replaceFocusedText),
            fragments: [TextFragment(source: .userTyped, text: "go", meta: [:])],
            originAppBundleID: nil,
            outputOverride: .clipboard
        )
        let r4 = try! await engine4.run(inv4)
        if case .injected(_, let via) = r4 {
            expect(via == .clipboard, "outputOverride wins (got .clipboard)")
        } else { fail("injected expected") }
        expect(spy4.dispatchCalls[0].strategy == .clipboard, "Router got override strategy")

        // 5. Prompt assembly: source-tagged section headers in order.
        let (engine5, spy5) = makeEngine(llmReady: true, llmResponse: "ok")
        let inv5 = Invocation(
            persona: persona(.none, output: .replaceFocusedText),
            fragments: [
                TextFragment(source: .selectedText, text: "S", meta: [:]),
                TextFragment(source: .clipboardItem, text: "C", meta: [:]),
                TextFragment(source: .voice, text: "V", meta: [:]),
            ],
            originAppBundleID: nil,
            outputOverride: nil
        )
        _ = try! await engine5.run(inv5)
        let userText = spy5.completeCalls > 0 ? spy5.lastUserText : ""
        expect(userText.contains("[Selected text]\nS"), "user message has [Selected text]")
        expect(userText.contains("[Recent clipboard]\nC"), "user message has [Recent clipboard]")
        expect(userText.contains("[User said]\nV"), "user message has [User said]")

        // 6. LLM throws → engine rethrows .llmFailed.
        let (engine6, _) = makeEngine(llmReady: true, llmError: NSError(domain: "x", code: 1))
        let inv6 = Invocation(
            persona: persona(.none, output: .replaceFocusedText),
            fragments: [TextFragment(source: .voice, text: "v", meta: [:])],
            originAppBundleID: nil,
            outputOverride: nil
        )
        do {
            _ = try await engine6.run(inv6)
            fail(".llmFailed expected")
        } catch InvocationError.llmFailed(_) {
            // ok
        } catch {
            fail("expected .llmFailed, got \(error)")
        }
    }

    // MARK: helpers

    static func makeEngine(
        llmReady: Bool,
        llmResponse: String = "",
        llmError: Error? = nil
    ) -> (PersonaEngine, EngineSpy) {
        let spy = EngineSpy()
        spy.llmReady = llmReady
        spy.llmResponse = llmResponse
        spy.llmError = llmError
        return (
            PersonaEngine(
                llmClient: spy,
                contextResolver: ContextResolver(
                    selection: NilSource(.selectedText),
                    clipboard: NilSource(.clipboardItem),
                    clipboardHistory: NilHistory(),
                    windowOCR: NilSource(.ocrWindow)
                ),
                outputRouter: SpyRouter(spy: spy)
            ),
            spy
        )
    }

    static func persona(_ mode: ContextMode, output: OutputStrategy = .replaceFocusedText) -> Persona {
        Persona(
            id: "p", name: "p", icon: "x", stylePrompt: "sys",
            temperature: 0.0, hotkey: nil,
            contextMode: mode, contextCount: 1,
            outputStrategy: output,
            builtIn: false,
            createdAt: Date(), updatedAt: Date()
        )
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("FAIL: \(msg)"); exit(1) }
    }

    static func fail(_ msg: String) -> Never {
        print("FAIL: \(msg)"); exit(1)
    }
}

final class EngineSpy: LLMClient {
    var llmReady = true
    var llmResponse = ""
    var llmError: Error?
    var completeCalls = 0
    var lastSystemPrompt = ""
    var lastUserText = ""
    var lastTemperature: Double = 0

    var dispatchCalls: [(strategy: OutputStrategy, text: String, origin: String?)] = []

    var isReady: Bool { llmReady }
    func complete(systemPrompt: String, userText: String, temperature: Double) async throws -> String {
        completeCalls += 1
        lastSystemPrompt = systemPrompt
        lastUserText = userText
        lastTemperature = temperature
        if let e = llmError { throw e }
        return llmResponse
    }
    func cancel() {}
}

final class SpyRouter: OutputRouter {
    private let spy: EngineSpy
    init(spy: EngineSpy) {
        self.spy = spy
        super.init(
            focusedText: NoopHandler(),
            replaceSelection: NoopHandler(),
            clipboard: NoopHandler(),
            openURLFactory: { _ in NoopHandler() }
        )
    }
    override func dispatch(_ strategy: OutputStrategy,
                           text: String, origin: String?,
                           options: StrategyOptions = .defaults) async throws {
        spy.dispatchCalls.append((strategy, text, origin))
    }
}

final class NoopHandler: OutputStrategyHandler {
    func dispatch(text: String, origin: String?, options: StrategyOptions) async throws {}
}

final class NilSource: ContextSource {
    let providedKind: TextSource
    init(_ k: TextSource) { providedKind = k }
    func read() async throws -> TextFragment? { nil }
}
final class NilHistory: ClipboardHistorySourceProtocol {
    func read(count: Int) async throws -> [TextFragment] { [] }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Compile attempt: `make test-persona-engine` (after adding the rule below) — expected to fail because `PersonaEngine.swift` doesn't exist yet and `SpyRouter` subclasses a not-yet-`open` `OutputRouter`.

- [ ] **Step 3: Make OutputRouter inheritable for testing**

In `Sources/KeyMic/PersonaPlatform/Output/OutputRouter.swift`, change:

```swift
final class OutputRouter {
```

to:

```swift
class OutputRouter {
```

And mark `init` and `dispatch` as `open` (or just non-`final`):

```swift
    init(focusedText: OutputStrategyHandler,
         replaceSelection: OutputStrategyHandler,
         clipboard: OutputStrategyHandler,
         openURLFactory: @escaping (String) -> OutputStrategyHandler)

    func dispatch(_ strategy: OutputStrategy, ...) async throws
```

Both already are; just remove `final` from the class.

- [ ] **Step 4: Write Sources/KeyMic/PersonaPlatform/Engine/PersonaEngine.swift**

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "PersonaEngine")

final class PersonaEngine {
    private let llmClient: LLMClient
    private let contextResolver: ContextResolver
    private let outputRouter: OutputRouter

    enum Progress {
        case resolvingContext
        case callingLLM
        case dispatchingOutput(OutputStrategy)
    }

    init(llmClient: LLMClient,
         contextResolver: ContextResolver,
         outputRouter: OutputRouter) {
        self.llmClient = llmClient
        self.contextResolver = contextResolver
        self.outputRouter = outputRouter
    }

    @discardableResult
    func run(_ invocation: Invocation,
             progress: ((Progress) -> Void)? = nil) async throws -> InvocationResult {
        // 1. Validate: at least one non-whitespace fragment.
        let nonEmpty = invocation.fragments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard nonEmpty else { return .bypassed(reason: .emptyInput) }

        // 2. Resolve context.
        progress?(.resolvingContext)
        try Task.checkCancellation()
        let allFragments = await contextResolver.resolve(persona: invocation.persona,
                                                          prefilled: invocation.fragments)

        // 3. Build prompt.
        try Task.checkCancellation()
        let userText = Self.buildUserText(from: allFragments)

        // 4. Call LLM. Check readiness first (no progress emit on bypass).
        guard llmClient.isReady else { return .bypassed(reason: .llmNotConfigured) }
        progress?(.callingLLM)
        try Task.checkCancellation()
        let refined: String
        do {
            refined = try await llmClient.complete(
                systemPrompt: invocation.persona.stylePrompt,
                userText: userText,
                temperature: invocation.persona.temperature
            )
        } catch is CancellationError {
            throw InvocationError.cancelled
        } catch {
            throw InvocationError.llmFailed(underlying: error)
        }

        // 5. Dispatch output.
        let strategy = invocation.outputOverride ?? invocation.persona.outputStrategy
        progress?(.dispatchingOutput(strategy))
        try Task.checkCancellation()
        do {
            try await outputRouter.dispatch(strategy, text: refined, origin: invocation.originAppBundleID)
        } catch {
            throw InvocationError.outputFailed(strategy: strategy, underlying: error)
        }
        return .injected(text: refined, via: strategy)
    }

    /// Build the user message by joining `[Header]\n<text>` sections in fragment order.
    /// Caps at 7500 UTF-16 units, snapped to character boundary (preserves surrogate pairs).
    static func buildUserText(from fragments: [TextFragment]) -> String {
        let sections: [String] = fragments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { frag in
                let header = headerFor(frag)
                return "\(header)\n\(frag.text)"
            }
        let joined = sections.joined(separator: "\n\n")
        if joined.utf16.count <= 7500 { return joined }
        var trimmed = ""
        for ch in joined {
            if trimmed.utf16.count + ch.utf16.count > 7500 { break }
            trimmed.append(ch)
        }
        return trimmed
    }

    private static func headerFor(_ frag: TextFragment) -> String {
        switch frag.source {
        case .voice: return "[User said]"
        case .selectedText: return "[Selected text]"
        case .clipboardItem:
            if let idx = frag.meta["index"], idx != "0" {
                return "[Clipboard #\(idx)]"
            }
            return "[Recent clipboard]"
        case .userTyped, .phoneInput: return "[Instruction]"
        case .ocrWindow: return "[Visible window text]"
        }
    }
}
```

The `.bypassed(.shellConfirmDenied)` case (declared in `BypassReason`) is currently unreachable in P1 — no shipped strategy throws a "denied" signal. The P3 plan that lands `.runShell`/`.iTermPane` will introduce the denial mechanism (likely a dedicated error type the engine catches before the generic `InvocationError.outputFailed` mapping). The enum case is kept now per spec §5 to avoid migrating the enum in a later plan.

- [ ] **Step 5: Add the Makefile rule**

```make
test-persona-engine:
	mkdir -p .build
	swiftc Sources/KeyMic/PersonaPlatform/Engine/Invocation.swift \
	       Sources/KeyMic/PersonaPlatform/Engine/PersonaEngine.swift \
	       Sources/KeyMic/PersonaPlatform/Engine/LLMClient.swift \
	       Sources/KeyMic/PersonaPlatform/Persona/Persona.swift \
	       Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ContextResolver.swift \
	       Sources/KeyMic/PersonaPlatform/Context/ClipboardHistorySource.swift \
	       Sources/KeyMic/PersonaPlatform/Output/FocusedTextStrategy.swift \
	       Sources/KeyMic/PersonaPlatform/Output/ReplaceSelectionStrategy.swift \
	       Sources/KeyMic/PersonaPlatform/Output/ClipboardStrategy.swift \
	       Sources/KeyMic/PersonaPlatform/Output/OpenURLStrategy.swift \
	       Sources/KeyMic/PersonaPlatform/Output/OutputRouter.swift \
	       Sources/KeyMic/Clipboard/ClipboardStore.swift \
	       Tests/PersonaEngineTests.swift \
	       -o .build/persona-engine-tests
	.build/persona-engine-tests
```

Append `test-persona-engine` to `test-all`.

- [ ] **Step 6: Run the test**

Run: `make test-persona-engine`
Expected: `PersonaEngineTests passed`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Engine/PersonaEngine.swift \
        Sources/KeyMic/PersonaPlatform/Output/OutputRouter.swift \
        Tests/PersonaEngineTests.swift \
        Makefile
git commit -m "feat(persona): add PersonaEngine 5-step pipeline"
```

---

### Task 13: SpeechSessionHost

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Triggers/SpeechSessionHost.swift`

Serializes the single `SpeechEngine` across triggers (VoiceTrigger, ClipboardTransformTrigger, future R4 panel). Holds a weak reference to the current `SpeechClient`. Future triggers (P2 ClipboardTransformTrigger) can acquire; this plan only ships `VoiceTrigger`.

No standalone test runner — exercised indirectly via the running app and Task 14's tests if applicable.

- [ ] **Step 1: Write Sources/KeyMic/PersonaPlatform/Triggers/SpeechSessionHost.swift**

```swift
import Foundation

protocol SpeechClient: AnyObject {
    func handlePartial(_ text: String)
    func handleFinal(_ text: String)
    func handleError(_ msg: String)
    func handleAudioLevel(_ level: Float)
}

protocol SpeechSessionHost: AnyObject {
    /// Acquire an exclusive recording session. Throws `.busy` when another
    /// client already holds the session. Returned `SpeechSession.release()`
    /// returns control to the host.
    func acquire(client: SpeechClient) throws -> SpeechSession
}

enum SpeechSessionError: Error {
    case busy
}

final class SpeechSession {
    fileprivate weak var host: DefaultSpeechSessionHost?
    fileprivate weak var client: SpeechClient?

    fileprivate init(host: DefaultSpeechSessionHost, client: SpeechClient) {
        self.host = host
        self.client = client
    }

    func start() { host?.engineStart() }
    func stop()  { host?.engineStop() }
    func cancel(){ host?.engineCancel() }

    func release() { host?.release(self) }
}

final class DefaultSpeechSessionHost: SpeechSessionHost {
    private let speechEngine: SpeechEngine
    private weak var currentClient: SpeechClient?
    private weak var currentSession: SpeechSession?

    init(speechEngine: SpeechEngine) {
        self.speechEngine = speechEngine
    }

    func acquire(client: SpeechClient) throws -> SpeechSession {
        if currentClient != nil, currentClient !== client {
            throw SpeechSessionError.busy
        }
        let session = SpeechSession(host: self, client: client)
        currentClient = client
        currentSession = session
        return session
    }

    fileprivate func engineStart()  { speechEngine.startRecording() }
    fileprivate func engineStop()   { speechEngine.stopRecording() }
    fileprivate func engineCancel() { speechEngine.cancel() }

    fileprivate func release(_ session: SpeechSession) {
        guard session === currentSession else { return }
        currentClient = nil
        currentSession = nil
    }

    // Routing — called from AppDelegate's SpeechEngine callbacks.
    func routePartial(_ text: String)    { currentClient?.handlePartial(text) }
    func routeFinal(_ text: String)      { currentClient?.handleFinal(text) }
    func routeError(_ msg: String)       { currentClient?.handleError(msg) }
    func routeAudioLevel(_ level: Float) { currentClient?.handleAudioLevel(level) }
}
```

- [ ] **Step 2: Run the build**

Run: `make build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Triggers/SpeechSessionHost.swift
git commit -m "feat(persona): add SpeechSessionHost for serialized SpeechEngine sharing"
```

---

### Task 14: VoiceTrigger

**Files:**
- Create: `Sources/KeyMic/PersonaPlatform/Triggers/VoiceTrigger.swift`

Replaces the inline voice flow from `AppDelegate`. Wires speech partial/final → engine.run → output. Falls back to `textInjector.inject(transcript)` on `.bypassed(.llmNotConfigured)`, `InvocationError.llmFailed`, or no active persona.

This task ships the trigger; Task 15 wires it into `AppDelegate` (deleting the inline path).

- [ ] **Step 1: Write Sources/KeyMic/PersonaPlatform/Triggers/VoiceTrigger.swift**

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "VoiceTrigger")

@MainActor
final class VoiceTrigger: SpeechClient {
    private let engine: PersonaEngine
    private let sessionHost: SpeechSessionHost
    private let overlayPanel: OverlayPanel
    private let personaStore: PersonaStore
    private let textInjector: TextInjector
    private let currentFrontBundleID: () -> String?

    private var session: SpeechSession?
    private var isRecording = false
    private var lastPartial = ""
    private var finalResultTimer: Timer?
    private var runTask: Task<Void, Never>?
    private var originBundleID: String?

    init(engine: PersonaEngine,
         sessionHost: SpeechSessionHost,
         overlayPanel: OverlayPanel,
         personaStore: PersonaStore,
         textInjector: TextInjector,
         currentFrontBundleID: @escaping () -> String?) {
        self.engine = engine
        self.sessionHost = sessionHost
        self.overlayPanel = overlayPanel
        self.personaStore = personaStore
        self.textInjector = textInjector
        self.currentFrontBundleID = currentFrontBundleID
    }

    func onTriggerDown() {
        guard !isRecording else { return }
        do {
            session = try sessionHost.acquire(client: self)
        } catch {
            logger.info("Speech session busy; ignoring trigger down")
            return
        }
        originBundleID = currentFrontBundleID()
        lastPartial = ""
        isRecording = true
        overlayPanel.show(text: "Listening...")
        NSSound(named: .init("Tink"))?.play()
        session?.start()
    }

    func onTriggerUp() {
        guard isRecording else { return }
        isRecording = false
        session?.stop()
        finalResultTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    func onTriggerInterrupted() {
        guard isRecording else { return }
        isRecording = false
        finalResultTimer?.invalidate(); finalResultTimer = nil
        lastPartial = ""
        session?.cancel()
        session?.release()
        session = nil
        overlayPanel.dismiss()
    }

    // MARK: SpeechClient

    func handlePartial(_ text: String) {
        lastPartial = text
        overlayPanel.updateText(text)
    }

    func handleFinal(_ text: String) {
        lastPartial = text
        finalResultTimer?.invalidate(); finalResultTimer = nil
        finish()
    }

    func handleError(_ msg: String) {
        overlayPanel.updateText(msg)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.overlayPanel.dismiss()
            self.releaseSession()
        }
    }

    func handleAudioLevel(_ level: Float) {
        overlayPanel.updateAudioLevel(level)
    }

    // MARK: finish

    private func finish() {
        finalResultTimer?.invalidate(); finalResultTimer = nil
        let transcript = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            overlayPanel.dismiss()
            releaseSession()
            lastPartial = ""
            return
        }

        // Passthrough when no active persona.
        guard let persona = personaStore.activePersona else {
            overlayPanel.dismiss()
            injectAfterPop(transcript)
            releaseSession()
            lastPartial = ""
            return
        }

        let invocation = Invocation(
            persona: persona,
            fragments: [TextFragment(source: .voice, text: transcript, meta: [:])],
            originAppBundleID: originBundleID,
            outputOverride: nil
        )

        overlayPanel.showRefining()
        runTask = Task { [weak self] in
            guard let self else { return }
            defer { self.releaseSession() }
            do {
                let result = try await self.engine.run(invocation)
                switch result {
                case .injected:
                    await MainActor.run { self.overlayPanel.dismiss() }
                case .bypassed(.llmNotConfigured):
                    await MainActor.run {
                        self.overlayPanel.dismiss()
                        self.injectAfterPop(transcript)
                    }
                case .bypassed:
                    await MainActor.run { self.overlayPanel.dismiss() }
                }
            } catch InvocationError.cancelled {
                await MainActor.run { self.overlayPanel.dismiss() }
            } catch {
                logger.error("Persona run failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.overlayPanel.showMessage(String(localized: "Refine failed: \(error.localizedDescription)"))
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    self.overlayPanel.dismiss()
                    self.injectAfterPop(transcript)
                }
            }
            await MainActor.run { self.lastPartial = "" }
        }
    }

    private func injectAfterPop(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.textInjector.inject(text)
            NSSound(named: .init("Pop"))?.play()
        }
    }

    private func releaseSession() {
        session?.release()
        session = nil
    }
}
```

- [ ] **Step 2: Run the build**

Run: `make build`
Expected: build succeeds. (`AppDelegate` still uses the old inline path; nothing references `VoiceTrigger` yet.)

- [ ] **Step 3: Commit**

```bash
git add Sources/KeyMic/PersonaPlatform/Triggers/VoiceTrigger.swift
git commit -m "feat(persona): add VoiceTrigger replacing inline AppDelegate voice path"
```

---

### Task 15: Wire PersonaPlatform into AppDelegate and delete inline voice path + LLMRefiner

**Files:**
- Modify: `Sources/KeyMic/AppDelegate.swift`
- Delete: `Sources/KeyMic/LLMRefiner.swift`

Restructure `AppDelegate` per spec §10. Build the PersonaPlatform graph in `applicationDidFinishLaunching`. Replace `keyMonitor.onTriggerDown/Up/Interrupted` callbacks with calls into `voiceTrigger`. Forward `SpeechEngine` callbacks through `speechSessionHost.routePartial/Final/Error/AudioLevel`. Remove `triggerDown`, `triggerUp`, `cancelRecording`, `finishTranscription`, `buildUserText`, `injectAfterPop`, `setupSpeechCallbacks`.

- [ ] **Step 1: Add new fields to AppDelegate**

In `Sources/KeyMic/AppDelegate.swift`, add to the property block (around line 30):

```swift
private var personaEngine: PersonaEngine!
private var voiceTrigger: VoiceTrigger!
private var speechSessionHost: DefaultSpeechSessionHost!
private var llmClient: OpenAICompatibleLLMClient!
```

Remove these properties (they're driven by `VoiceTrigger` now):

```swift
private var isRecording = false
private var lastPartialResult = ""
private var finalResultTimer: Timer?
```

- [ ] **Step 2: Construct the platform in applicationDidFinishLaunching**

In `applicationDidFinishLaunching`, after `clipboardController = ClipboardController()` and `clipboardController.start()` (or wherever `clipboardController` becomes available — be careful with the ordering of lifecycle steps, look at the current file before placing), add:

```swift
// PersonaPlatform construction
llmClient = OpenAICompatibleLLMClient()
let contextResolver = ContextResolver(
    selection: SelectionSource(),
    clipboard: ClipboardSource(store: clipboardController.store),
    clipboardHistory: ClipboardHistorySource(store: clipboardController.store),
    windowOCR: WindowOCRSource()
)
let focusedText = FocusedTextStrategy(textInjector: textInjector)
let outputRouter = OutputRouter(
    focusedText: focusedText,
    replaceSelection: ReplaceSelectionStrategy(fallback: focusedText),
    clipboard: ClipboardStrategy(controller: clipboardController),
    openURLFactory: { template in OpenURLStrategy(template: template) }
)
personaEngine = PersonaEngine(
    llmClient: llmClient,
    contextResolver: contextResolver,
    outputRouter: outputRouter
)
speechSessionHost = DefaultSpeechSessionHost(speechEngine: speechEngine)
voiceTrigger = VoiceTrigger(
    engine: personaEngine,
    sessionHost: speechSessionHost,
    overlayPanel: overlayPanel,
    personaStore: PersonaStore.shared,
    textInjector: textInjector,
    currentFrontBundleID: { [weak self] in self?.cachedFrontBundleID }
)
```

If `clipboardController` does not expose its `store` publicly today, expose it (in `Sources/KeyMic/Clipboard/ClipboardController.swift`, change `private let store` to `let store` — or add a `var store: ClipboardStore { ... }` getter).

- [ ] **Step 3: Replace KeyMonitor callbacks**

Replace these three lines in `applicationDidFinishLaunching`:

```swift
keyMonitor.onTriggerDown = { [weak self] in self?.triggerDown() }
keyMonitor.onTriggerUp = { [weak self] in self?.triggerUp() }
keyMonitor.onTriggerInterrupted = { [weak self] in self?.cancelRecording() }
```

with:

```swift
keyMonitor.onTriggerDown = { [weak self] in
    guard let self, self.isVoiceEnabled else { return }
    Task { @MainActor in self.voiceTrigger.onTriggerDown() }
}
keyMonitor.onTriggerUp = { [weak self] in
    Task { @MainActor in self?.voiceTrigger.onTriggerUp() }
}
keyMonitor.onTriggerInterrupted = { [weak self] in
    Task { @MainActor in self?.voiceTrigger.onTriggerInterrupted() }
}
```

- [ ] **Step 4: Route SpeechEngine callbacks through the session host**

Replace `setupSpeechCallbacks()` body (and call site) with direct assignment to the host's routers. Delete `setupSpeechCallbacks()`. In `applicationDidFinishLaunching`, after constructing `speechSessionHost`, add:

```swift
speechEngine.onPartialResult   = { [weak self] t in self?.speechSessionHost.routePartial(t) }
speechEngine.onFinalResult     = { [weak self] t in self?.speechSessionHost.routeFinal(t) }
speechEngine.onError           = { [weak self] m in self?.speechSessionHost.routeError(m) }
speechEngine.onAudioLevel      = { [weak self] l in self?.speechSessionHost.routeAudioLevel(l) }
speechEngine.onLocaleUnavailable = { [weak self] msg in
    self?.showAlert(title: String(localized: "Language Unavailable"), message: msg)
}
```

- [ ] **Step 5: Delete the inline voice path methods**

Delete these methods from `Sources/KeyMic/AppDelegate.swift` (find by name):

- `private func triggerDown()`
- `private func triggerUp()`
- `private func cancelRecording()`
- `private func setupSpeechCallbacks()`
- `private func finishTranscription()`
- `private func buildUserText(...)`
- `private func injectAfterPop(_ text:)`

Also delete the line `setupSpeechCallbacks()` from `applicationDidFinishLaunching`.

Delete the import of `Speech` if no other code in `AppDelegate.swift` references SpeechRecognizer types (`SFSpeechRecognizer` is referenced in `defaultSpeechLocaleCode` — keep the import).

- [ ] **Step 6: Delete LLMRefiner.swift**

```bash
git rm Sources/KeyMic/LLMRefiner.swift
grep -rn "LLMRefiner" Sources/ Tests/
```

Expected: no remaining references. If any test or non-AppDelegate source still references `LLMRefiner.shared`, switch it to use the new `LLMClient` (likely none — `LLMRefiner.shared` was only consumed by `AppDelegate`).

- [ ] **Step 7: Build**

Run: `make build`
Expected: build succeeds.

- [ ] **Step 8: Run the full test suite**

Run: `make test-all`
Expected: every test prints `… passed` and the final line is `✅ All tests passed`.

- [ ] **Step 9: Manual smoke test**

Run: `make run`

In another app:
1. Verify the menu-bar icon appears.
2. Hold the voice trigger key (`Fn` or `Right Option` per settings), say one short phrase, release.
3. Confirm the transcript is injected via Cmd+V into the focused field.
4. Toggle on a built-in persona (e.g. "Context") from the menu bar; configure LLM API key in Settings.
5. With selection in a text field, hold the voice trigger, dictate; verify the LLM-refined text is injected.
6. Without LLM configured, verify passthrough still works (raw transcript injected).

If anything misbehaves, do NOT mark this step complete — investigate, fix in code, and re-run. A green test suite is necessary but not sufficient.

- [ ] **Step 10: Commit**

```bash
git add Sources/KeyMic/AppDelegate.swift \
        Sources/KeyMic/Clipboard/ClipboardController.swift \
        Sources/KeyMic/LLMRefiner.swift
git commit -m "refactor(appdelegate): wire PersonaEngine and VoiceTrigger; delete inline voice path"
```

---

### Task 16: Final cleanup + verify P1 module is complete

**Files:**
- Modify: `Makefile` — confirm `test-all` includes every new rule.
- (Optional) Add a top-level `README.md` under `Sources/KeyMic/PersonaPlatform/` describing module boundary for future contributors. Skip unless explicitly requested.

This task does not add new files. It re-verifies that the module is internally consistent and that no stale references remain.

- [ ] **Step 1: Verify no stale references to the old structure**

```bash
grep -rn "Sources/KeyMic/LLM/\|LLMRefiner\|SelectionTextProvider" Sources/ Tests/ Makefile
```

Expected: no matches.

- [ ] **Step 2: Verify all new test rules are in test-all**

```bash
grep "^test-all:" Makefile
```

Expected output line contains: `test-invocation test-llm-client test-selection-source test-context-resolver test-output-router test-persona-engine` (in addition to the pre-existing rules).

- [ ] **Step 3: Verify clean build from scratch**

```bash
make clean
make build
```

Expected: clean build succeeds; produces `KeyMic.app`.

- [ ] **Step 4: Run the full test suite again**

```bash
make test-all
```

Expected: `✅ All tests passed`.

- [ ] **Step 5: Verify the produced binary still launches and behaves correctly**

```bash
make run
```

Repeat the smoke test from Task 15 Step 9.

- [ ] **Step 6: Update CLAUDE.md if module layout descriptions are now stale**

Look at the "Architecture" / "Voice path" section of `CLAUDE.md` (root of repo). The current text describes the inline voice path in `AppDelegate.finishTranscription`. Update it to describe the new flow:

```
- Voice path: `KeyMonitor.onTriggerDown/Up` → `VoiceTrigger` (in `PersonaPlatform/Triggers/`)
  → `PersonaEngine.run(Invocation)` → `LLMClient.complete` → `OutputRouter.dispatch` →
  `FocusedTextStrategy` (Cmd+V via `TextInjector`).
- `AppDelegate` constructs the platform graph in `applicationDidFinishLaunching` and routes
  `KeyMonitor`/`SpeechEngine` callbacks through `voiceTrigger` and `speechSessionHost`.
```

Replace any contradicting older descriptions (especially around `finishTranscription` and `LLMRefiner.shared`).

- [ ] **Step 7: Commit any final cleanup**

```bash
git add CLAUDE.md Makefile
git commit -m "docs(claude-md): describe new PersonaPlatform module wiring"
```

---

## What this plan does NOT ship (next plans)

- **R4 Selection Edit Trigger + floating panel** (LOR-16) — own plan covering panel UI design + chips + recording button + `SelectionEditTrigger` wiring + new `Edit` built-in persona.
- **R5 Clipboard Transform Trigger** (LOR-19) — own plan covering `ClipboardTransformTrigger` + new `⌥L` hotkey + new `ClipboardTransformer` built-in persona.
- **R2.3 Window OCR** (LOR-20) — own plan, replaces `WindowOCRSource` stub with real `ScreenCaptureKit` + `VNRecognizeTextRequest` impl.
- **R3 `.runShell` / `.iTermPane` strategies** — own plan with confirmation dialog UX, `ShellRunner` invocation, AppleScript to iTerm. Tied to R2.3 plan because users want OCR → CLI workflows.
- **R6 Phone Whisper Mode** (LOR-21) — own plan, large independent surface (TLS server, QR pairing, PIN, WebSocket).
- **R7 Agent / Skill spike** (LOR-22) — research plan first.
- **Settings UI for per-persona `outputStrategy` editing** — separate UI plan.
