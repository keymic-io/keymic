---
phase: 01-persona-schema-hidden-persona-centralization
plan: 03
subsystem: persona-callsites
tags: [swift, refactor, callsite-migration, hidden-persona, build-gate]

# Dependency graph
requires:
  - phase: 01-persona-schema-hidden-persona-centralization (Plan 01)
    provides: "Persona.hidden field + builtin-shortcut-config (5th hidden seed)"
  - phase: 01-persona-schema-hidden-persona-centralization (Plan 02)
    provides: "PersonaStore.personas narrowed to private; visiblePersonas / allPersonas / shortcutConfigPersona accessors; setActive silent-reject of hidden; mergeWithBuiltIns override of {id, builtIn, hidden}"
provides:
  - "Project-wide `swift build` clean (exit 0) — restores the gate that Plan 02 intentionally broke at 5 callsites"
  - "All 5 PersonaStore.shared.personas reads in production source migrated to .visiblePersonas"
  - "Hidden persona (`builtin-shortcut-config`) cannot leak into: settings persona list, hotkey-assignment sheet, conflict-message name lookup, status-bar persona submenu, runtime persona-hotkey dispatch, HotkeyRegistry persona ownership"
affects:
  - "01-04-PLAN — PersonaHiddenTests can now assert against `.visiblePersonas` (instead of `.personas`) with full confidence that no production callsite still reads the un-filtered array"
  - "Phase 4 — voice coordinator's `shortcutConfigPersona` lookup is the only intentional production read of the hidden seed; no other call sites compete"

# Tech tracking
tech-stack:
  added: []  # No dependencies — 5 single-token swaps
  patterns:
    - "Pattern A applied (Single-Source-of-Truth Access Migration): each callsite swap is `PersonaStore.shared.personas` → `PersonaStore.shared.visiblePersonas` (or `store.personas` → `store.visiblePersonas` inside the view-model)"
    - "Atomic per-callsite commits (5 commits, 1 file each, 1-line diff each) — every commit individually compiles closer to clean (Plan 02 left build broken at 5 files; each Task 1–5 commit eliminates one diagnostic)"

key-files:
  created:
    - ".planning/phases/01-persona-schema-hidden-persona-centralization/01-03-SUMMARY.md (this file)"
  modified:
    - "Sources/KeyMic/SettingsUI/PersonasView.swift — L395: `store.personas` → `store.visiblePersonas`"
    - "Sources/KeyMic/KeyMonitor.swift — L311: `PersonaStore.shared.personas` → `PersonaStore.shared.visiblePersonas`"
    - "Sources/KeyMic/Hotkey/HotkeySettingsStore.swift — L42: `PersonaStore.shared.personas` → `PersonaStore.shared.visiblePersonas` (inside `personasProvider:` closure)"
    - "Sources/KeyMic/AppDelegate.swift — L199: `PersonaStore.shared.personas` → `PersonaStore.shared.visiblePersonas` (`syncPersonaHotkeysToRegistry`); L614: `PersonaStore.shared.personas` → `PersonaStore.shared.visiblePersonas` (`rebuildPersonasMenu`)"

key-decisions:
  - "All 5 callsites migrated to `.visiblePersonas` (NOT `.allPersonas`) — every site is a UI surface or runtime-hotkey path where hidden personas must be filtered. No site intentionally retains hidden-inclusive semantics."
  - "Two AppDelegate sites committed as separate atomic commits (Task 4 + Task 5) rather than folded into one — preserves the plan's `one commit per callsite` structure and keeps the per-commit blast radius minimal."
  - "Scope-excluded the pre-existing `ScreenshotController` Swift 6 main-actor conformance warning surfaced by `swift build` — it is not caused by this plan's changes and falls under the executor's documented scope-boundary rule (logged here for traceability, not fixed)."

patterns-established:
  - "Callsite migration cadence for narrowed-access store accessors: `<store>.<oldName>` → `<store>.<filterName>`, one commit per file × callsite-context pair. Reference impl: this plan's 5 commits."

requirements-completed: [PERS-09, PERS-10]

# Metrics
duration: ~4min
completed: 2026-05-18
---

# Phase 01 Plan 03: Persona Callsite Migration Summary

**All 5 production callsites that previously read `PersonaStore.shared.personas` (or `store.personas` from inside `PersonasViewModel`) now read `.visiblePersonas`. Project-wide `swift build` is green again, closing the intentional build break Plan 02 left at 5 files. The hidden `builtin-shortcut-config` seed (Plan 01) is now invisible to every UI surface and runtime hotkey path.**

## Performance

- **Duration:** ~4 min wall-clock (5 atomic commits + baseline build + 4 verification gates + summary)
- **Started:** 2026-05-18T13:31:40Z
- **Completed:** 2026-05-18T13:35:34Z
- **Tasks:** 5 / 5 committed atomically (one commit per callsite per plan structure)
- **Files modified:** 4 production source files (AppDelegate.swift touched twice via Task 4 and Task 5)
- **Files created:** 1 (this SUMMARY.md)

## Accomplishments

- **Settings persona list filtered.** `PersonasView.PersonasViewModel.reload()` reads `store.visiblePersonas`; the SwiftUI `ForEach(model.personas)` row driver at L14 of the same file now iterates an already-filtered array (hidden personas dropped at the source).
- **Runtime persona-hotkey dispatch filtered.** `KeyMonitor`'s CGEventTap callback iterates `PersonaStore.shared.visiblePersonas` when scanning for matching push-to-talk hotkeys. Hidden personas can never claim a runtime hotkey route, even if a future hidden seed grew a non-nil `hotkey` field.
- **Hotkey-assignment sheet + conflict-name lookup filtered.** `HotkeySettingsStore.shared`'s `personasProvider` closure now returns visible personas only. Two downstream effects: (a) `loadOrCreate` ignores hidden personas when seeding the persona-hotkey map at first launch, and (b) `validatePersonaConflict`'s name lookup at L167 can't accidentally produce a "Conflicts with: Persona: Shortcut Config" error message.
- **Registry sync filtered.** `AppDelegate.syncPersonaHotkeysToRegistry()` iterates `.visiblePersonas` — hidden personas are never registered as `HotkeyOwner.persona(id:)` in `HotkeyRegistry.shared`.
- **Status-bar menu filtered.** `AppDelegate.rebuildPersonasMenu()` reads `.visiblePersonas` — the status-bar persona submenu (PersonaMenuItemView rows + togglePersona handlers) never shows the hidden seed.
- **Project-wide `swift build` restored to exit 0.** Plan 02's intentional callsite-level build break is closed.

## Task Commits

Each task was committed atomically on this worktree branch `worktree-agent-a52b17323f3ed7331` (base: `9b9214d`, the tip of `gsd/phase-01-persona-schema-hidden-persona-centralization` immediately after Plan 02):

1. **Task 1: PersonasView.swift L395 — `store.personas` → `store.visiblePersonas`** — `8200ee3` (`refactor`)
2. **Task 2: KeyMonitor.swift L311 — runtime persona-hotkey loop** — `e448673` (`refactor`)
3. **Task 3: HotkeySettingsStore.swift L42 — `personasProvider:` closure** — `9d9aa10` (`refactor`)
4. **Task 4: AppDelegate.swift L199 — `syncPersonaHotkeysToRegistry`** — `cb9ab62` (`refactor`)
5. **Task 5: AppDelegate.swift L614 — `rebuildPersonasMenu`** — `576b91e` (`refactor`)

SUMMARY metadata (this file) is committed in the next commit by the executor finalizer.

## Per-Callsite Migration Table

| # | File | Line | Before | After | Idiom rationale |
|---|------|------|--------|-------|-----------------|
| 1 | `Sources/KeyMic/SettingsUI/PersonasView.swift` | 395 | `personas = store.personas` | `personas = store.visiblePersonas` | View-model `reload()` populates the settings persona list (`ForEach(model.personas)` on L14). UI surface — hidden persona must not render. |
| 2 | `Sources/KeyMic/KeyMonitor.swift` | 311 | `for persona in PersonaStore.shared.personas {` | `for persona in PersonaStore.shared.visiblePersonas {` | Runtime push-to-talk hotkey dispatch in the CGEventTap callback. Hidden personas have `hotkey: nil` today but the principle is enforced at the source. |
| 3 | `Sources/KeyMic/Hotkey/HotkeySettingsStore.swift` | 42 | `static let shared = HotkeySettingsStore(personasProvider: { PersonaStore.shared.personas })` | `static let shared = HotkeySettingsStore(personasProvider: { PersonaStore.shared.visiblePersonas })` | Feeds both the persona-hotkey seed map (`loadOrCreate`) and the conflict-name lookup (`validatePersonaConflict`). Hotkey-assignment sheet UI surface. |
| 4 | `Sources/KeyMic/AppDelegate.swift` | 199 | `for persona in PersonaStore.shared.personas {` | `for persona in PersonaStore.shared.visiblePersonas {` | `syncPersonaHotkeysToRegistry()` — registers persona hotkey owners. Hidden persona must never own a registry slot. |
| 5 | `Sources/KeyMic/AppDelegate.swift` | 614 | `let personas = PersonaStore.shared.personas` | `let personas = PersonaStore.shared.visiblePersonas` | `rebuildPersonasMenu()` — drives the status-bar persona submenu. UI surface. |

**No site swapped to `.allPersonas`** — every one of the 5 is genuinely a "filter hidden" path. The `.allPersonas` escape hatch is reserved for tests and any future internal-only consumer that legitimately needs the unfiltered array (e.g. PersonaHiddenTests in Plan 04).

## Files Created/Modified

- `Sources/KeyMic/SettingsUI/PersonasView.swift` — single-token edit at L395.
- `Sources/KeyMic/KeyMonitor.swift` — single-token edit at L311.
- `Sources/KeyMic/Hotkey/HotkeySettingsStore.swift` — single-token edit at L42 (inside `personasProvider:` closure).
- `Sources/KeyMic/AppDelegate.swift` — two single-token edits at L199 and L614 (committed as Task 4 and Task 5 respectively, atomic per-callsite).
- `.planning/phases/01-persona-schema-hidden-persona-centralization/01-03-SUMMARY.md` — this file.

## Verification Results

Project-wide build gate (the plan's primary new gate that Plan 02 deferred):

1. `swift build` → exit 0 ✅

Regression gates (Waves 1 + 2 stay green):

2. `make test-persona` → `✅ PersonaTests passed` ✅
3. `make test-persona-store` → `✅ PersonaStoreTests passed` ✅
4. `make test-clipboard-store` → `ClipboardStoreTests passed` ✅
5. `make test-clipboard-monitor` → `ClipboardMonitorTests passed` ✅

Structural gates:

6. `grep -rn 'PersonaStore.shared.personas\b\|store\.personas\b' Sources/` → no matches (exit 1) ✅ — zero remaining un-filtered reads on the singleton or view-model `store`.
7. `grep -nE 'PersonaStore.shared.(personas|visiblePersonas|allPersonas|shortcutConfigPersona)' Sources/KeyMic/AppDelegate.swift` → both AppDelegate sites (L199, L614) read `.visiblePersonas`; `L314` continues to read `.activePersona` (unchanged — not in scope) ✅

## Baseline Confirmation

Before Task 1, `swift build` failed with exactly the diagnostics Plan 02's SUMMARY predicted: `'personas' is inaccessible due to 'private' protection level` at `HotkeySettingsStore.swift:42:85`, with parallel errors at the 4 other callsites (full output truncated by Bash tee). The error count matched the 5 callsites enumerated in this plan's `<task_summary>`.

After all 5 commits, `swift build` exits 0. The only `swift build` diagnostic still present is a pre-existing Swift 6 main-actor concurrency warning on `ScreenshotController` (file: `Sources/KeyMic/Screenshot/ScreenshotController.swift:6`) which is unrelated to this plan and out of scope per the executor's scope-boundary rule (logged here, not fixed).

## Decisions Made

None beyond confirming each callsite genuinely wants the filtered (`.visiblePersonas`) read. The plan's `<task_summary>` listed the 5 sites and named `.visiblePersonas` as the swap; semantic review of each site agreed — every one is a UI surface (settings list, hotkey-assignment sheet, status-bar menu) or a runtime hotkey path (KeyMonitor dispatch, registry sync) where hidden personas must be filtered.

## Deviations from Plan

**None — plan executed exactly as written.**

The line numbers cited in the `<task_summary>` were slightly different from the actual current lines (PersonasView.swift:395, KeyMonitor.swift:311 vs plan-cited :407, HotkeySettingsStore.swift:42 matches, AppDelegate.swift:199 matches, AppDelegate.swift:614 matches). This is expected line drift between plan authoring and execution; the 5 callsites identified semantically by `grep` were unambiguous, matched the plan's intent precisely, and form the complete set of `PersonaStore.shared.personas` / `store.personas` reads in `Sources/`.

## Issues Encountered

None.

**One process note on initial worktree-base reset:** the worktree-agent branch was created from `main` (HEAD `d90df7d`) rather than from the Plan-02 tip; the `<worktree_branch_check>` block in the executor prompt's `EXPECTED_BASE=9b9214d…` clause triggered the documented `git reset --hard 9b9214d…` recovery (a sanctioned exception inside `<worktree_branch_check>` per the destructive-git-prohibition rules). After the reset, `.planning/phases/01-…/` was populated with the two prior summaries and execution proceeded. No data lost; this is the expected first-action recovery path for a worktree spawned on a fresh-from-`main` branch when the orchestrator expects a phase-branch base. Recorded for transparency.

## User Setup Required

None — pure 5-line source refactor. No environment variables, no permissions, no Sparkle/Keychain interaction.

## Known Stubs

None introduced by this plan. The Phase 1 known stub (`Persona(id: "builtin-shortcut-config", ...).stylePrompt` placeholder per D-03 from Plan 01) is unchanged and remains deferred to Phase 6.

## Threat Flags

None. No new network endpoints, no auth paths, no file access patterns added. The 5 swaps tighten existing trust boundaries (the persona enumeration surfaces) by filtering at the source rather than relying on downstream consumers to skip hidden personas.

## Next Phase Readiness

- **Plan 04 unblocked:** PersonaHiddenTests can now make assertions against `.visiblePersonas` / `.allPersonas` / `.shortcutConfigPersona` with full confidence that no production callsite competes for the un-filtered `.personas` (which is now `private` and has zero external readers in `Sources/`).
- **Phase 4 unblocked at API surface:** `shortcutConfigPersona` is the lone intentional production-read entry point for the hidden seed. The Phase 4 voice coordinator can wire to it directly without any callsite-collision concern.
- **No blockers carried forward.** Project-wide `swift build` is clean; the four regression test gates are green; zero `.personas` reads remain in `Sources/`.

## Self-Check: PASSED

Verified that all files claimed in this SUMMARY exist in the worktree and all commit hashes are present in `git log`:

- `Sources/KeyMic/SettingsUI/PersonasView.swift` — present; L395 reads `store.visiblePersonas`.
- `Sources/KeyMic/KeyMonitor.swift` — present; L311 reads `PersonaStore.shared.visiblePersonas`.
- `Sources/KeyMic/Hotkey/HotkeySettingsStore.swift` — present; L42 reads `PersonaStore.shared.visiblePersonas`.
- `Sources/KeyMic/AppDelegate.swift` — present; L199 and L614 both read `PersonaStore.shared.visiblePersonas`.
- Commit `8200ee3` (Task 1, PersonasView) — present in `git log`.
- Commit `e448673` (Task 2, KeyMonitor) — present in `git log`.
- Commit `9d9aa10` (Task 3, HotkeySettingsStore) — present in `git log`.
- Commit `cb9ab62` (Task 4, syncPersonaHotkeysToRegistry) — present in `git log`.
- Commit `576b91e` (Task 5, rebuildPersonasMenu) — present in `git log`.
- `swift build` → exit 0.
- `make test-persona` → `✅ PersonaTests passed`.
- `make test-persona-store` → `✅ PersonaStoreTests passed`.
- `make test-clipboard-store` → `ClipboardStoreTests passed`.
- `make test-clipboard-monitor` → `ClipboardMonitorTests passed`.
- `grep -rn 'PersonaStore.shared.personas\b\|store\.personas\b' Sources/` → 0 matches.

---

*Phase: 01-persona-schema-hidden-persona-centralization*
*Plan: 03*
*Completed: 2026-05-18*
