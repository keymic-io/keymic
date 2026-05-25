# Shell + iTerm Output Strategies (LOR-15 P3 / R3 extension)

> **Status:** Draft · 2026-05-23
> **Linear:** [LOR-15 OutputRouter (Done at P1 with stubs)](https://linear.app/lorne/issue/LOR-15)
> **Parent epic:** [LOR-23 Voice + LLM Persona Platform](https://linear.app/lorne/issue/LOR-23)
> **Phase:** P3
> **Builds on:** [Output Router P1 spec §5.5–5.6](2026-05-21-lor-15-output-router.md) — contract drafted, this spec is the implementation contract
> **Dependencies:** None new — P1 OutputRouter already has the strategy enum cases stubbed as `.failed(message:)`

---

## 1. Context

`OutputRouter` (P1) ships with two stubbed strategies:

```swift
case .runShell:
    return .failed(message: "shell strategy not yet available")
case .writeToITermPane:
    return .failed(message: "iterm strategy not yet available")
```

`InjectionStrategy` already has the case shapes (`.runShell(commandTemplate: String)`, `.writeToITermPane(paneIndex: Int)`) and they decode/encode correctly through Persona JSON. This spec replaces the stubs with real implementations, plus the supporting confirmation UI and Automation permission scaffolding.

These two strategies are what unlocks the "CLI Wizard" and "Terminal operator" personas from the original ideas doc.

## 2. Goals

- Replace both stubs with shipping implementations.
- `.runShell` MUST surface a confirmation sheet on every invocation — no silent execution, ever. Default button is **Cancel**.
- `.writeToITermPane` writes via AppleScript to the iTerm 2 app; works without a confirmation dialog (the act of voice-typing into a known terminal is the implicit consent).
- Both strategies reject empty / placeholder-only commands at the OutputRouter layer.
- Both strategies degrade gracefully when their environment is missing (no iTerm installed; Automation permission denied; shell command refused by user).
- One new built-in persona surfaced via this spec: **CLI Wizard** flips from `.replaceFocusedText` to `.runShell(commandTemplate: "{query}")` (P1 left the seed at `.replaceFocusedText` pending this work).

## 3. Non-Goals

- A remember-my-choice option on the shell confirmation sheet. Confirmation is per-invocation, intentionally high-friction.
- Long-running / interactive shell sessions. `Process` runs once, returns once.
- Shell input injection (sending stdin to a running process). Out of scope.
- Apple Terminal.app support. iTerm 2 only — broader terminal coverage can come later.
- Specific iTerm pane addressing (e.g. "the pane I right-clicked"). `paneIndex: Int` selects from current window's sessions in z-order; if the user wants finer control, they switch focus to that pane first.
- A shell strategy "allowlist" of safe commands. The confirmation sheet is the safety mechanism.

## 4. `.runShell(commandTemplate:)`

### 4.1 Module layout

```
Sources/KeyMic/Output/Shell/
├── ShellRunner.swift                // pure Process execution + capture
├── ShellConfirmationSheet.swift     // NSAlert-style confirmation UI
└── ShellTemplate.swift              // (extension to existing URLTemplate or new file) placeholder substitution
```

### 4.2 OutputRouter dispatch

Replace the stub:

```swift
case .runShell(let commandTemplate):
    return await runShell(template: commandTemplate, output: output)
```

Where `runShell` lives on `OutputRouter`:

```swift
private func runShell(template: String, output: PersonaOutput) async -> RouteResult {
    let substituted = ShellTemplate.substitute(
        template: template, text: output.text, context: output.context
    )
    guard let command = substituted, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
        return .failed(message: "Empty shell command after substitution")
    }
    // Reject commands whose all placeholders resolved to empty.
    guard ShellTemplate.hasResolvedSubstantialContent(original: template, resolved: command) else {
        return .failed(message: "Refusing to run command with empty placeholders")
    }

    // Confirmation sheet (always, no remember-my-choice).
    let confirmed = await confirmShellRun(command)
    guard confirmed else { return .userCancelled }

    do {
        let result = try await ShellRunner.run(command)
        // stdout → focused field via TextInjector (mirrors .replaceFocusedText).
        if !result.stdout.isEmpty {
            textInjector.inject(result.stdout)
        }
        if !result.stderr.isEmpty {
            routerLogger.error("shell stderr (exit=\(result.exitCode)): present")
            return .failed(message: result.stderr.prefix(200) + (result.stderr.count > 200 ? "…" : ""))
        }
        return .injected
    } catch {
        return .failed(message: "shell run failed: \(error.localizedDescription)")
    }
}
```

`confirmShellRun` is the closure already wired into `OutputRouter.init` (P1 spec §4.1). It returns `Bool`. The default implementation in `AppDelegate` presents the new `ShellConfirmationSheet`.

### 4.3 ShellTemplate

```swift
enum ShellTemplate {
    /// Same placeholders as URLTemplate but NO URL encoding.
    /// Supported: {query}, {selection}, {clipboard}, {clipboardTop}
    /// Unknown placeholders are left literal so the user sees them in the confirmation
    /// sheet and can spot misconfigured templates.
    static func substitute(template: String, text: String, context: PersonaContext?) -> String?

    /// Returns true if at least one placeholder resolved to non-empty content,
    /// OR if the template had no placeholders at all (literal command).
    /// Refusing the run when EVERY placeholder is empty prevents silent surprise
    /// (e.g. `rm -rf {selection}` with no selection becoming `rm -rf `).
    static func hasResolvedSubstantialContent(original: String, resolved: String) -> Bool
}
```

### 4.4 ShellRunner

```swift
struct ShellRunResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ShellRunnerError: Error {
    case launchFailed(Error)
    case timeout
}

enum ShellRunner {
    /// Runs `/bin/zsh -c <command>`. Captures stdout + stderr. Times out at 30s.
    /// stdin is /dev/null.
    static func run(_ command: String, timeout: TimeInterval = 30) async throws -> ShellRunResult
}
```

Implementation: `Process` with `launchPath = "/bin/zsh"`, `arguments = ["-c", command]`, `Pipe()` for both standard streams. Read both pipes on background queues to avoid deadlock when output exceeds pipe buffer (~64 KB). A 30-second `DispatchSource.makeTimerSource` cancels the process and throws `.timeout` if it overruns.

Environment passthrough: full inheritance of `ProcessInfo.processInfo.environment` minus `KEYMIC_*` keys (so personas can't read KeyMic's own env vars accidentally — defensive habit, not a hard threat).

Working directory: `NSHomeDirectory()`.

### 4.5 ShellConfirmationSheet

Standalone `NSAlert`-style presentation attached to a transient borderless `NSPanel`. The shape:

```
┌─────────────────────────────────────────────┐
│  ⚠️  Run shell command?                       │
│                                              │
│  ┌─────────────────────────────────────────┐ │
│  │ git log --oneline -10 | grep "feat"     │ │   ← monospace
│  └─────────────────────────────────────────┘ │
│                                              │
│  This command will run in your shell with    │
│  your full user environment.                 │
│                                              │
│              [ Cancel ]  [ Run ]             │   ← default = Cancel
└─────────────────────────────────────────────┘
```

API:

```swift
@MainActor
enum ShellConfirmationSheet {
    /// Presents the confirmation. Returns true if the user clicks Run.
    /// Default action is Cancel (Esc and Enter on the default button both cancel).
    /// The command text is shown verbatim, monospace, scrollable if it exceeds 5 lines.
    static func present(command: String) async -> Bool
}
```

Use `NSAlert` with `.warning` icon, custom accessory view holding an `NSTextView` for the monospace command preview. Configure:

- `.alertStyle = .warning`
- Buttons added in order: `[Cancel]` then `[Run]`.
- The default button (`.keyEquivalent = "\r"`) is **Cancel**, NOT Run. This is unusual but intentional — accidentally hitting Enter must not execute a command.
- `Run` button is keyboard-accessible via Cmd+R.

Why an `NSAlert` and not a custom panel: alerts handle modality / focus / Esc / VoiceOver correctly out of the box. The "tiny floating panel" alternative would replicate that work and likely get it wrong.

### 4.6 Built-in persona update

`Persona.builtInSeeds()` — `builtin-cli` flips its strategy:

```swift
Persona(
    id: "builtin-cli",
    name: "CLI Wizard",
    icon: "terminal",
    stylePrompt: "Convert voice transcription into executable shell commands. Be concise and accurate for technical users. Return ONLY the command, with no markdown fences.",
    temperature: 0.1,
    hotkey: nil,
    contextSources: [],
    builtIn: true,
    injectionStrategy: .runShell(commandTemplate: "{query}")    // was .replaceFocusedText
)
```

Existing installs already have `builtin-cli` on disk with `.replaceFocusedText`. `PersonaStore.merge` (LOR-14) overwrites only the immutable fields on built-ins (name, builtIn flag); user-editable fields including `injectionStrategy` are preserved. To roll the change forward for existing users, treat `injectionStrategy` as immutable for built-ins **going forward** — i.e., promote `injectionStrategy` from "user-editable" to "user-editable for custom personas only, fixed for built-ins". This is consistent with the original spec's framing: the persona's identity includes its destination.

Add to `PersonaStore.merge`: copy `injectionStrategy` from the seed onto the loaded built-in if the seed's `builtIn == true`. One-line change, documented in the PR description.

## 5. `.writeToITermPane(paneIndex:)`

### 5.1 Module layout

```
Sources/KeyMic/Output/iTerm/
├── ITermBridge.swift               // AppleScript invocation + permission handling
└── ITermAvailability.swift         // bundle-presence + Automation permission check
```

### 5.2 OutputRouter dispatch

```swift
case .writeToITermPane(let paneIndex):
    return await writeToITerm(paneIndex: paneIndex, text: output.text)
```

```swift
private func writeToITerm(paneIndex: Int, text: String) async -> RouteResult {
    guard ITermAvailability.isInstalled() else {
        return .failed(message: "iTerm 2 is not installed")
    }
    do {
        try await ITermBridge.write(text: text, paneIndex: paneIndex)
        return .injected
    } catch ITermBridge.Error.permissionDenied {
        return .failed(message: "Automation permission for iTerm 2 is required (System Settings → Privacy & Security → Automation → KeyMic)")
    } catch {
        return .failed(message: "iTerm write failed: \(error.localizedDescription)")
    }
}
```

### 5.3 ITermAvailability

```swift
enum ITermAvailability {
    /// True if iTerm 2 (com.googlecode.iterm2) is installed and discoverable.
    static func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }
}
```

### 5.4 ITermBridge

AppleScript via `NSAppleScript`. The script:

```applescript
tell application "iTerm"
    if (count of windows) = 0 then
        return "no-window"
    end if
    tell current window
        set sessionList to sessions
        if (count of sessionList) < <PANE_INDEX+1> then
            return "out-of-range"
        end if
        tell item <PANE_INDEX+1> of sessionList
            write text "<ESCAPED_TEXT>"
        end tell
    end tell
end tell
```

`<PANE_INDEX+1>` because AppleScript is 1-indexed; the strategy enum stores 0-indexed for sanity. `<ESCAPED_TEXT>` escapes `"`, `\`, and newlines per AppleScript string literal rules (a small `ITermBridge.escapeForAppleScript` helper).

API:

```swift
enum ITermBridge {
    enum Error: Swift.Error, Equatable {
        case permissionDenied              // -1743 / errAEEventNotPermitted
        case appleScriptFailed(String)
        case iTermNotRunning
        case paneOutOfRange
        case noActiveWindow
    }

    @MainActor
    static func write(text: String, paneIndex: Int) async throws
}
```

Detect permission denial by inspecting the `NSAppleScript.executeAndReturnError(_:)` error dictionary — `NSAppleScriptErrorNumber == -1743` indicates `errAEEventNotPermitted`. First-time invocation triggers macOS's Automation prompt natively; subsequent denials surface as `-1743` and we route them to `.permissionDenied`.

### 5.5 Why not the iTerm Python API

iTerm 2 ships a Python API (websocket-based) that's nicer than AppleScript but requires the user to install a separate Python runtime *and* enable the API in iTerm preferences. AppleScript is built in and works out of the box. We accept the AppleScript fragility (it's slower, ~30 ms per call, and has the Automation permission flow) in exchange for zero-setup operation.

### 5.6 No new built-in persona

Personas using `.writeToITermPane` are inherently user-specific (which pane index, what shape of input). Don't ship a built-in; document the strategy in PersonasView when users edit a custom persona's `injectionStrategy` picker.

## 6. PersonasView edits

`PersonasView` already renders an `injectionStrategy` editor (added in LOR-15 P1 cleanup). Update:

- `.runShell(commandTemplate:)` row → text field for the command template, with a small "Placeholders: {query} {selection} {clipboard}" hint label.
- `.writeToITermPane(paneIndex:)` row → integer stepper (0–9) for the pane index.

When a built-in persona has its strategy field locked (per §4.6), grey out the picker with a tooltip "Built-in personas have a fixed output strategy."

## 7. Logging

Subsystem `io.keymic.app`, category `OutputRouter`.

- `.debug` on `.runShell`: template, substituted command length (NOT content), user decision (confirmed/cancelled), exit code, duration.
- `.error` on `ShellRunner` failure: error case, never the command content.
- `.debug` on `.writeToITermPane`: pane index, text length, success/failure.
- `.error` on `.permissionDenied`: log once per launch (rate-limited).
- **No PII**: command content and text content NEVER logged.

## 8. Test Strategy

`make test-shell-output` (new runner) + extensions to existing `test-output-router`.

### Pure-logic tests

- `ShellTemplate.substitute`:
  - `"{query}"` + text `"foo"` → `"foo"`
  - `"echo {query}"` + text `"hi there"` → `"echo hi there"` (no shell escaping at this layer; the persona writes safe templates)
  - `"echo {unknown}"` → left literal `"echo {unknown}"`
  - Unicode passthrough.
- `ShellTemplate.hasResolvedSubstantialContent`:
  - Literal template (no placeholders): always true.
  - Template with placeholders that all resolved to empty: false.
  - Template with at least one non-empty resolution: true.
- `ITermBridge.escapeForAppleScript`:
  - `"`hello`"` → `"\"hello\""`
  - `"line1\nline2"` → `"line1\" & return & \"line2"` (verify with a live iTerm session in manual smoke)

### Integration tests with stubs

- `OutputRouter.route(.runShell)` with `confirmShellRun = { _ in false }` → returns `.userCancelled`, `ShellRunner.run` never invoked.
- `OutputRouter.route(.runShell)` with confirmed = true and stub ShellRunner returning `{stdout: "ok", stderr: "", exitCode: 0}` → returns `.injected`, `TextInjector.inject("ok")` called once.
- `OutputRouter.route(.runShell)` with stub returning `{stderr: "no such file"}` → returns `.failed("no such file")`, no inject.
- `OutputRouter.route(.writeToITermPane)` when `ITermAvailability.isInstalled() == false` → returns `.failed("iTerm 2 is not installed")`, AppleScript not invoked.

### Manual smoke matrix

| Setup | Action | Expected |
|---|---|---|
| Press hotkey for CLI Wizard, say "list files" | speak | Confirmation sheet shows `ls` (or similar). Click Run → output pastes into focused field. |
| Same as above | Click Cancel (or hit Enter on the default button) | Nothing happens. Persona's voice session ends silently. |
| Sheet open | Esc | Cancels |
| Sheet open | Cmd+R | Runs |
| Shell command takes > 30 s | speak long-running cmd, confirm | Times out, error toast |
| Shell command writes 200 KB stdout | confirm | All injected to focused field (pipe drain prevents deadlock) |
| Shell with `{selection}` placeholder, no selection | speak | `.failed("Refusing to run command with empty placeholders")` |
| iTerm 2 not installed | persona uses `.writeToITermPane` | `.failed("iTerm 2 is not installed")` |
| iTerm 2 installed, Automation NOT granted yet | persona uses `.writeToITermPane` | macOS Automation prompt appears; on first grant, write succeeds |
| Automation explicitly denied (System Settings) | persona uses `.writeToITermPane` | `.failed` with link-pointing message |
| `paneIndex = 5` but only 2 panes exist | persona | `.failed("paneOutOfRange")` |
| Existing user with `builtin-cli` already on disk | upgrade | After launch, `builtin-cli.injectionStrategy == .runShell(...)`; user's edits to stylePrompt preserved |

## 9. Migration / rollout

1. Land ShellRunner + ShellTemplate + ShellConfirmationSheet, no OutputRouter changes yet (`make test-shell-output` passes).
2. Land ITermBridge + ITermAvailability (`make test-shell-output` covers what's testable).
3. Wire OutputRouter `.runShell` arm; keep `.writeToITermPane` stubbed. Manual smoke + commit.
4. Wire OutputRouter `.writeToITermPane` arm. Manual smoke + commit.
5. Update `builtin-cli` seed + PersonaStore.merge promote `injectionStrategy` to immutable-on-built-in. Bump test expectations. Commit.
6. PersonasView editor updates (`.runShell` template field, `.writeToITermPane` stepper). Commit.
7. Final `make test-all` green, smoke matrix run, PR.

## 10. Open Questions

- **Should ShellConfirmationSheet show the substituted command OR the template?** Decision: substituted, per the P1 spec §5.5. The user sees what will actually run. Templates that the user doesn't recognize are a red flag worth confirming.
- **Should we offer "Run in iTerm" as the Run button's submenu** (i.e. open a new iTerm pane and run there instead of capturing stdout)? Proposal: not in P3 — that's a separate strategy. Power users compose with `.writeToITermPane` if they want it. Reconsider if shell capture proves clumsy.
- **Should the 30-second `ShellRunner` timeout be configurable per-persona?** Proposal: not in P3. Personas using `.runShell` should write fast commands; long-running ones are out of scope.
- **Should `.runShell` strip ANSI escape sequences from stdout before injecting?** Many CLIs emit colored output. Proposal: yes — add a tiny `ANSIStripper.strip(_:)` helper invoked just before `textInjector.inject`. Add to scope.

## 11. Acceptance Criteria

- [ ] `OutputRouter` no longer returns `"shell strategy not yet available"` / `"iterm strategy not yet available"` — both strategies route to real implementations.
- [ ] `.runShell` shows confirmation sheet for every invocation; default action is Cancel.
- [ ] Esc, Enter (on default), and outside-clicks all cancel the sheet.
- [ ] Cmd+R inside the sheet runs the command.
- [ ] `ShellRunner` captures stdout + stderr without deadlocking on > 64 KB output.
- [ ] `ShellRunner` times out at 30 s with a clear error message.
- [ ] `ShellTemplate.hasResolvedSubstantialContent` correctly refuses templates whose placeholders all resolved to empty.
- [ ] ANSI escape sequences stripped from stdout before injection.
- [ ] `.writeToITermPane` writes to the specified pane index in iTerm 2's current window.
- [ ] iTerm 2 absent → graceful `.failed` with a clear message.
- [ ] Automation permission denied → graceful `.failed` with link-style message pointing at System Settings.
- [ ] `builtin-cli` persona's `injectionStrategy` is `.runShell(commandTemplate: "{query}")` after the migration; user's stylePrompt edits preserved across the upgrade.
- [ ] PersonasView shows template / pane-index editors for the two strategies.
- [ ] `make test-shell-output` passes; `make test-output-router` extensions pass; `make test-all` green.
- [ ] Manual smoke matrix in §8 fully green.
- [ ] No log line contains shell command content or injected text content.
