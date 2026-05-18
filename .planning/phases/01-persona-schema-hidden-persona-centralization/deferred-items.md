# Deferred Items — Phase 01

Items discovered during execution that are OUT OF SCOPE for the current plan
(Rule: scope boundary — only auto-fix issues DIRECTLY caused by the current
task's changes). These are recorded here for future planning attention.

## From Plan 01-04 (2026-05-18)

### test-hotkey-action-runner is broken (pre-existing, NOT introduced by 01-04)

- **Where:** `Makefile` — rule `test-hotkey-action-runner:` (currently lines ~227–233)
  and `Sources/KeyMic/Hotkey/HotkeyActionRunner.swift:23`
- **Symptom:** `make test-hotkey-action-runner` exits non-zero with
  `error: cannot find 'ShellRunner' in scope` at HotkeyActionRunner.swift:23.
- **Root cause:** `HotkeyActionRunner.swift` references `ShellRunner.shared.run(...)`
  in a default-argument closure, but the swiftc source list in the Make rule
  omits `Sources/KeyMic/Tools/Shell/ShellRunner.swift` (and its dependencies
  `ShellSnapshot.swift`, `ShellLogger.swift`).
- **Impact:** `make test-all` cannot exit 0 today because it includes
  `test-hotkey-action-runner` in its target list. Plan 01-04's success criterion
  "`make test-all` exits 0" is gated on this pre-existing failure.
- **Verified pre-existing:** the failure reproduces on the Phase-1 base commit
  `2c1bf82e` and on Wave 3-01 (`56263a5`) — predates Plan 01-04 entirely. The
  Plan 01-04 changes (adding `test-persona-hidden` rule + appending to `test-all`)
  do not affect `test-hotkey-action-runner`.
- **Fix sketch (for a future cleanup plan):** extend the rule's swiftc source list
  to include `Sources/KeyMic/Tools/Shell/ShellRunner.swift`,
  `Sources/KeyMic/Tools/Shell/ShellSnapshot.swift`, and
  `Sources/KeyMic/Tools/Shell/ShellLogger.swift`. Mirror the existing
  `test-shell-runner:` rule's source list as the reference.
- **Disposition:** out of scope for Plan 01-04 (different test runner, different
  files, no overlap with persona-centralization). Logged here for future attention.

## From Phase 01 Code Review (2026-05-19)

### WR-05: `PersonaStore @MainActor` annotation cascade

- **Where:** `Sources/KeyMic/LLM/PersonaStore.swift` (class declaration) — cascades
  to `Sources/KeyMic/AppDelegate.swift`, `Sources/KeyMic/KeyMonitor.swift`,
  `Sources/KeyMic/Hotkey/HotkeySettingsStore.swift`, `Sources/KeyMic/SettingsUI/SettingsRoot.swift`.
- **Symptom:** Annotating `PersonaStore` with `@MainActor` triggers 19 compile errors
  across 4 files — `KeyMonitor` (CFRunLoop callback context), `HotkeySettingsStore.personasProvider`
  closure, `AppDelegate` cross-actor access, and `SettingsRoot` view-model bridge.
- **Why deferred:** Required `MainActor.assumeIsolated` shims at every cross-actor
  boundary plus an architectural decision on whether to lift the whole AppDelegate to
  `@MainActor` (or only the relevant call paths). Beyond a localized review-fix pass —
  best handled as a coordinated Swift 6 concurrency adoption phase.
- **Current safety net:** All persona-store mutations and reads happen on main in
  production (event-tap callback, AppDelegate, SwiftUI views) — de facto thread-safe.
  Risk is regression at the next refactor that touches PersonaStore from a background
  context.
- **Fix sketch (for future Swift-6-concurrency phase):**
  1. Annotate `PersonaStore` class with `@MainActor`.
  2. Annotate `AppDelegate` with `@MainActor` (it already only mutates on main).
  3. In `KeyMonitor` CFRunLoop callback, wrap `PersonaStore.shared.*` reads in
     `MainActor.assumeIsolated { ... }`.
  4. Flip `HotkeySettingsStore.personasProvider` closure return type to `@MainActor`
     or capture a snapshot at registration time.
  5. Audit `SettingsRoot` view-model for any non-MainActor consumers.
- **Disposition:** out of scope for the localized Phase 01 review-fix pass. Logged
  here for a future Swift-6-concurrency adoption phase.
