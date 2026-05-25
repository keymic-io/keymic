# LOR-15 P3 Shell + iTerm Output Strategies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `OutputRouter` stubs for `.runShell(commandTemplate:)` and `.writeToITermPane(paneIndex:)` with shipping implementations. `.runShell` MUST show a per-invocation confirmation sheet (default = Cancel). `.writeToITermPane` writes via AppleScript with graceful degradation when iTerm is missing or Automation permission is denied. Promote the `builtin-cli` persona's `injectionStrategy` to `.runShell(commandTemplate: "{query}")` and lock it on built-ins via `PersonaStore.merge`.

**Architecture:** Two new module clusters — `Sources/KeyMic/Output/Shell/` (pure `ShellTemplate` + `ANSIStripper` + Process-driven `ShellRunner` + `NSAlert`-based `ShellConfirmationSheet`) and `Sources/KeyMic/Output/iTerm/` (`ITermAvailability` + `NSAppleScript` `ITermBridge`). `OutputRouter` gains a `confirmShellRun: (String) async -> Bool` constructor parameter; `AppDelegate` injects the real sheet presenter. `PersonaStore.mergeWithBuiltIns` copies `injectionStrategy` from the seed onto loaded built-ins so existing installs upgrade silently. `PersonasView` gains editor arms for `.runShell` and `.writeToITermPane` and locks the picker on built-ins.

**Tech Stack:** Swift 5.9, SwiftPM single target, Foundation-only / AppKit / `NSAppleScript` for `ITermBridge`, standalone `swiftc` test runners under `Tests/` (NOT XCTest — see `CLAUDE.md`). macOS 14.

**Source spec:** `docs/persona-platform/2026-05-23-lor-15-shell-and-iterm-output.md`

**Builds on:** [Output Router P1 spec](../2026-05-21-lor-15-output-router.md) — `InjectionStrategy.runShell` / `.writeToITermPane` cases already exist; this plan only fills the stubs and supporting UI.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/KeyMic/Output/Shell/ShellTemplate.swift` | Create | `{query}/{selection}/{clipboard}/{clipboardTop}` substitution (NO URL encoding) + `hasResolvedSubstantialContent` guard. |
| `Sources/KeyMic/Output/Shell/ANSIStripper.swift` | Create | Strip ANSI CSI / OSC escape sequences from shell stdout before injection. |
| `Sources/KeyMic/Output/Shell/ShellRunner.swift` | Create | `Process` wrapper: `/bin/zsh -c <command>` with stdout+stderr Pipe drain, 30 s timeout, env passthrough minus `KEYMIC_*`. |
| `Sources/KeyMic/Output/Shell/ShellConfirmationSheet.swift` | Create | `@MainActor` `NSAlert` with monospace accessory view. Default button = Cancel. Cmd+R = Run. |
| `Sources/KeyMic/Output/iTerm/ITermAvailability.swift` | Create | `NSWorkspace.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil`. |
| `Sources/KeyMic/Output/iTerm/ITermBridge.swift` | Create | `NSAppleScript` invocation + permission-denial mapping (`-1743 → .permissionDenied`). |
| `Sources/KeyMic/Output/OutputRouter.swift` | Modify | Add `confirmShellRun` init param; replace `.runShell` + `.writeToITermPane` stubs with real dispatch. |
| `Sources/KeyMic/LLM/Persona.swift` | Modify | `builtin-cli` seed: `.replaceFocusedText` → `.runShell(commandTemplate: "{query}")`. |
| `Sources/KeyMic/LLM/PersonaStore.swift` | Modify | `mergeWithBuiltIns` copies seed's `injectionStrategy` onto loaded built-ins. |
| `Sources/KeyMic/SettingsUI/PersonasView.swift` | Modify | Add `InjectionStrategy` picker + per-arm editors (`.runShell` template field, `.writeToITermPane` stepper). Lock picker on built-ins. |
| `Sources/KeyMic/AppDelegate.swift` | Modify | Provide `confirmShellRun` closure → `ShellConfirmationSheet.present`. |
| `Tests/ShellOutputTests.swift` | Create | Pure-logic tests: `ShellTemplate.substitute`, `hasResolvedSubstantialContent`, `ANSIStripper.strip`, `ShellRunner.run("echo hello")`. |
| `Tests/OutputRouterTests.swift` | Modify | Cover new `.runShell` cancelled / success / stderr paths and `.writeToITermPane` "not installed" path with stubs. |
| `Tests/PersonaTests.swift` | Modify | `seeds[2].injectionStrategy == .runShell(commandTemplate: "{query}")`. |
| `Tests/PersonaInjectionStrategyTests.swift` | Modify | `"builtin-cli": .runShell(commandTemplate: "{query}")`. |
| `Tests/PersonaStoreTests.swift` | Modify | New migration test: legacy JSON with `builtin-cli` strategy `.replaceFocusedText` loads as `.runShell(commandTemplate: "{query}")`. |
| `Makefile` | Modify | New `test-shell-output` target; extend `test-output-router` source list; thread into `test-all`. |

---

## Task 1: `ShellTemplate.substitute` + `hasResolvedSubstantialContent` (TDD)

Pure Foundation helpers. Mirrors the `URLTemplate.substitute` pattern at the bottom of `OutputRouter.swift` but without URL encoding — shell-safe quoting is the persona author's responsibility, and the confirmation sheet is the safety net.

**Files:**
- Create: `Sources/KeyMic/Output/Shell/ShellTemplate.swift`
- Create: `Tests/ShellOutputTests.swift` (stub runner — single suite for all pure-logic tests, will grow in Tasks 2 + 3)
- Modify: `Makefile`

- [ ] **Step 1: Write failing test runner**

`Tests/ShellOutputTests.swift`:

```swift
import Foundation

@main
struct ShellOutputTestRunner {
    static func main() {
        // ShellTemplate.substitute
        testSubstituteQuery()
        testSubstituteEcho()
        testSubstituteUnknownPlaceholderLiteral()
        testSubstituteUnicode()
        testSubstituteSelectionAndClipboard()

        // ShellTemplate.hasResolvedSubstantialContent
        testLiteralTemplateAlwaysSubstantial()
        testAllPlaceholdersEmptyNotSubstantial()
        testOneNonEmptyResolutionSubstantial()

        print("ShellOutputTests passed")
    }

    static func testSubstituteQuery() {
        let got = ShellTemplate.substitute(template: "{query}", text: "foo", context: nil)
        expect(got == "foo", "{query} should substitute to text, got: \(got ?? "nil")")
    }

    static func testSubstituteEcho() {
        let got = ShellTemplate.substitute(template: "echo {query}", text: "hi there", context: nil)
        expect(got == "echo hi there", "echo passthrough mismatch, got: \(got ?? "nil")")
    }

    static func testSubstituteUnknownPlaceholderLiteral() {
        let got = ShellTemplate.substitute(template: "echo {unknown}", text: "anything", context: nil)
        expect(got == "echo {unknown}", "unknown placeholder must remain literal, got: \(got ?? "nil")")
    }

    static func testSubstituteUnicode() {
        let got = ShellTemplate.substitute(template: "echo {query}", text: "héllo 🌍", context: nil)
        expect(got == "echo héllo 🌍", "unicode passthrough failed, got: \(got ?? "nil")")
    }

    static func testSubstituteSelectionAndClipboard() {
        let ctx = PersonaContext(selection: "SEL", clipboardTop: "CLIP", clipboardHistory: nil)
        let got = ShellTemplate.substitute(
            template: "cmd {selection} {clipboard}", text: "Q", context: ctx)
        expect(got == "cmd SEL CLIP",
               "selection+clipboard passthrough failed, got: \(got ?? "nil")")
    }

    static func testLiteralTemplateAlwaysSubstantial() {
        let ok = ShellTemplate.hasResolvedSubstantialContent(
            original: "ls -la", resolved: "ls -la")
        expect(ok, "literal templates (no placeholders) must be substantial")
    }

    static func testAllPlaceholdersEmptyNotSubstantial() {
        // Template had placeholders; all resolved to "". Expect false.
        let ok = ShellTemplate.hasResolvedSubstantialContent(
            original: "rm -rf {selection}", resolved: "rm -rf ")
        expect(!ok, "empty-placeholder resolution must be refused")
    }

    static func testOneNonEmptyResolutionSubstantial() {
        let ok = ShellTemplate.hasResolvedSubstantialContent(
            original: "echo {query} {selection}", resolved: "echo hi ")
        expect(ok, "at least one non-empty placeholder is substantial")
    }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { fail(msg) }
    }
    static func fail(_ msg: String) {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }
}
```

- [ ] **Step 2: Confirm compile fails (no implementation yet)**

Run: `mkdir -p .build && swiftc Tests/ShellOutputTests.swift -o .build/shell-output-tests 2>&1 | head -3`

Expected: `cannot find 'ShellTemplate' in scope`.

- [ ] **Step 3: Write `ShellTemplate`**

`Sources/KeyMic/Output/Shell/ShellTemplate.swift`:

```swift
import Foundation

/// Pure helper for the `.runShell` injection strategy. Mirrors `URLTemplate.substitute`
/// shape but performs NO URL encoding — shell quoting is the persona author's job,
/// and the confirmation sheet is the safety net.
///
/// Supported placeholders: `{query}`, `{selection}`, `{clipboard}` (aliases of
/// `{clipboardTop}`). Unknown placeholders are left LITERAL so they show up
/// verbatim in the confirmation sheet and signal misconfiguration to the user.
enum ShellTemplate {
    static func substitute(template: String, text: String, context: PersonaContext?) -> String? {
        var out = template
        out = out.replacingOccurrences(of: "{query}", with: text)
        out = out.replacingOccurrences(of: "{selection}", with: context?.selection ?? "")
        out = out.replacingOccurrences(of: "{clipboardTop}", with: context?.clipboardTop ?? "")
        out = out.replacingOccurrences(of: "{clipboard}", with: context?.clipboardTop ?? "")
        return out
    }

    /// Returns `true` if at least one placeholder resolved to non-empty content,
    /// OR if the template had no placeholders at all (literal command).
    ///
    /// Returning `false` short-circuits `OutputRouter` BEFORE the confirmation sheet
    /// to prevent surprises like `rm -rf {selection}` becoming `rm -rf ` when nothing
    /// is selected.
    static func hasResolvedSubstantialContent(original: String, resolved: String) -> Bool {
        // Strip every known placeholder from `original`. If the residual matches `resolved`
        // (modulo whitespace shrinkage), every placeholder collapsed to "".
        var stripped = original
        for placeholder in ["{query}", "{selection}", "{clipboardTop}", "{clipboard}"] {
            stripped = stripped.replacingOccurrences(of: placeholder, with: "")
        }
        // If `original` had no placeholders at all, `stripped == original == resolved`.
        // That's a literal command — always substantial.
        if stripped == original { return true }
        // If every placeholder resolved to "", `resolved == stripped`. Refuse.
        return resolved != stripped
    }
}
```

- [ ] **Step 4: Add `test-shell-output` Makefile target**

Append after the existing `test-clipboard-transform` block (around line 522):

```makefile
test-shell-output:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/PersonaContext.swift \
	       Sources/KeyMic/LLM/ContextSource.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Tests/ShellOutputTests.swift \
	       -o .build/shell-output-tests
	.build/shell-output-tests
```

Append `test-shell-output` to the end of the `test-all:` chain (line 537).

- [ ] **Step 5: Run test → green**

Run: `make test-shell-output`

Expected: `ShellOutputTests passed`.

- [ ] **Step 6: Full build sanity**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/Output/Shell/ShellTemplate.swift \
        Tests/ShellOutputTests.swift Makefile
git commit -m "feat(output): add ShellTemplate substitution + substantial-content guard (LOR-15)"
```

---

## Task 2: `ANSIStripper.strip` pure helper (TDD)

Many CLIs (`git log`, `ls --color`, `npm`, …) emit ANSI escapes. Spec §10 adds ANSI stripping to scope to keep injected text clean.

**Files:**
- Create: `Sources/KeyMic/Output/Shell/ANSIStripper.swift`
- Modify: `Tests/ShellOutputTests.swift` (extend existing runner)
- Modify: `Makefile` (add `ANSIStripper.swift` to `test-shell-output` source list)

- [ ] **Step 1: Extend test runner**

Edit `Tests/ShellOutputTests.swift`. In `main()`, add (after `testOneNonEmptyResolutionSubstantial()`):

```swift
        // ANSIStripper.strip
        testStripPassthrough()
        testStripCSIColor()
        testStripCSIMulti()
        testStripOSC()
        testStripBare()
```

Append these methods inside the struct, after `testOneNonEmptyResolutionSubstantial`:

```swift
    static func testStripPassthrough() {
        let got = ANSIStripper.strip("hello world")
        expect(got == "hello world", "plain text must passthrough, got: \(got)")
    }

    static func testStripCSIColor() {
        // ESC[31mRED ESC[0m  (red foreground + reset)
        let input = "\u{001B}[31mRED\u{001B}[0m"
        let got = ANSIStripper.strip(input)
        expect(got == "RED", "CSI color stripping failed, got: \(got)")
    }

    static func testStripCSIMulti() {
        let input = "\u{001B}[1;32mBOLD GREEN\u{001B}[0m and \u{001B}[4munderlined\u{001B}[0m"
        let got = ANSIStripper.strip(input)
        expect(got == "BOLD GREEN and underlined", "multi-CSI strip failed, got: \(got)")
    }

    static func testStripOSC() {
        // ESC]0;title (window title OSC, BEL terminator)
        let input = "\u{001B}]0;my title\u{0007}body"
        let got = ANSIStripper.strip(input)
        expect(got == "body", "OSC strip failed, got: \(got)")
    }

    static func testStripBare() {
        // Bare ESC with no recognized intro — drop the ESC, keep the rest.
        let input = "\u{001B}xliteral"
        let got = ANSIStripper.strip(input)
        expect(got == "xliteral" || got == "literal",
               "bare ESC handling unexpected, got: \(got)")
    }
```

- [ ] **Step 2: Confirm compile fails**

Run: `swiftc Sources/KeyMic/LLM/PersonaContext.swift Sources/KeyMic/LLM/ContextSource.swift Sources/KeyMic/Output/Shell/ShellTemplate.swift Tests/ShellOutputTests.swift -o /tmp/sot 2>&1 | head -3`

Expected: `cannot find 'ANSIStripper' in scope`.

- [ ] **Step 3: Write implementation**

`Sources/KeyMic/Output/Shell/ANSIStripper.swift`:

```swift
import Foundation

/// Strips ANSI escape sequences from text. Invoked on `ShellRunner` stdout before
/// `TextInjector.inject` so users don't see raw color codes pasted into their docs.
///
/// Handles:
/// - CSI (Control Sequence Introducer): ESC `[` ... letter (e.g. `[31m`).
/// - OSC (Operating System Command): ESC `]` ... BEL or ESC `\`.
/// - Bare ESC followed by an unrecognized intro: drop the ESC byte.
///
/// Not handled (rare in CLI stdout we'd capture):
/// - DCS/PM/APC sequences — caller can extend if needed.
enum ANSIStripper {
    static func strip(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "\u{001B}" {
                let next = input.index(after: i)
                if next < input.endIndex {
                    let intro = input[next]
                    if intro == "[" {
                        // CSI: read params/intermediates until a final byte (0x40-0x7E).
                        var j = input.index(after: next)
                        while j < input.endIndex {
                            let cc = input[j]
                            if let scalar = cc.unicodeScalars.first,
                               (0x40...0x7E).contains(Int(scalar.value)) {
                                j = input.index(after: j)
                                break
                            }
                            j = input.index(after: j)
                        }
                        i = j
                        continue
                    } else if intro == "]" {
                        // OSC: read until BEL (0x07) or ESC \ (ST).
                        var j = input.index(after: next)
                        while j < input.endIndex {
                            let cc = input[j]
                            if cc == "\u{0007}" {
                                j = input.index(after: j)
                                break
                            }
                            if cc == "\u{001B}" {
                                let k = input.index(after: j)
                                if k < input.endIndex, input[k] == "\\" {
                                    j = input.index(after: k)
                                    break
                                }
                            }
                            j = input.index(after: j)
                        }
                        i = j
                        continue
                    } else {
                        // Bare ESC + unknown intro → drop the ESC, keep `intro` and onward.
                        i = next
                        continue
                    }
                } else {
                    // Trailing ESC — drop it.
                    break
                }
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
    }
}
```

- [ ] **Step 4: Update Makefile target source list**

Edit `Makefile` `test-shell-output` block:

```makefile
test-shell-output:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/PersonaContext.swift \
	       Sources/KeyMic/LLM/ContextSource.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Tests/ShellOutputTests.swift \
	       -o .build/shell-output-tests
	.build/shell-output-tests
```

- [ ] **Step 5: Run test → green**

Run: `make test-shell-output`

Expected: `ShellOutputTests passed`.

- [ ] **Step 6: Build sanity**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/Output/Shell/ANSIStripper.swift \
        Tests/ShellOutputTests.swift Makefile
git commit -m "feat(output): add ANSIStripper for shell stdout cleanup (LOR-15)"
```

---

## Task 3: `ShellRunner.run(_:timeout:)` (Process + Pipe drain + timeout)

Process wrapper with stdout+stderr Pipe drains on background queues (mandatory — 64 KB pipe buffer otherwise deadlocks), 30 s timeout, `env` passthrough minus `KEYMIC_*`, `stdin = /dev/null`, `cwd = NSHomeDirectory()`.

**Files:**
- Create: `Sources/KeyMic/Output/Shell/ShellRunner.swift`
- Modify: `Tests/ShellOutputTests.swift` — append integration smoke (`echo hello`, `false`, `sleep 100` w/ short timeout)
- Modify: `Makefile`

- [ ] **Step 1: Extend test runner**

Edit `Tests/ShellOutputTests.swift`. In `main()`, add after the ANSI block:

```swift
        // ShellRunner.run — integration smoke (real /bin/zsh)
        await runRunnerSmoke()
```

Convert `main()` to `static func main() async` and the runner suite call style. Replace the `@main struct ShellOutputTestRunner { static func main() {` declaration with:

```swift
@main
struct ShellOutputTestRunner {
    static func main() async {
        // ShellTemplate.substitute
        testSubstituteQuery()
        testSubstituteEcho()
        testSubstituteUnknownPlaceholderLiteral()
        testSubstituteUnicode()
        testSubstituteSelectionAndClipboard()

        // ShellTemplate.hasResolvedSubstantialContent
        testLiteralTemplateAlwaysSubstantial()
        testAllPlaceholdersEmptyNotSubstantial()
        testOneNonEmptyResolutionSubstantial()

        // ANSIStripper.strip
        testStripPassthrough()
        testStripCSIColor()
        testStripCSIMulti()
        testStripOSC()
        testStripBare()

        // ShellRunner.run
        await runRunnerSmoke()

        print("ShellOutputTests passed")
    }
```

Append at the bottom of the struct:

```swift
    static func runRunnerSmoke() async {
        do {
            let ok = try await ShellRunner.run("echo hello", timeout: 5)
            expect(ok.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello",
                   "echo hello stdout mismatch, got: \(ok.stdout)")
            expect(ok.stderr.isEmpty, "echo hello should have no stderr, got: \(ok.stderr)")
            expect(ok.exitCode == 0, "echo hello exitCode mismatch, got: \(ok.exitCode)")
        } catch {
            fail("echo hello threw: \(error)")
        }

        do {
            let bad = try await ShellRunner.run("false", timeout: 5)
            expect(bad.exitCode != 0, "`false` should have non-zero exit, got: \(bad.exitCode)")
        } catch {
            fail("false threw unexpectedly: \(error)")
        }

        // Timeout path
        do {
            _ = try await ShellRunner.run("sleep 3", timeout: 0.5)
            fail("sleep 3 timeout=0.5 should have thrown .timeout")
        } catch ShellRunnerError.timeout {
            // expected
        } catch {
            fail("sleep 3 threw wrong error: \(error)")
        }
    }
```

- [ ] **Step 2: Confirm compile fails**

Run: `swiftc Sources/KeyMic/LLM/PersonaContext.swift Sources/KeyMic/LLM/ContextSource.swift Sources/KeyMic/Output/Shell/ShellTemplate.swift Sources/KeyMic/Output/Shell/ANSIStripper.swift Tests/ShellOutputTests.swift -o /tmp/sot 2>&1 | head -3`

Expected: `cannot find 'ShellRunner' in scope`.

- [ ] **Step 3: Write implementation**

`Sources/KeyMic/Output/Shell/ShellRunner.swift`:

```swift
import Foundation
import os.log

private let shellLogger = Logger(subsystem: "io.keymic.app", category: "ShellRunner")

struct ShellRunResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ShellRunnerError: Error, Equatable {
    case launchFailed(String)
    case timeout
}

/// Pure-ish wrapper around `Process` for `.runShell` injection strategy. Captures
/// stdout + stderr without deadlock by draining both pipes on background queues
/// (the 64 KB pipe buffer otherwise blocks `Process` once full).
///
/// Spec §4.4. Env passthrough strips `KEYMIC_*` keys defensively. cwd = $HOME.
enum ShellRunner {
    static func run(_ command: String, timeout: TimeInterval = 30) async throws -> ShellRunResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShellRunResult, Error>) in
            let process = Process()
            process.launchPath = "/bin/zsh"
            process.arguments = ["-c", command]
            process.currentDirectoryPath = NSHomeDirectory()

            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key.hasPrefix("KEYMIC_") { env.removeValue(forKey: key) }
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle(forReadingAtPath: "/dev/null")

            // Drain pipes on background queues to prevent buffer-full deadlock.
            let stdoutBox = DataBox()
            let stderrBox = DataBox()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; return }
                stdoutBox.append(chunk)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; return }
                stderrBox.append(chunk)
            }

            // Timeout source: cancel the process if we overrun.
            let timeoutSource = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let resumed = ResumedFlag()
            timeoutSource.schedule(deadline: .now() + timeout)
            timeoutSource.setEventHandler {
                if process.isRunning { process.terminate() }
                if resumed.set() {
                    cont.resume(throwing: ShellRunnerError.timeout)
                }
                timeoutSource.cancel()
            }
            timeoutSource.resume()

            process.terminationHandler = { proc in
                timeoutSource.cancel()
                // Final drain — grab anything still buffered.
                stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                let stdout = String(data: stdoutBox.snapshot(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.snapshot(), encoding: .utf8) ?? ""
                let result = ShellRunResult(stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus)
                if resumed.set() {
                    cont.resume(returning: result)
                }
            }

            do {
                try process.run()
                shellLogger.debug("launched pid=\(process.processIdentifier, privacy: .public) timeout=\(timeout, privacy: .public)s")
            } catch {
                timeoutSource.cancel()
                if resumed.set() {
                    cont.resume(throwing: ShellRunnerError.launchFailed(error.localizedDescription))
                }
            }
        }
    }
}

/// Thread-safe data accumulator for pipe drains.
private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// One-shot flag: ensures we only `cont.resume(...)` once across timeout-vs-termination race.
private final class ResumedFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    /// Returns true iff this caller is the first to set the flag.
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
```

- [ ] **Step 4: Update Makefile source list**

```makefile
test-shell-output:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/PersonaContext.swift \
	       Sources/KeyMic/LLM/ContextSource.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellRunner.swift \
	       Tests/ShellOutputTests.swift \
	       -o .build/shell-output-tests
	.build/shell-output-tests
```

- [ ] **Step 5: Run test → green**

Run: `make test-shell-output`

Expected: `ShellOutputTests passed`. (Takes ~1 s including the `sleep 3 / timeout=0.5` smoke.)

- [ ] **Step 6: Build sanity**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/Output/Shell/ShellRunner.swift \
        Tests/ShellOutputTests.swift Makefile
git commit -m "feat(output): add ShellRunner with pipe drain + 30s timeout (LOR-15)"
```

---

## Task 4: `ShellConfirmationSheet.present(command:)` — `NSAlert` with default = Cancel

No unit test — `NSAlert` modal cannot be exercised without a real run loop and a Run/Cancel choice. Manual smoke only.

**Files:**
- Create: `Sources/KeyMic/Output/Shell/ShellConfirmationSheet.swift`

- [ ] **Step 1: Write implementation**

`Sources/KeyMic/Output/Shell/ShellConfirmationSheet.swift`:

```swift
import AppKit
import Foundation

/// Confirmation sheet shown BEFORE every `.runShell` invocation.
/// Default action is Cancel (Esc + Enter both cancel). Cmd+R runs.
/// Spec §4.5.
@MainActor
enum ShellConfirmationSheet {
    static func present(command: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Run shell command?")
            alert.informativeText = String(localized:
                "This command will run in your shell with your full user environment.")

            // Monospace accessory view for the command preview.
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.autohidesScrollers = true

            let textView = NSTextView(frame: scroll.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.string = command
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.autoresizingMask = [.width, .height]
            scroll.documentView = textView
            alert.accessoryView = scroll

            // Button order matters: first button is the default.
            // Spec §4.5: default = Cancel. Run is the second button, keyed to Cmd+R.
            let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
            cancelButton.keyEquivalent = "\r"

            let runButton = alert.addButton(withTitle: String(localized: "Run"))
            runButton.keyEquivalent = "r"
            runButton.keyEquivalentModifierMask = [.command]

            let response = alert.runModal()
            // NSAlert returns .alertFirstButtonReturn for the first added button (Cancel),
            // .alertSecondButtonReturn for Run.
            cont.resume(returning: response == .alertSecondButtonReturn)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`. (No consumer yet — Task 5 wires it.)

- [ ] **Step 3: Manual smoke — no unit test possible**

Defer hands-on verification to Task 5's smoke. This task's smoke is just "compiles + appears in the source tree".

- [ ] **Step 4: Commit**

```bash
git add Sources/KeyMic/Output/Shell/ShellConfirmationSheet.swift
git commit -m "feat(output): add ShellConfirmationSheet NSAlert (default=Cancel, Cmd+R=Run) (LOR-15)"
```

---

## Task 5: Wire `OutputRouter.runShell` arm + `confirmShellRun` constructor param

`OutputRouter.init` does NOT currently accept `confirmShellRun`. Add it as a constructor parameter with a default of `{ _ in false }` so any uninjected caller (tests, defensive paths) cannot accidentally run shell commands.

**Files:**
- Modify: `Sources/KeyMic/Output/OutputRouter.swift`

- [ ] **Step 1: Add the constructor param + stored property**

Find this block in `OutputRouter`:

Before:
```swift
    private let inject: (String) -> Void
    private let readSelection: () -> String?
    private let writeSelection: (String) -> Bool
    private let pasteboard: NSPasteboard
    private let workspace: NSWorkspace
    private let onMarkIgnored: (String) -> Void
```

After:
```swift
    private let inject: (String) -> Void
    private let readSelection: () -> String?
    private let writeSelection: (String) -> Bool
    private let pasteboard: NSPasteboard
    private let workspace: NSWorkspace
    private let onMarkIgnored: (String) -> Void
    /// `.runShell` confirmation gate. Returns true if the user approved. Default is
    /// a safety stub that always returns false — production wires `ShellConfirmationSheet.present`.
    private let confirmShellRun: (String) async -> Bool
```

Find the `init(...)` signature:

Before:
```swift
    init(inject: @escaping (String) -> Void,
         readSelection: @escaping () -> String? = { SelectionTextProvider.currentSelection() },
         writeSelection: @escaping (String) -> Bool = { AXSelectionWriter.write($0) },
         pasteboard: NSPasteboard = .general,
         workspace: NSWorkspace = .shared,
         onMarkIgnored: @escaping (String) -> Void = { _ in }) {
        self.inject = inject
        self.readSelection = readSelection
        self.writeSelection = writeSelection
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.onMarkIgnored = onMarkIgnored
    }
```

After:
```swift
    init(inject: @escaping (String) -> Void,
         readSelection: @escaping () -> String? = { SelectionTextProvider.currentSelection() },
         writeSelection: @escaping (String) -> Bool = { AXSelectionWriter.write($0) },
         pasteboard: NSPasteboard = .general,
         workspace: NSWorkspace = .shared,
         onMarkIgnored: @escaping (String) -> Void = { _ in },
         confirmShellRun: @escaping (String) async -> Bool = { _ in false }) {
        self.inject = inject
        self.readSelection = readSelection
        self.writeSelection = writeSelection
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.onMarkIgnored = onMarkIgnored
        self.confirmShellRun = confirmShellRun
    }
```

- [ ] **Step 2: Replace the `.runShell` stub**

Before (line 143-144):
```swift
        case .runShell:
            return .failed(message: "shell strategy not yet available")
```

After:
```swift
        case .runShell(let commandTemplate):
            return await runShell(template: commandTemplate, output: output)
```

- [ ] **Step 3: Add the private `runShell` method**

Append before the final `}` of the `OutputRouter` class (after `activateOriginatingAppSync`):

```swift
    /// `.runShell` dispatch. Substitutes the template, refuses empty / all-empty-placeholder
    /// commands, asks `confirmShellRun` (cancel → `.userCancelled`), runs `ShellRunner`,
    /// strips ANSI from stdout, then routes through `inject(_:)` (same path as
    /// `.replaceFocusedText`). stderr present (with any exit code) surfaces as `.failed`.
    private func runShell(template: String, output: PersonaOutput) async -> RouteResult {
        guard let substituted = ShellTemplate.substitute(
                template: template, text: output.text, context: output.context) else {
            return .failed(message: "shell template substitution failed")
        }
        let command = substituted.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            return .failed(message: "Empty shell command after substitution")
        }
        guard ShellTemplate.hasResolvedSubstantialContent(
                original: template, resolved: substituted) else {
            return .failed(message: "Refusing to run command with empty placeholders")
        }

        let confirmed = await confirmShellRun(command)
        guard confirmed else {
            routerLogger.debug("runShell user cancelled (length=\(command.count, privacy: .public))")
            return .userCancelled
        }

        do {
            let result = try await ShellRunner.run(command)
            routerLogger.debug("runShell exit=\(result.exitCode, privacy: .public) stdout_len=\(result.stdout.count, privacy: .public) stderr_len=\(result.stderr.count, privacy: .public)")
            let cleanStdout = ANSIStripper.strip(result.stdout)
            if !cleanStdout.isEmpty {
                await activateOriginatingApp(output.originatingApp)
                inject(cleanStdout)
            }
            if !result.stderr.isEmpty {
                routerLogger.error("runShell stderr present exit=\(result.exitCode, privacy: .public)")
                let truncated = result.stderr.count > 200
                    ? String(result.stderr.prefix(200)) + "…"
                    : result.stderr
                return .failed(message: truncated)
            }
            return .injected
        } catch ShellRunnerError.timeout {
            return .failed(message: "shell command timed out after 30s")
        } catch {
            return .failed(message: "shell run failed: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 4: Extend `test-output-router` source list**

Edit the `test-output-router:` block in `Makefile` to include the new shell sources:

Before:
```makefile
test-output-router:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/Persona.swift \
	       Sources/KeyMic/LLM/PersonaContext.swift \
	       Sources/KeyMic/LLM/ContextSource.swift \
	       Sources/KeyMic/LLM/SelectionTextProvider.swift \
	       Sources/KeyMic/LLM/PasteboardSnapshot.swift \
	       Sources/KeyMic/LLM/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/OutputRouterTests.swift \
	       -o .build/output-router-tests
	.build/output-router-tests
```

After:
```makefile
test-output-router:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/Persona.swift \
	       Sources/KeyMic/LLM/PersonaContext.swift \
	       Sources/KeyMic/LLM/ContextSource.swift \
	       Sources/KeyMic/LLM/SelectionTextProvider.swift \
	       Sources/KeyMic/LLM/PasteboardSnapshot.swift \
	       Sources/KeyMic/LLM/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellRunner.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/OutputRouterTests.swift \
	       -o .build/output-router-tests
	.build/output-router-tests
```

- [ ] **Step 5: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 6: Existing output-router tests still pass**

Run: `make test-output-router`

Expected: `OutputRouterTests passed` (existing tests; the `.runShell` cases are added in Task 13).

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/Output/OutputRouter.swift Makefile
git commit -m "feat(output): wire OutputRouter.runShell arm + confirmShellRun gate (LOR-15)"
```

---

## Task 6: AppDelegate injects real `confirmShellRun` closure

The default `confirmShellRun = { _ in false }` is a deliberate safety stub. Production replaces it with the actual `ShellConfirmationSheet.present` call.

**Files:**
- Modify: `Sources/KeyMic/AppDelegate.swift`

- [ ] **Step 1: Update `OutputRouter.shared` construction**

Find the existing call (around line 155):

Before:
```swift
        OutputRouter.shared = OutputRouter(
            inject: { [weak self] text in self?.textInjector.inject(text) },
            onMarkIgnored: { [weak self] text in
                self?.clipboardController.markPasteboardWrite(text)
            })
```

After:
```swift
        OutputRouter.shared = OutputRouter(
            inject: { [weak self] text in self?.textInjector.inject(text) },
            onMarkIgnored: { [weak self] text in
                self?.clipboardController.markPasteboardWrite(text)
            },
            confirmShellRun: { command in
                await ShellConfirmationSheet.present(command: command)
            })
```

- [ ] **Step 2: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 3: Manual smoke — sheet appears, default = Cancel, Cmd+R runs**

Launch `KeyMic.app`. Temporarily route a persona to `.runShell(commandTemplate: "echo hello")` via Settings (or wait for Task 10 to flip `builtin-cli`). Trigger it. Verify:

- Sheet appears with monospace `echo hello` preview.
- Pressing **Enter** → sheet closes with no execution. (Default button = Cancel.)
- Pressing **Esc** → same.
- Pressing **Cmd+R** → `echo hello` runs; `hello\n` is injected into the focused field.

If any of these are wrong, fix `ShellConfirmationSheet.present` before continuing.

- [ ] **Step 4: Commit**

```bash
git add Sources/KeyMic/AppDelegate.swift
git commit -m "feat(output): AppDelegate wires ShellConfirmationSheet into OutputRouter (LOR-15)"
```

---

## Task 7: `ITermAvailability.isInstalled()` pure helper

Trivial — `NSWorkspace.urlForApplication(withBundleIdentifier:)`. Can't unit-test the production path without iTerm installed in CI, so we only verify the file compiles and the path of integration in Task 9.

**Files:**
- Create: `Sources/KeyMic/Output/iTerm/ITermAvailability.swift`

- [ ] **Step 1: Write implementation**

`Sources/KeyMic/Output/iTerm/ITermAvailability.swift`:

```swift
import AppKit
import Foundation

/// Bundle-presence probe for iTerm 2. Used by `OutputRouter.writeToITerm` to short-circuit
/// with a clean error message when iTerm isn't installed.
///
/// We deliberately do NOT probe the Automation TCC state here — there is no public API
/// for that, and the first AppleScript dispatch triggers the prompt natively.
enum ITermAvailability {
    static let bundleID: String = "com.googlecode.iterm2"

    static func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
```

- [ ] **Step 2: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 3: Manual smoke (no unit test — environmental)**

If iTerm is installed: `ITermAvailability.isInstalled() == true`.
If `mv /Applications/iTerm.app /Applications/iTerm.app.disabled` (don't actually do this — just note the expected behavior): would return `false`.

- [ ] **Step 4: Commit**

```bash
git add Sources/KeyMic/Output/iTerm/ITermAvailability.swift
git commit -m "feat(output): add ITermAvailability bundle probe (LOR-15)"
```

---

## Task 8: `ITermBridge.write(text:paneIndex:)` (NSAppleScript + permission mapping)

No unit test — AppleScript dispatch + Automation permission flow cannot be exercised without a real iTerm process. Manual smoke matrix only.

**Files:**
- Create: `Sources/KeyMic/Output/iTerm/ITermBridge.swift`

- [ ] **Step 1: Write implementation**

`Sources/KeyMic/Output/iTerm/ITermBridge.swift`:

```swift
import AppKit
import Foundation
import os.log

private let itermLogger = Logger(subsystem: "io.keymic.app", category: "ITermBridge")

/// AppleScript bridge to iTerm 2. Spec §5.4.
///
/// AppleScript chosen over the iTerm Python API to keep the integration zero-setup —
/// the Python API requires installing a Python runtime and enabling iTerm's API setting.
enum ITermBridge {
    enum Error: Swift.Error, Equatable {
        case permissionDenied            // NSAppleScriptErrorNumber == -1743
        case appleScriptFailed(String)
        case iTermNotRunning             // returned "no-window" sentinel from script
        case paneOutOfRange              // returned "out-of-range" sentinel
        case noActiveWindow              // alias kept for spec parity with .iTermNotRunning
    }

    @MainActor
    static func write(text: String, paneIndex: Int) async throws {
        let escaped = escapeForAppleScript(text)
        // Pane index +1 because AppleScript is 1-indexed.
        let scriptSource = """
        tell application "iTerm"
            if (count of windows) = 0 then
                return "no-window"
            end if
            tell current window
                set sessionList to sessions
                if (count of sessionList) < \(paneIndex + 1) then
                    return "out-of-range"
                end if
                tell item \(paneIndex + 1) of sessionList
                    write text "\(escaped)"
                end tell
            end tell
            return "ok"
        end tell
        """

        guard let script = NSAppleScript(source: scriptSource) else {
            throw Error.appleScriptFailed("NSAppleScript init returned nil")
        }
        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if let errorDict = errorDict as? [String: Any] {
            if let code = errorDict["NSAppleScriptErrorNumber"] as? Int, code == -1743 {
                itermLogger.error("iTerm AppleScript denied (errAEEventNotPermitted)")
                throw Error.permissionDenied
            }
            let message = (errorDict["NSAppleScriptErrorMessage"] as? String) ?? "unknown"
            itermLogger.error("iTerm AppleScript failed: \(message, privacy: .public)")
            throw Error.appleScriptFailed(message)
        }
        let sentinel = descriptor.stringValue ?? "ok"
        switch sentinel {
        case "no-window":     throw Error.iTermNotRunning
        case "out-of-range":  throw Error.paneOutOfRange
        default: break
        }
        itermLogger.debug("iTerm write pane=\(paneIndex, privacy: .public) length=\(text.count, privacy: .public)")
    }

    /// Escapes for embedding in an AppleScript string literal.
    /// - `\` → `\\`
    /// - `"` → `\"`
    /// - newline → `" & return & "`
    static func escapeForAppleScript(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\" & return & \"")
            default:   out.append(ch)
            }
        }
        return out
    }
}
```

- [ ] **Step 2: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`. (No consumer yet — Task 9.)

- [ ] **Step 3: Manual smoke deferred to Task 9** — `ITermBridge` has no consumer until then.

- [ ] **Step 4: Commit**

```bash
git add Sources/KeyMic/Output/iTerm/ITermBridge.swift
git commit -m "feat(output): add ITermBridge AppleScript dispatch (LOR-15)"
```

---

## Task 9: Wire `OutputRouter.writeToITermPane` arm

**Files:**
- Modify: `Sources/KeyMic/Output/OutputRouter.swift`

- [ ] **Step 1: Replace the `.writeToITermPane` stub**

Before:
```swift
        case .writeToITermPane:
            return .failed(message: "iterm strategy not yet available")
```

After:
```swift
        case .writeToITermPane(let paneIndex):
            return await writeToITerm(paneIndex: paneIndex, text: output.text)
```

- [ ] **Step 2: Add the private method**

Append after `runShell(...)`:

```swift
    /// `.writeToITermPane` dispatch. Spec §5.2.
    private func writeToITerm(paneIndex: Int, text: String) async -> RouteResult {
        guard ITermAvailability.isInstalled() else {
            return .failed(message: "iTerm 2 is not installed")
        }
        do {
            try await ITermBridge.write(text: text, paneIndex: paneIndex)
            return .injected
        } catch ITermBridge.Error.permissionDenied {
            return .failed(message: "Automation permission for iTerm 2 is required (System Settings → Privacy & Security → Automation → KeyMic)")
        } catch ITermBridge.Error.iTermNotRunning {
            return .failed(message: "iTerm 2 has no open window")
        } catch ITermBridge.Error.paneOutOfRange {
            return .failed(message: "iTerm pane index out of range")
        } catch {
            return .failed(message: "iTerm write failed: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 3: Extend `test-output-router` source list with iTerm sources**

```makefile
test-output-router:
	mkdir -p .build
	swiftc Sources/KeyMic/LLM/Persona.swift \
	       Sources/KeyMic/LLM/PersonaContext.swift \
	       Sources/KeyMic/LLM/ContextSource.swift \
	       Sources/KeyMic/LLM/SelectionTextProvider.swift \
	       Sources/KeyMic/LLM/PasteboardSnapshot.swift \
	       Sources/KeyMic/LLM/SelectionCopyWait.swift \
	       Sources/KeyMic/Output/Shell/ShellTemplate.swift \
	       Sources/KeyMic/Output/Shell/ANSIStripper.swift \
	       Sources/KeyMic/Output/Shell/ShellRunner.swift \
	       Sources/KeyMic/Output/iTerm/ITermAvailability.swift \
	       Sources/KeyMic/Output/iTerm/ITermBridge.swift \
	       Sources/KeyMic/Output/OutputRouter.swift \
	       Tests/OutputRouterTests.swift \
	       -o .build/output-router-tests
	.build/output-router-tests
```

- [ ] **Step 4: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 5: Manual smoke (iTerm matrix)**

If iTerm is installed:
- Create / pick a persona with `.writeToITermPane(paneIndex: 0)`. Trigger voice → text writes into pane 0.
- First-time dispatch should trigger macOS's Automation prompt for KeyMic → iTerm.
- After denying Automation in System Settings → Privacy & Security → Automation → KeyMic, next dispatch must surface `.failed(message: "Automation permission for iTerm 2 is required...")`.
- With `paneIndex = 9` and only one pane open → `.failed("iTerm pane index out of range")`.

If iTerm is NOT installed (rare on dev machine — `mv` it aside or test on a clean machine):
- Same dispatch → `.failed("iTerm 2 is not installed")`. AppleScript never invoked.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/Output/OutputRouter.swift Makefile
git commit -m "feat(output): wire OutputRouter.writeToITermPane arm (LOR-15)"
```

---

## Task 10: Flip `builtin-cli` seed to `.runShell(commandTemplate: "{query}")`

**Files:**
- Modify: `Sources/KeyMic/LLM/Persona.swift`
- Modify: `Tests/PersonaTests.swift`
- Modify: `Tests/PersonaInjectionStrategyTests.swift`

- [ ] **Step 1: Update the seed**

Edit `Sources/KeyMic/LLM/Persona.swift`. Locate the `builtin-cli` entry (around line 122).

Before:
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
                createdAt: now,
                updatedAt: now
            ),
```

After:
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
                createdAt: now,
                updatedAt: now,
                injectionStrategy: .runShell(commandTemplate: "{query}")
            ),
```

- [ ] **Step 2: Update `Tests/PersonaTests.swift`**

Locate the assertion for `seeds[2]` (the cli persona). Add (or replace existing default-strategy expectation):

```swift
        expect(seeds[2].id == "builtin-cli", "third seed is builtin-cli")
        expect(seeds[2].injectionStrategy == .runShell(commandTemplate: "{query}"),
               "builtin-cli persona uses .runShell({query})")
```

- [ ] **Step 3: Update `Tests/PersonaInjectionStrategyTests.swift`**

In `testBuiltInSeedsHaveCanonicalStrategy`, find the `expected` dictionary entry for `"builtin-cli"` (currently `.replaceFocusedText`). Change to:

```swift
            "builtin-cli": .runShell(commandTemplate: "{query}"),
```

- [ ] **Step 4: Run dependent tests**

Run: `make test-persona test-persona-injection-strategy 2>&1 | grep -E "passed|FAIL|❌"`

Expected: both passed.

- [ ] **Step 5: Build sanity**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/LLM/Persona.swift \
        Tests/PersonaTests.swift \
        Tests/PersonaInjectionStrategyTests.swift
git commit -m "feat(persona): flip builtin-cli to .runShell({query}) (LOR-15)"
```

---

## Task 11: `PersonaStore.mergeWithBuiltIns` promotes `injectionStrategy` on built-ins

Existing installs have `builtin-cli.injectionStrategy = .replaceFocusedText` on disk. Without a migration, the JSON value silently wins and the new shell strategy never activates for upgraders. Fix: copy `injectionStrategy` from the seed onto every loaded built-in. User-edited custom personas are untouched (the `if existing` branch only fires for built-ins).

**Files:**
- Modify: `Sources/KeyMic/LLM/PersonaStore.swift`
- Modify: `Tests/PersonaStoreTests.swift`

- [ ] **Step 1: Write the migration test**

In `Tests/PersonaStoreTests.swift`, append a new test method and call it from `main()`:

```swift
    static func testBuiltinCliInjectionStrategyPromotedOnMerge() {
        // Simulate an existing user whose personas.json has the OLD strategy on disk.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keymic-persona-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let storeURL = tmpDir.appendingPathComponent("personas.json")

        let legacyJSON = """
        {
          "version": 1,
          "personas": [
            {
              "builtIn": true,
              "contextSources": [],
              "createdAt": "2024-01-01T00:00:00.000Z",
              "icon": "terminal",
              "id": "builtin-cli",
              "injectionStrategy": { "replaceFocusedText": {} },
              "name": "CLI Wizard",
              "stylePrompt": "USER EDITED PROMPT",
              "temperature": 0.2,
              "updatedAt": "2024-01-01T00:00:00.000Z"
            }
          ],
          "activePersonaId": null
        }
        """
        try? legacyJSON.write(to: storeURL, atomically: true, encoding: .utf8)

        let store = PersonaStore(storeURL: storeURL)
        guard let cli = store.persona(id: "builtin-cli") else {
            fail("builtin-cli missing after merge"); return
        }
        expect(cli.injectionStrategy == .runShell(commandTemplate: "{query}"),
               "merge must promote builtin-cli.injectionStrategy to .runShell({query})")
        // User-editable fields must be preserved.
        expect(cli.stylePrompt == "USER EDITED PROMPT",
               "user-edited stylePrompt must survive the merge")
        expect(cli.temperature == 0.2, "user-edited temperature must survive the merge")
    }
```

(If `Tests/PersonaStoreTests.swift` uses a different `expect`/`fail` convention, mirror its existing style — see the LOR-19 plan Task 3 for the surrounding test runner pattern.)

- [ ] **Step 2: Confirm test fails**

Run: `make test-persona-store 2>&1 | tail -5`

Expected: `FAIL: merge must promote builtin-cli.injectionStrategy to .runShell({query})` (or similar).

- [ ] **Step 3: Update `mergeWithBuiltIns`**

Edit `Sources/KeyMic/LLM/PersonaStore.swift`.

Before:
```swift
    /// Ensures all 4 built-ins exist (preserves user edits to existing built-ins;
    /// adds any built-in seed not yet on disk). Custom personas pass through unchanged.
    private func mergeWithBuiltIns(loaded: [Persona]) -> [Persona] {
        let seeds = Persona.builtInSeeds()
        var result: [Persona] = []
        for seed in seeds {
            if let existing = loaded.first(where: { $0.id == seed.id }) {
                result.append(existing)
            } else {
                result.append(seed)
            }
        }
        let builtInIds = Set(seeds.map(\.id))
        result.append(contentsOf: loaded.filter { !builtInIds.contains($0.id) })
        return result
    }
```

After:
```swift
    /// Ensures every built-in seed exists. For each existing built-in, preserves user-editable
    /// fields (stylePrompt, icon, temperature, hotkey, contextSources) but **promotes
    /// `injectionStrategy` from the seed** — built-ins' destination is part of their identity,
    /// not user-editable. This is what migrates legacy `builtin-cli.injectionStrategy =
    /// .replaceFocusedText` installs onto the new `.runShell({query})` strategy without losing
    /// the user's stylePrompt edits.
    private func mergeWithBuiltIns(loaded: [Persona]) -> [Persona] {
        let seeds = Persona.builtInSeeds()
        var result: [Persona] = []
        for seed in seeds {
            if var existing = loaded.first(where: { $0.id == seed.id }) {
                // Built-in identity fields (incl. injectionStrategy) follow the seed.
                existing.injectionStrategy = seed.injectionStrategy
                result.append(existing)
            } else {
                result.append(seed)
            }
        }
        let builtInIds = Set(seeds.map(\.id))
        result.append(contentsOf: loaded.filter { !builtInIds.contains($0.id) })
        return result
    }
```

- [ ] **Step 4: Run test → green**

Run: `make test-persona-store 2>&1 | tail -5`

Expected: `PersonaStoreTests passed`.

- [ ] **Step 5: Build sanity**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add Sources/KeyMic/LLM/PersonaStore.swift Tests/PersonaStoreTests.swift
git commit -m "feat(persona): promote injectionStrategy from seed on merge (LOR-15)"
```

---

## Task 12: `PersonasView` — `InjectionStrategy` picker + per-arm editors + built-in lock

The current `PersonasView` (`Sources/KeyMic/SettingsUI/PersonasView.swift`) does NOT yet render an injection-strategy editor. Add one. Spec §6.

**Files:**
- Modify: `Sources/KeyMic/SettingsUI/PersonasView.swift`

- [ ] **Step 1: Add a strategy-kind enum + helper bindings**

At the top of `PersonasView.swift` (after the file's imports), add a small mapping helper. The point: SwiftUI `Picker` needs a `Hashable` selection, and `InjectionStrategy` has associated values that break direct `Picker` use. Map to a stable `case-kind` enum.

```swift
private enum InjectionStrategyKind: String, CaseIterable, Identifiable {
    case replaceFocusedText
    case replaceSelection
    case clipboard
    case openURL
    case runShell
    case writeToITermPane

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .replaceFocusedText: return String(localized: "Replace focused text (paste)")
        case .replaceSelection:   return String(localized: "Replace selection (AX)")
        case .clipboard:          return String(localized: "Copy to clipboard")
        case .openURL:            return String(localized: "Open URL")
        case .runShell:           return String(localized: "Run shell command")
        case .writeToITermPane:   return String(localized: "Write to iTerm pane")
        }
    }

    init(_ strategy: InjectionStrategy) {
        switch strategy {
        case .replaceFocusedText: self = .replaceFocusedText
        case .replaceSelection:   self = .replaceSelection
        case .clipboard:          self = .clipboard
        case .openURL:            self = .openURL
        case .runShell:           self = .runShell
        case .writeToITermPane:   self = .writeToITermPane
        }
    }

    /// Produce a fresh `InjectionStrategy` with sensible defaults when the picker
    /// switches arms. Existing associated values are LOST when switching arms — by design.
    func defaultStrategy() -> InjectionStrategy {
        switch self {
        case .replaceFocusedText: return .replaceFocusedText
        case .replaceSelection:   return .replaceSelection
        case .clipboard:          return .clipboard
        case .openURL:            return .openURL(template: "https://www.google.com/search?q={query}")
        case .runShell:           return .runShell(commandTemplate: "{query}")
        case .writeToITermPane:   return .writeToITermPane(paneIndex: 0)
        }
    }
}
```

- [ ] **Step 2: Add the editor section after the Context label**

Find the `// Context sources (read-only label; multi-select editor is a follow-up)` block (around line 181-185). After it, but before the `if persona.builtIn { ... }` block, insert:

```swift
                // Injection strategy (Output destination)
                FieldLabel("Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Strategy", selection: Binding<InjectionStrategyKind>(
                            get: { InjectionStrategyKind(persona.injectionStrategy) },
                            set: { newKind in
                                guard !persona.builtIn else { return }
                                model.setInjectionStrategy(newKind.defaultStrategy(), for: persona)
                            }
                        )) {
                            ForEach(InjectionStrategyKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .disabled(persona.builtIn)
                        .help(persona.builtIn
                              ? String(localized: "Built-in personas have a fixed output strategy.")
                              : String(localized: "Where to send the model's output."))

                        injectionStrategyEditor(for: persona)
                    }
                }
```

- [ ] **Step 3: Add per-arm editor view**

Inside the same view struct, append (before `contextSourcesDescription`):

```swift
    @ViewBuilder
    private func injectionStrategyEditor(for persona: Persona) -> some View {
        switch persona.injectionStrategy {
        case .openURL(let template):
            VStack(alignment: .leading, spacing: 4) {
                TextField("URL template", text: Binding<String>(
                    get: { template },
                    set: { new in
                        guard !persona.builtIn else { return }
                        model.setInjectionStrategy(.openURL(template: new), for: persona)
                    }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(persona.builtIn)
                Text("Placeholders: {query} {selection} {clipboard}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .runShell(let commandTemplate):
            VStack(alignment: .leading, spacing: 4) {
                TextField("Command template", text: Binding<String>(
                    get: { commandTemplate },
                    set: { new in
                        guard !persona.builtIn else { return }
                        model.setInjectionStrategy(.runShell(commandTemplate: new), for: persona)
                    }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(persona.builtIn)
                Text("Placeholders: {query} {selection} {clipboard}. A confirmation sheet shows on every run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .writeToITermPane(let paneIndex):
            HStack {
                Text("Pane index:")
                Stepper(value: Binding<Int>(
                    get: { paneIndex },
                    set: { new in
                        guard !persona.builtIn else { return }
                        let clamped = max(0, min(9, new))
                        model.setInjectionStrategy(.writeToITermPane(paneIndex: clamped), for: persona)
                    }), in: 0...9) {
                    Text("\(paneIndex)")
                        .frame(width: 24, alignment: .trailing)
                        .monospacedDigit()
                }
                .disabled(persona.builtIn)
                Spacer()
            }

        case .replaceFocusedText, .replaceSelection, .clipboard:
            EmptyView()
        }
    }
```

- [ ] **Step 4: Add the `setInjectionStrategy` model method**

Find `PersonaEditModel` (the view model holding the `binding(\.foo, for:)` machinery — likely around line 415-440 per the grep output). Add:

```swift
    func setInjectionStrategy(_ strategy: InjectionStrategy, for persona: Persona) {
        update(persona) { p in p.injectionStrategy = strategy }
    }
```

(Mirror the existing `setTemperature` shape — read 5 lines around `p.temperature = value` (line 440) to match the exact `update`/closure shape used in this codebase.)

- [ ] **Step 5: Build**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 6: Manual smoke**

Open Settings → Personas:
- `builtin-cli` Output picker shows "Run shell command" and is **disabled** (greyed). Hovering shows the tooltip "Built-in personas have a fixed output strategy."
- Command template field shows `{query}`, also disabled.
- Create a custom persona via "Duplicate". Switch its strategy to "Run shell command" — template field appears and is editable. Switch to "Write to iTerm pane" — stepper appears, range 0-9.

- [ ] **Step 7: Commit**

```bash
git add Sources/KeyMic/SettingsUI/PersonasView.swift
git commit -m "feat(persona-ui): add InjectionStrategy editor with .runShell + .writeToITermPane arms (LOR-15)"
```

---

## Task 13: `OutputRouter` integration tests for new code paths

Cover the three router decision points with stubs: cancelled, stdout-only success, stderr-failure for `.runShell`; "not installed" early-return for `.writeToITermPane`. The actual `Process` / `NSAppleScript` calls cannot be reached from a test runner — we stub them out by injecting fake closures into a small `OutputRouter` test fixture.

**Note:** `OutputRouter.runShell` calls `ShellRunner.run` directly (not through a closure). To make `.runShell` testable, we either (a) introduce a `runShellExecutor: (String) async throws -> ShellRunResult` constructor parameter, or (b) write the integration tests to actually invoke the real ShellRunner with safe commands. We choose **(a)** — clean test seam, mirrors `openURLHandler`.

**Files:**
- Modify: `Sources/KeyMic/Output/OutputRouter.swift` (add `runShellExecutor` test seam)
- Modify: `Tests/OutputRouterTests.swift`

- [ ] **Step 1: Add `runShellExecutor` test seam**

Edit `Sources/KeyMic/Output/OutputRouter.swift`. After the `var openURLHandler:` declaration, add:

```swift
    /// Test injection point — overrides `ShellRunner.run(_:)`. Production default delegates
    /// to the real runner with the default 30 s timeout.
    var runShellExecutor: ((String) async throws -> ShellRunResult)?
```

In `runShell(template:output:)`, replace:

```swift
            let result = try await ShellRunner.run(command)
```

with:

```swift
            let result: ShellRunResult
            if let executor = runShellExecutor {
                result = try await executor(command)
            } else {
                result = try await ShellRunner.run(command)
            }
```

- [ ] **Step 2: Add tests**

In `Tests/OutputRouterTests.swift`, append:

```swift
    static func testRunShellCancelledByUser() async {
        let router = OutputRouter(
            inject: { _ in fail("inject must not run when user cancelled") },
            confirmShellRun: { _ in false }
        )
        var injectedText: String? = nil
        router.runShellExecutor = { _ in
            fail("ShellRunner must not run when user cancelled")
            return ShellRunResult(stdout: "", stderr: "", exitCode: 0)
        }
        _ = injectedText  // silence unused-warning across compilers
        let output = PersonaOutput(
            text: "ls",
            strategy: .runShell(commandTemplate: "{query}"),
            originatingApp: nil,
            context: nil
        )
        let result = await router.route(output)
        expect(result == .userCancelled, "cancelled run must return .userCancelled, got: \(result)")
    }

    static func testRunShellSuccessInjectsStdout() async {
        var injected: String? = nil
        let router = OutputRouter(
            inject: { text in injected = text },
            confirmShellRun: { _ in true }
        )
        router.runShellExecutor = { command in
            expect(command == "ls", "command after substitution mismatch: \(command)")
            return ShellRunResult(stdout: "\u{001B}[32mok\u{001B}[0m\n", stderr: "", exitCode: 0)
        }
        let output = PersonaOutput(
            text: "ls",
            strategy: .runShell(commandTemplate: "{query}"),
            originatingApp: nil,
            context: nil
        )
        let result = await router.route(output)
        expect(result == .injected, "expected .injected, got: \(result)")
        expect(injected == "ok\n", "ANSI not stripped before inject; got: \(injected ?? "nil")")
    }

    static func testRunShellStderrPathReturnsFailed() async {
        let router = OutputRouter(
            inject: { _ in fail("inject must not be called on stderr path") },
            confirmShellRun: { _ in true }
        )
        router.runShellExecutor = { _ in
            ShellRunResult(stdout: "", stderr: "no such file or directory", exitCode: 1)
        }
        let output = PersonaOutput(
            text: "ls",
            strategy: .runShell(commandTemplate: "{query}"),
            originatingApp: nil,
            context: nil
        )
        let result = await router.route(output)
        if case .failed(let msg) = result {
            expect(msg.contains("no such file"),
                   "failed message should contain stderr; got: \(msg)")
        } else {
            fail("expected .failed, got: \(result)")
        }
    }

    static func testRunShellEmptyPlaceholderRefused() async {
        let router = OutputRouter(
            inject: { _ in fail("inject must not be called when refusing empty placeholders") },
            confirmShellRun: { _ in
                fail("confirm must not be reached when refusing empty placeholders")
                return false
            }
        )
        router.runShellExecutor = { _ in
            fail("ShellRunner must not run when refusing empty placeholders")
            return ShellRunResult(stdout: "", stderr: "", exitCode: 0)
        }
        // Template has {selection} but PersonaContext has no selection → all-empty.
        let ctx = PersonaContext(selection: "", clipboardTop: nil, clipboardHistory: nil)
        let output = PersonaOutput(
            text: "",
            strategy: .runShell(commandTemplate: "rm -rf {selection}"),
            originatingApp: nil,
            context: ctx
        )
        let result = await router.route(output)
        if case .failed(let msg) = result {
            expect(msg.contains("empty placeholders"),
                   "expected empty-placeholder refusal, got: \(msg)")
        } else {
            fail("expected .failed, got: \(result)")
        }
    }

    static func testWriteToITermWhenNotInstalled() async {
        // Cannot easily stub ITermAvailability without making it injectable. Document the
        // expected behavior on a machine WITHOUT iTerm; on dev machines this test is a
        // best-effort smoke that asserts the early-return contract via the code path.
        // If iTerm IS installed, the test routes into ITermBridge and we skip the
        // assertion (manual smoke matrix covers the installed case).
        guard !ITermAvailability.isInstalled() else { return }

        let router = OutputRouter(
            inject: { _ in fail("inject must not be called for iTerm strategy") }
        )
        let output = PersonaOutput(
            text: "echo hi",
            strategy: .writeToITermPane(paneIndex: 0),
            originatingApp: nil,
            context: nil
        )
        let result = await router.route(output)
        if case .failed(let msg) = result {
            expect(msg.contains("not installed"), "expected not-installed message, got: \(msg)")
        } else {
            fail("expected .failed when iTerm absent, got: \(result)")
        }
    }
```

Call each new test from the test runner's `main()` (or whichever dispatch list the existing `OutputRouterTests.swift` uses — match the existing pattern, e.g. `await testRunShellCancelledByUser()`).

- [ ] **Step 3: Run tests**

Run: `make test-output-router 2>&1 | tail -5`

Expected: `OutputRouterTests passed`.

- [ ] **Step 4: Build sanity**

Run: `make build 2>&1 | grep -E "error:|Build complete"`

Expected: `Build complete!`.

- [ ] **Step 5: Commit**

```bash
git add Sources/KeyMic/Output/OutputRouter.swift Tests/OutputRouterTests.swift
git commit -m "test(output): cover .runShell + .writeToITermPane routing paths (LOR-15)"
```

---

## Task 14: Final verification — `make test-all` + manual smoke matrix

- [ ] **Step 1: Clean rebuild**

Run: `make clean && make build 2>&1 | tail -3`

Expected: `Build complete!`.

- [ ] **Step 2: Full test suite**

Run: `script -q /dev/null make test-all 2>&1 | tail -5`

Expected: every runner prints `… passed` and the final `✅ All tests passed`.

- [ ] **Step 3: Manual smoke matrix (spec §8)**

Walk every row of the matrix in `docs/persona-platform/2026-05-23-lor-15-shell-and-iterm-output.md` §8 against a running `KeyMic.app`. Check each:

- [ ] CLI Wizard + "list files" → sheet shows `ls` (or similar). Click Run → output pastes into focused field.
- [ ] Same → click Cancel → nothing happens; voice session ends silently.
- [ ] Sheet open + Esc → cancels.
- [ ] Sheet open + Enter → cancels (default = Cancel).
- [ ] Sheet open + Cmd+R → runs.
- [ ] Long-running command (`sleep 60`) + confirm → times out at 30 s, error toast / `.failed`.
- [ ] Large stdout (`yes | head -n 50000`) + confirm → all injected; no pipe deadlock.
- [ ] Persona with `{selection}` template, no selection → `.failed("Refusing to run command with empty placeholders")`. Sheet NEVER shown.
- [ ] Persona `.writeToITermPane`, iTerm NOT installed → `.failed("iTerm 2 is not installed")`.
- [ ] iTerm installed, Automation NOT granted → first prompt appears; on grant, write succeeds.
- [ ] Automation explicitly denied (System Settings) → `.failed` with "Automation permission for iTerm 2 is required…".
- [ ] `paneIndex = 5` + only 2 panes open → `.failed("iTerm pane index out of range")`.
- [ ] Existing install: launch app, inspect `~/Library/Application Support/KeyMic/personas.json` — `builtin-cli.injectionStrategy` is the new `runShell` shape AND user's `stylePrompt` edits survived.

- [ ] **Step 4: Acceptance criteria walk (spec §11)**

Every item in `docs/persona-platform/2026-05-23-lor-15-shell-and-iterm-output.md` §11 must be checkable. Tick each in the spec or in the PR description.

- [ ] **Step 5: Logging sanity**

In the Console.app, filter on `subsystem == io.keymic.app && category == OutputRouter || category == ShellRunner || category == ITermBridge`. Trigger a `.runShell` confirm-and-run. Verify:

- No log line contains the command body (only `length=` / `count=`).
- No log line contains the stdout body (only `stdout_len=`).
- No log line contains the injected text body.

If any of those leak, fix the offending `Logger.debug/error` call's privacy annotation to `.private` before shipping.

- [ ] **Step 6: Final commit (only if any docs / tweaks made during smoke)**

```bash
# Only if changes happened during smoke; otherwise skip this commit.
git add -A
git commit -m "chore(output): smoke-pass cleanups for LOR-15"
```

---

## Notes for the implementer

- **`OutputRouter` is `@MainActor`** — `ShellConfirmationSheet.present` and `ITermBridge.write` are too. Don't try to call them from background queues.
- **`ShellRunner.run` is NOT `@MainActor`** — `Process` blocks on its termination handler which runs on a background queue. Awaiting it from `@MainActor` code works because `withCheckedThrowingContinuation` jumps the boundary.
- **`Process` + pipe drain** — every `Process` consumer in this codebase that captures large stdout MUST drain via `readabilityHandler`, not `readDataToEndOfFile()` alone. The 64 KB pipe buffer otherwise wedges. The pattern is in `ShellRunner.swift`.
- **AppleScript escaping is fiddly** — `escapeForAppleScript` handles backslash, double-quote, newline. If your persona's text contains tabs, control characters, or non-BMP unicode, AppleScript may render them oddly. Out of scope for P3; broader escaping can come later.
- **Automation permission** — first AppleScript dispatch triggers the macOS prompt natively. KeyMic's `Info.plist` does NOT need an `NSAppleEventsUsageDescription` for AppleScript-to-iTerm; the OS uses the target app's bundle metadata. If users see "operation not permitted" repeatedly, point them at System Settings → Privacy & Security → Automation → KeyMic.
- **Default = Cancel is unusual** — `NSAlert`'s first button is the default. We add Cancel first (with `keyEquivalent = "\r"`), then Run (with Cmd+R). Don't reorder.
- **Migration is one-way** — once a user's `builtin-cli.injectionStrategy` flips to `.runShell`, downgrading KeyMic won't re-migrate to `.replaceFocusedText`. Acceptable; we don't support downgrades.
- **`runShellExecutor` test seam** is an `Optional` instance property, NOT a constructor parameter, to keep the production init signature minimal. Mirrors `openURLHandler`.
- **No `Tests/PersonaInjectionStrategyTests.swift` count change** — the seed count stays at 6 (LOR-19 added the clipboard-transformer; this plan only flips `builtin-cli`'s strategy). If the LOR-19 plan hasn't shipped yet and the count is 5, that's a separate plan's concern; this plan does not assert the seed count.
- **Commits each independently build + test green.** Tasks 1 + 2 + 3 leave the app fully functional (no consumer yet). Task 5 wires the router but `confirmShellRun` defaults to `false`, so accidentally-triggering a `.runShell` persona before Task 6 just shows `.userCancelled`. Task 11 (mergeWithBuiltIns) is gated by Task 10's seed change but they're separate commits for clarity.
