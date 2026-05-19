# Voice + LLM Persona Platform — Decoupled Module Design

**Linear epic:** [LOR-23](https://linear.app/lorne/issue/LOR-23/epic-voice-llm-persona-platform)
**Date:** 2026-05-20
**Status:** Design approved, pending spec review

## 1. Background and goal

KeyMic's current voice pipeline (`hold trigger → record → transcribe → optional LLM refine → Cmd+V`) is implemented inline inside `AppDelegate` (777-line file). The Persona system seeded by LOR-14 has shipped (`Sources/KeyMic/LLM/Persona.swift`, `PersonaStore.swift`, `SelectionTextProvider.swift`, generalized `LLMRefiner`), but its consumer — `AppDelegate.finishTranscription` + `buildUserText` — still hardcodes:

- Single trigger (hold-to-record voice).
- Single context shape (`selection + clipboard` via inline `buildUserText`).
- Single output (`TextInjector.inject` → simulated `Cmd+V`).

The epic adds more **input modes** (selection-edit panel R4, clipboard transform R5, phone R6), more **context sources** (clipboard R2.2, OCR R2.3, selection R2.1), and more **output targets** (replaceSelection, clipboard, openURL, shell, iTerm — R3), plus a long-term Skill/Agent layer (R7). All of these need to plug into one abstraction, not bolt onto `AppDelegate`.

This document specifies a self-contained `PersonaPlatform` module inside the existing SwiftPM target that:

- Has a single entry point (`PersonaEngine.run(Invocation)`).
- Models input fragments with a source tag, not a hardcoded shape.
- Routes output through a `OutputRouter` registry.
- Lets every Trigger (voice / R4 / R5 / R6) build an `Invocation` and hand off.
- Leaves AppDelegate as a thin wiring host.

## 2. Scope

In scope (this design):

- New `Sources/KeyMic/PersonaPlatform/` module structure (single target, protocol-driven).
- Core types: `Invocation`, `TextFragment`, `TextSource`, `InvocationResult`, `InvocationError`.
- `Persona` migration: new `outputStrategy` + `contextCount` fields, extended `ContextMode`.
- `PersonaEngine` async run pipeline with `Progress` callback.
- `ContextResolver` + `ContextSource` protocol + 4 built-in sources (selection, clipboard, clipboard-history, window OCR — last one stubbed for P1).
- `OutputRouter` + 6 strategy handlers (replaceFocusedText, replaceSelection, clipboard, openURL, runShell, iTermPane — last three with confirmation gates).
- 4 Triggers (`VoiceTrigger`, `SelectionEditTrigger`, `ClipboardTransformTrigger`, `PhoneTrigger`).
- `SpeechSessionHost` to serialize the single `SpeechEngine` across triggers.
- `LLMClient` protocol replacing `LLMRefiner.shared`.
- AppDelegate restructure (~777 → ~450 lines).
- Test plan and Makefile additions.
- Phase mapping (P1–P5) onto Linear sub-tickets.

Out of scope:

- R4 panel UI details (chips, recording button placement, preview truncation). The Trigger contract is fixed here; the panel is its own spec.
- R7 Skill internal data model. Only the *boundary* is reserved (a `Skill/` subfolder and a `SkillRunner` placeholder).
- Multi-instance `SpeechEngine` (deferred until the single-session model proves insufficient in R4/R5 use).

## 3. Decisions made during brainstorming

1. **Module boundary**: directory + protocol decoupling inside the existing KeyMic SwiftPM target. Not a separate `PersonaCore` library. (Future library extraction kept on the table by aligning protocol shapes accordingly.)
2. **Output strategy lives on Persona**: each `Persona` carries one `outputStrategy`. No dynamic per-invocation routing. (Triggers may still pass `outputOverride` for special cases like R4 forcing `.replaceSelection`.)
3. **All inputs are text with a source tag**: a single `TextFragment { source, text, meta }` model replaces ad-hoc string concatenation. Sources: `voice`, `selectedText`, `clipboardItem`, `userTyped`, `phoneInput`, `ocrWindow`.
4. **Module shape**: synchronous pipeline using `async/await`, single entry point `PersonaEngine.run(Invocation) async throws -> InvocationResult`. Not NotificationCenter event bus, not Combine.

## 4. Module layout

```
Sources/KeyMic/PersonaPlatform/
  Engine/
    PersonaEngine.swift         ← run() pipeline + nested enum Progress
    Invocation.swift            ← Invocation + InvocationResult + BypassReason
                                  + InvocationError + TextFragment + TextSource
    LLMClient.swift             ← protocol + OpenAICompatibleLLMClient
                                  (absorbs current LLMRefiner)
  Persona/
    Persona.swift               ← moved from LLM/, extended (see §5)
    PersonaStore.swift          ← moved from LLM/, v1→v2 migration
  Context/
    ContextResolver.swift       ← protocol + default impl
    SelectionSource.swift       ← absorbs LLM/SelectionTextProvider
                                  + adds replaceSelection(with:) (LOR-17)
    ClipboardSource.swift       ← latest item
    ClipboardHistorySource.swift ← N most recent
    WindowOCRSource.swift       ← P3; stub returning nil for P1-P2
  Output/
    OutputRouter.swift          ← protocol + registry + dispatch
    FocusedTextStrategy.swift   ← wraps existing TextInjector
    ReplaceSelectionStrategy.swift
    ClipboardStrategy.swift
    OpenURLStrategy.swift       ← {query} template + percent-encoding
    ShellStrategy.swift         ← confirm gate; uses ShellRunner.shared
    ITermStrategy.swift         ← confirm gate; AppleScript to iTerm
  Triggers/
    VoiceTrigger.swift          ← replaces AppDelegate.triggerDown/Up/finish
    SelectionEditTrigger.swift  ← R4
    ClipboardTransformTrigger.swift ← R5
    PhoneTrigger.swift          ← R6 (P4)
    SpeechSessionHost.swift     ← serializes single SpeechEngine across triggers
  Skill/                         ← R7 placeholder (empty stub + README) for P5
    SkillRunner.swift           ← future
```

**Deleted/moved from existing tree:**

- `Sources/KeyMic/LLM/Persona.swift` → `Sources/KeyMic/PersonaPlatform/Persona/Persona.swift`
- `Sources/KeyMic/LLM/PersonaStore.swift` → `Sources/KeyMic/PersonaPlatform/Persona/PersonaStore.swift`
- `Sources/KeyMic/LLM/SelectionTextProvider.swift` → folded into `Sources/KeyMic/PersonaPlatform/Context/SelectionSource.swift`
- `Sources/KeyMic/LLMRefiner.swift` → logic moved into `Sources/KeyMic/PersonaPlatform/Engine/LLMClient.swift` (`OpenAICompatibleLLMClient`); `LLMRefiner.shared` singleton removed.
- `Sources/KeyMic/LLM/` directory deleted after the move.

## 5. Core types

```swift
// Engine/Invocation.swift

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
    let meta: [String: String]   // e.g. clipboardItem may carry "index": "0"
}

/// One Persona invocation. Triggers construct, Engine consumes.
struct Invocation {
    let persona: Persona
    let fragments: [TextFragment]      // pre-filled by Trigger; Resolver may add more
    let originAppBundleID: String?     // for reactivate-before-inject
    let outputOverride: OutputStrategy? // nil = use persona.outputStrategy
}

enum InvocationResult {
    case injected(text: String, via: OutputStrategy)
    case bypassed(reason: BypassReason)
}

enum BypassReason {
    case llmNotConfigured       // Engine: LLMClient.isReady == false
    case emptyInput             // Engine: all fragments empty / whitespace
    case shellConfirmDenied     // OutputRouter: user denied .runShell/.iTermPane confirm dialog
}

enum InvocationError: Error {
    case llmFailed(underlying: Error)
    case contextResolveFailed(source: TextSource, underlying: Error)
    case outputFailed(strategy: OutputStrategy, underlying: Error)
    case cancelled
}
```

```swift
// Persona/Persona.swift (additions)

enum ContextMode: String, Codable, CaseIterable {
    case none
    case selection
    case clipboard
    case clipboardHistory          // count comes from persona.contextCount
    case selectionAndClipboard     // existing
    case windowOCR                 // R2.3
}

enum OutputStrategy: Codable, Equatable {
    case replaceFocusedText        // default; existing TextInjector behavior
    case replaceSelection          // R4
    case clipboard                 // R5
    case openURL(template: String) // {query} placeholder, percent-encoded
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
    var contextCount: Int                // new; default 1
    var outputStrategy: OutputStrategy   // new; default .replaceFocusedText
    var builtIn: Bool
    var createdAt: Date
    var updatedAt: Date
}
```

`PersonaStore` migration: bump `Envelope.version` to 2. v1 decode path fills missing fields with defaults (`outputStrategy = .replaceFocusedText`, `contextCount = 1`) and re-saves. Built-in seed list is updated in the same release to include the new fields.

## 6. PersonaEngine

```swift
// Engine/PersonaEngine.swift

final class PersonaEngine {
    private let llmClient: LLMClient
    private let contextResolver: ContextResolver
    private let outputRouter: OutputRouter
    private let logger = Logger(subsystem: "io.keymic.app", category: "PersonaEngine")

    init(llmClient: LLMClient,
         contextResolver: ContextResolver,
         outputRouter: OutputRouter)

    enum Progress {
        case resolvingContext
        case callingLLM
        case dispatchingOutput(OutputStrategy)
    }

    /// Single entry. Callable from any thread; internal hops as needed.
    @discardableResult
    func run(_ invocation: Invocation,
             progress: ((Progress) -> Void)? = nil) async throws -> InvocationResult
}
```

**Pipeline (5 steps):**

1. **Validate.** `Invocation.persona` is non-optional, so "no active persona" is a Trigger-side filter (Trigger never constructs an `Invocation` without one — it falls back to passthrough directly). Engine validates: at least one non-empty fragment (whitespace-trimmed). If not, return `.bypassed(.emptyInput)`.
2. **Resolve context.** `progress(.resolvingContext)`. Hand `(persona, prefilled fragments)` to `ContextResolver.resolve(...)`. Resolver fills only what the persona's `contextMode` requires *and* the trigger didn't already prefill (trigger wins). Result: full `[TextFragment]`.
3. **Build prompt.** System message = `persona.stylePrompt`. User message = sections joined by `\n\n`. Section header is keyed off `TextSource` (see table below). Existing 7500 UTF-16 cap with character-boundary trim (logic moved from `AppDelegate.buildUserText`).
4. **Call LLM.** Check `llmClient.isReady` first; if false, return `.bypassed(.llmNotConfigured)` *without* calling complete. Otherwise `progress(.callingLLM)` and `llmClient.complete(system, user, persona.temperature)`. Network/parse failures → throw `InvocationError.llmFailed`. Trigger decides whether to fall back on either the bypass or the throw.
5. **Dispatch output.** `strategy = invocation.outputOverride ?? persona.outputStrategy`. `progress(.dispatchingOutput(strategy))`. `outputRouter.dispatch(strategy, text: refined, origin: invocation.originAppBundleID)`. Return `.injected(text:, via:)`.

**Source → section header mapping (step 3):**

| TextSource | Header |
|---|---|
| `.voice` | `[User said]` |
| `.selectedText` | `[Selected text]` |
| `.clipboardItem` | `[Recent clipboard]` (single) or `[Clipboard #N]` (with `meta["index"]`) |
| `.userTyped` | `[Instruction]` |
| `.phoneInput` | `[Instruction]` |
| `.ocrWindow` | `[Visible window text]` |

**Cancellation.** Each trigger holds the `Task` it spawned. `run()` calls `try Task.checkCancellation()` between steps 2/3/4/5. `LLMClient.cancel()` aborts the underlying `URLSession` task.

**Threading.** `run()` is not `@MainActor`. AX/Pasteboard reads inside sources hop to main as required. UI-touching output strategies marshal to main themselves.

## 7. ContextResolver

```swift
// Context/ContextResolver.swift

protocol ContextSource {
    var providedKind: TextSource { get }
    func read() async throws -> TextFragment?    // nil = nothing to provide
}

final class ContextResolver {
    init(selection: ContextSource,
         clipboard: ContextSource,
         clipboardHistory: ClipboardHistorySource,
         windowOCR: ContextSource)

    /// Fill gaps based on persona.contextMode. Existing fragments of the same
    /// source are kept (trigger wins).
    func resolve(persona: Persona,
                 prefilled: [TextFragment]) async -> [TextFragment]
}
```

**Resolve table:**

| `contextMode` | Action |
|---|---|
| `.none` | No-op |
| `.selection` | If no `.selectedText` fragment, call `selection.read()` |
| `.clipboard` | If no `.clipboardItem` fragment, call `clipboard.read()` (most recent) |
| `.clipboardHistory` | Call `clipboardHistory.read(count: persona.contextCount)` regardless |
| `.selectionAndClipboard` | Both `.selection` and `.clipboard` paths above |
| `.windowOCR` | If no `.ocrWindow` fragment, call `windowOCR.read()` |

**Built-in sources:**

- `SelectionSource` — wraps existing AX `kAXSelectedTextAttribute` read, plus a static `replaceSelection(with: String) throws` that uses AX set on the selected text attribute. Throws `SelectionWriteError.notSettable` for read-only elements (webviews, terminals). Satisfies LOR-17.
- `ClipboardSource` — reads `ClipboardStore.mostRecent()`, falls back to `NSPasteboard.general.string(forType: .string)`.
- `ClipboardHistorySource` — async `read(count:) -> [TextFragment]`, each fragment carries `meta["index"] = "<i>"`.
- `WindowOCRSource` — for P1/P2 returns `nil`. For P3 captures focused window via `ScreenCapturer` (shared with `Screenshot/`) and runs `VNRecognizeTextRequest`. Documented latency 100–500 ms.

## 8. OutputRouter

```swift
// Output/OutputRouter.swift

protocol OutputStrategyHandler {
    func dispatch(text: String,
                  origin: String?,
                  options: StrategyOptions) async throws
}

struct StrategyOptions {
    let reactivateOrigin: Bool   // default true for focused-text strategies
}

final class OutputRouter {
    init(focusedText: OutputStrategyHandler,
         replaceSelection: OutputStrategyHandler,
         clipboard: OutputStrategyHandler,
         openURL: OutputStrategyHandler,
         shell: OutputStrategyHandler,
         iTerm: OutputStrategyHandler)

    func dispatch(_ strategy: OutputStrategy,
                  text: String,
                  origin: String?) async throws
}
```

**Strategy implementations:**

| Strategy | Implementation | Fallback |
|---|---|---|
| `.replaceFocusedText` | Existing `TextInjector.inject` (Cmd+V + IME switch + clipboard restore) | None |
| `.replaceSelection` | `SelectionSource.replaceSelection(with:)` via AX | On `notSettable` → fall back to `.replaceFocusedText` |
| `.clipboard` | `NSPasteboard.setString` + `ClipboardController.markPasteboardWrite` so the monitor ignores the write | None |
| `.openURL(template)` | Replace `{query}` with `text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`, parse via `URL(string:)`, `NSWorkspace.shared.open`. Invalid template → throw `.outputFailed` | None |
| `.runShell(command, confirm)` | If `confirm`, present `NSAlert` showing the full command line and the text argument; on approval run via `ShellRunner.shared.run(command, args: [text])` (text is passed as `$1`, never string-interpolated into the command) | Denial → `.bypassed(.shellConfirmDenied)` |
| `.iTermPane(confirm)` | Confirm gate as above; on approval send AppleScript to iTerm's current session writing `text` | Denial → bypassed |

**Reactivate-before-inject:** `FocusedTextStrategy` and `ReplaceSelectionStrategy` reactivate `origin` (using `NSRunningApplication.activate`) before sending events. This consolidates logic currently scattered between `ClipboardController` and `TextInjector`.

**Shell safety hard rules:**

- `.runShell` and `.iTermPane` default to `confirm = true`. Code may not change the default.
- A Settings UI toggle to set `confirm = false` requires a second "I understand the risk" checkbox.
- Text is always passed as a positional argument, never composed into the command string.
- These strategies do not auto-create personas; built-in seeds never use them.

## 9. Triggers

Each trigger holds `PersonaEngine` plus its own input source and UI. AppDelegate constructs them and wires `KeyMonitor` callbacks.

### 9.1 VoiceTrigger (replaces inline voice path)

Drives: hold-to-record voice via `SpeechEngine`, partial UI via `OverlayPanel`, final → `PersonaEngine.run`.

```swift
final class VoiceTrigger: SpeechClient {
    init(engine: PersonaEngine,
         sessionHost: SpeechSessionHost,
         overlayPanel: OverlayPanel,
         personaStore: PersonaStore,
         textInjector: TextInjector,   // for passthrough on bypass/fail
         currentFrontBundleID: @escaping () -> String?)

    func onTriggerDown()
    func onTriggerUp()
    func onTriggerInterrupted()

    // SpeechClient
    func handlePartial(_ text: String)
    func handleFinal(_ text: String)
    func handleError(_ msg: String)
    func handleAudioLevel(_ level: Float)
}
```

Behavior:

- `onTriggerDown` acquires a `SpeechSession` from `SpeechSessionHost`, snapshots front bundle ID, shows overlay, starts recording.
- `onTriggerUp` stops recording and starts a 2 s grace timer (matches current behavior).
- Grace timer or `handleFinal` calls `finish()`:
  - If `personaStore.activePersona == nil`, skip engine: dismiss overlay, call `textInjector.inject(transcript)` directly.
  - Otherwise build `Invocation` with one `TextFragment(source: .voice, …)`, show "Refining…" overlay, call `engine.run`.
  - On `InvocationResult.bypassed(.llmNotConfigured)`: dismiss overlay, `textInjector.inject(transcript)` (passthrough).
  - On `InvocationResult.injected`: dismiss overlay (router already delivered).
  - On `InvocationError.llmFailed`: overlay shows "Refine failed: <msg>" 1.5 s, then dismiss + passthrough-inject the raw transcript.
  - On `InvocationError.cancelled`: silent dismiss.

### 9.2 SelectionEditTrigger (R4)

Hotkey (default `⌥E`) → read selection → present floating panel → user provides instruction (voice or typed or chip preset) → engine runs with persona = "Edit" (built-in, see §10) → output forced to `.replaceSelection`.

Panel UI is out of scope here; the Trigger contract is:

```swift
final class SelectionEditTrigger {
    func onHotkey() async   // reads selection, presents panel, awaits submit
}
```

Submit hands the Trigger `(instruction: String, source: TextSource)` where `source ∈ {.voice, .userTyped}`. Trigger builds `Invocation` with `[ .selectedText fragment, instruction fragment ]` and `outputOverride = .replaceSelection`.

If selection is empty: show a brief toast ("Select text first") and dismiss.

If AX write fails: panel surfaces the error; no fallback to focused-text (would replace whatever is under the cursor, not the original selection).

### 9.3 ClipboardTransformTrigger (R5)

Hotkey (default `⌥L`) is hold-to-record. Acquires `SpeechSession`. On release, builds `Invocation` with `[ .clipboardItem (most recent), .voice (transcript) ]`, persona = built-in `ClipboardTransformer`, output forced to `.clipboard`. After dispatch, both the original clipboard item and the transformed result are in `ClipboardStore` (the strategy writes the result; the store already has the original).

### 9.4 PhoneTrigger (R6, P4)

Lazily constructed when the user toggles "Whisper mode" in the menu bar. Owns a local TLS HTTPS server (`Network.framework`), serves a one-page form + a WebSocket endpoint, displays a QR code. On message:

- Build `Invocation` with `[ .phoneInput (text) ]`.
- Persona = user-configured "Phone persona" (defaults to the active persona).
- `originAppBundleID` = the front bundle ID cached when Whisper mode was toggled on.
- LLM failures are sent back over the WebSocket as a JSON error frame; the phone UI displays them.

Security details (PIN pairing, device fingerprint, TLS) live in the R6 ticket; not duplicated here.

### 9.5 SpeechSessionHost (serializes the single SpeechEngine)

```swift
protocol SpeechClient: AnyObject {
    func handlePartial(_ text: String)
    func handleFinal(_ text: String)
    func handleError(_ msg: String)
    func handleAudioLevel(_ level: Float)
}

protocol SpeechSessionHost: AnyObject {
    func acquire(client: SpeechClient) throws -> SpeechSession
}

final class SpeechSession {
    func start()
    func stop()
    func cancel()
    func release()
}

enum SpeechSessionError: Error { case busy }
```

`DefaultSpeechSessionHost` holds the singleton `SpeechEngine` plus a weak reference to the current active client. SpeechEngine callbacks (set once in AppDelegate) route via the host to the active client. Acquiring while busy throws `.busy`; the caller's hotkey handler can toast "Another recording in progress" and discard the press.

## 10. AppDelegate restructure

Deletes: `triggerDown`, `triggerUp`, `cancelRecording`, `finishTranscription`, `buildUserText`, `injectAfterPop`, `setupSpeechCallbacks` (replaced by host-routed callbacks). ~150 lines removed.

Adds (fields):

```swift
private var personaEngine: PersonaEngine!
private var voiceTrigger: VoiceTrigger!
private var selectionEditTrigger: SelectionEditTrigger!
private var clipboardTransformTrigger: ClipboardTransformTrigger!
private var phoneTrigger: PhoneTrigger?            // P4
private var speechSessionHost: DefaultSpeechSessionHost!
```

Wiring sequence inside `applicationDidFinishLaunching` (after existing menu/permission setup):

1. Construct `LLMClient`, `ContextResolver` (with the four built-in sources sharing `clipboardController.store`), `OutputRouter` (with the six built-in handlers, each holding their KeyMic-side dependency).
2. Construct `personaEngine` with the three above.
3. Construct `speechSessionHost` wrapping the existing `speechEngine` instance.
4. Construct triggers, injecting `personaEngine`, `speechSessionHost`, `overlayPanel`, `personaStore`, `textInjector`, and `currentFrontBundleID` closure as needed.
5. Hook `KeyMonitor` callbacks to trigger methods. Adds two new callbacks: `onSelectionEditHotkey` and `onClipboardTransformDown/Up`. Existing callbacks (`onTriggerDown/Up`, `onClipboardHotkey`, `onVaultHotkey`, `onScreenshotHotkey`, `onSettingsHotkey`, `onClipboardQuickPaste`) stay.
6. Forward `SpeechEngine` callbacks to `speechSessionHost.routePartial/Final/Error/AudioLevel`. The host fans out to the current client.

`KeyMonitor` is unmodified except for two new event emitters. Their hotkey identifiers register through the existing `HotkeyRegistry`/`HotkeySettingsStore` as new `HotkeyFeature` cases (`selectionEditTrigger`, `clipboardTransform`).

**Estimated AppDelegate size:** 777 → ~450 lines.

## 11. LLMClient

```swift
// Engine/LLMClient.swift

protocol LLMClient: AnyObject {
    var isReady: Bool { get }
    func complete(systemPrompt: String,
                  userText: String,
                  temperature: Double) async throws -> String
    func cancel()
}

final class OpenAICompatibleLLMClient: LLMClient {
    // Reads apiBaseURL / apiKey / model from existing UserDefaults keys
    // (llmAPIBaseURL, llmAPIKey, llmModel) — no migration needed.
    // Uses URLSession.shared async/await: try await session.data(for: request)
    // Reuses extractContent / pickContent / parseFirstJSONObject / extractErrorMessage
    // verbatim from LLMRefiner. Logging unchanged (subsystem io.keymic.app,
    // category LLMClient).
}

final class StubLLMClient: LLMClient {   // tests only
    var isReady = true
    var responder: ((String, String, Double) async throws -> String)!
}
```

`PersonaEngine` holds an `LLMClient` (protocol). Production wires `OpenAICompatibleLLMClient`. Tests inject `StubLLMClient`. `LLMRefiner.shared` and the `LLMRefiner` class are deleted; settings UI bindings move to whatever holds the production client (likely a small `LLMConfig` value object, but the existing UserDefaults backing means the Settings UI may stay unchanged).

## 12. Error handling and fallback matrix

| Failure | Trigger response |
|---|---|
| `InvocationError.cancelled` | Silently dismiss overlay |
| `.llmFailed` (VoiceTrigger) | Overlay shows "Refine failed: <msg>" 1.5 s, then passthrough-inject the raw transcript |
| `.llmFailed` (SelectionEditTrigger) | Panel surfaces the error inline; do not write back to selection; do not fall back |
| `.llmFailed` (ClipboardTransformTrigger) | Toast; do not modify clipboard; original clipboard item preserved |
| `.llmFailed` (PhoneTrigger) | WebSocket error frame to phone UI |
| `.contextResolveFailed(.ocrWindow)` | Skip that fragment, continue LLM with what we have (log warning) |
| `.contextResolveFailed(.selectedText)` on write side | Handled in `OutputRouter.replaceSelection` → fall back to `.replaceFocusedText` |
| `.outputFailed` from `.runShell` with denial | `.bypassed(.shellConfirmDenied)`, log info, no toast |
| `.outputFailed` from any other strategy | Toast with the strategy name + error |

## 13. Test plan

Tests follow the existing convention: standalone `swiftc` runners that print `… passed` or exit non-zero. Each gets a `make test-<name>` Makefile rule.

| Runner | Coverage | Dependencies / fakes |
|---|---|---|
| `PersonaEngineTests.swift` | 5-step pipeline; context fill; output routing; cancellation; bypass paths (no persona, LLM not ready, empty input) | `StubLLMClient`, in-memory `ContextSource` doubles, spy `OutputRouter` |
| `InvocationTests.swift` | `TextFragment` / `TextSource` codable round-trips; Persona v1→v2 migration adds defaults | None |
| `OutputRouterTests.swift` | Each strategy dispatches; `.replaceSelection` falls back to focused-text on write error; `.runShell(confirm)` denial returns bypassed | Spy `TextInjector`, fake `NSAlert` answer |
| `ContextResolverTests.swift` | All `contextMode` resolve rules; trigger-prefilled fragments win; `.windowOCR` stub returns nil cleanly | Stub `ContextSource`s |
| `SelectionEditTriggerTests.swift` | Empty selection short-circuits; submit builds correct `Invocation`; outputOverride is `.replaceSelection`; AX-write failure surfaces error | Fake panel, spy `PersonaEngine` |

Makefile additions:

```
test-persona-engine:
test-persona-invocation:
test-output-router:
test-context-resolver:
test-selection-edit-trigger:
```

All five chained into `test-all`.

## 14. Phase mapping (Linear → module)

| Phase | Linear tickets | Module deliverable |
|---|---|---|
| **P1** | LOR-14 (done), LOR-17 (Selection read+write), LOR-15 base (`.replaceFocusedText`, `.clipboard`, `.openURL`), LOR-16 R4 panel | Full `PersonaPlatform/` skeleton; `PersonaEngine`, `ContextResolver`, `OutputRouter` with 3 strategies; `VoiceTrigger` shipped replacing inline voice path; `SelectionEditTrigger` shipped |
| **P2** | LOR-18 (`.clipboard` / `.clipboardHistory` context modes), LOR-19 R5 | `ClipboardHistorySource`; `ClipboardTransformTrigger` |
| **P3** | LOR-20 R2.3, LOR-15 shell/iTerm | `WindowOCRSource` real impl; `ShellStrategy`, `ITermStrategy` with confirm gates |
| **P4** | LOR-21 R6 | `PhoneTrigger` + local TLS server subdirectory `Triggers/Phone/` |
| **P5** | LOR-22 R7 spike | `Skill/SkillRunner.swift` and friends |

P1 is the largest scope and the one this design must absolutely de-risk. P2-P5 only add files; no core protocol changes are anticipated.

## 15. Open questions / deferred

- **R4 panel UI (chips, recording button placement, preview truncation)**: deferred to a separate spec when LOR-16 implementation starts.
- **R7 Skill data model and discovery (built-in vs external skill dir)**: deferred; only the `Skill/` boundary and the `SkillRunner` placeholder are reserved here.
- **Multi-instance SpeechEngine**: deferred. Current design assumes single-session serialization via `SpeechSessionHost`. If R4 panel UX requires concurrent voice (panel listening while a long-press transform is in flight), revisit.
- **Persona output strategy UI**: each persona's `outputStrategy` needs Settings UI for users to set/edit. Spec deferred; not on the P1 critical path because P1 ships with sensible built-in defaults.

## 16. Built-in persona seeds

**Existing four** (`builtin-default`, `builtin-translate`, `builtin-cli`, `builtin-context`) all default to `outputStrategy = .replaceFocusedText` and `contextCount = 1` via the v1→v2 migration (§5).

**New, added per phase:**

- P1 — **Edit** (`builtin-edit`): used by `SelectionEditTrigger`. `contextMode = .selection`, `outputStrategy = .replaceSelection`. Prompt instructs the model to apply the user's instruction to the selected text and return only the rewritten text.
- P2 — **ClipboardTransformer** (`builtin-clipboard-transformer`): used by `ClipboardTransformTrigger`. `contextMode = .clipboard`, `outputStrategy = .clipboard`. Prompt instructs the model to apply the voice instruction to the clipboard contents.

Migration (§5) treats new built-ins the same as existing ones: `PersonaStore.mergeWithBuiltIns` appends any seed not yet on disk, preserves user edits to ones already there.

## 17. Non-goals

- Replacing or rewriting `KeyMonitor`, `SpeechEngine`, `ClipboardStore`, `ClipboardMonitor`, `TextInjector`, `OverlayPanel`, `HotkeyRegistry`, `HotkeySettingsStore`. They are dependencies and their public surface is unchanged.
- Sandboxing the app or adding new entitlements. The platform stays within current TCC grants (Accessibility, Microphone, SpeechRecognition, ScreenCapture).
- Changing the appcast / Sparkle update flow.
- Changing the Vault subsystem or the secret scanner.
