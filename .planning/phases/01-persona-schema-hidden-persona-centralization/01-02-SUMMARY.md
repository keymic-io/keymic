---
phase: 01-persona-schema-hidden-persona-centralization
plan: 02
subsystem: persona-store
tags: [swift, persona-store, access-narrowing, hidden-filter, codable-merge]

# Dependency graph
requires:
  - phase: 01-persona-schema-hidden-persona-centralization (Plan 01)
    provides: "Persona.hidden field + restored memberwise init + builtin-shortcut-config seed (5th built-in)"
provides:
  - "`PersonaStore.personas` is `private` (no public read channel); 5 external callsites in PLAN-03 territory are now compile-broken on purpose"
  - "`PersonaStore.visiblePersonas` — `personas.filter { !$0.hidden }` — single source of truth for every UI / runtime iteration"
  - "`PersonaStore.allPersonas` — full underlying array (escape hatch for tests + internal-only consumers)"
  - "`PersonaStore.shortcutConfigPersona` — `personas.first { $0.id == \"builtin-shortcut-config\" }` (convenience getter for Phase 4 voice coordinator)"
  - "`PersonaStore.setActive(_:)` silently rejects hidden personas (no save, no log, no `didChangeNotification`); preserves existing `activePersonaId` unchanged"
  - "`PersonaStore.mergeWithBuiltIns(loaded:)` overrides `{id, builtIn, hidden}` from seed for every disk persona whose id matches a seed; preserves `{stylePrompt, icon, temperature, hotkey, contextMode, name, createdAt, updatedAt}` from disk"
affects:
  - "01-03-PLAN — must swap 5 callsites (PersonasView.swift:395, KeyMonitor.swift:407, HotkeySettingsStore.swift:42, AppDelegate.swift:199 + :614) from `.personas` → `.visiblePersonas`; integration `swift build` gate lives in that plan"
  - "01-04-PLAN — new `PersonaHiddenTests.swift` test file asserts against `visiblePersonas`/`allPersonas`/`shortcutConfigPersona`/setActive rejection/re-merge override (D-10 cases #1–#6)"
  - "Phase 4 — `shortcutConfigPersona` is the single getter the voice coordinator consumes; no broader API surface needed"
  - "Phase 6 — hidden persona stays untouched; only the placeholder `stylePrompt` from Plan 01 needs replacement"

# Tech tracking
tech-stack:
  added: []  # No dependencies — pure access refactor + 4-line merge extension
  patterns:
    - "Single-source-of-truth access narrowing (`private(set)` → `private` + filtered/full computed properties)"
    - "Codable on-load override of immutable fields (`{id, builtIn, hidden}` restored from seed; user-editable fields preserved from disk)"
    - "Two-branch setActive guard with explicit early-return on guarded predicate, preserving fall-through semantics for unknown/nil"

key-files:
  created: []
  modified:
    - "Sources/KeyMic/LLM/PersonaStore.swift — +14 lines (3 accessors), `private(set)` → `private` on line 20, `setActive` rewritten from 1-line `.flatMap` to two-branch (+7 lines), `mergeWithBuiltIns` extended with 3-line override + bumped doc comment"
    - "Tests/PersonaStoreTests.swift — 3 lines: `store.personas.count` → `store.allPersonas.count` at L14, L22, L39 (Rule 3 deviation — unblocks plan's primary test gate after access narrowing)"

key-decisions:
  - "D-05 implemented: narrow `personas` access to `private`; add 3 computed accessors (`visiblePersonas`, `allPersonas`, `shortcutConfigPersona`); property name `personas` preserved (no `_personas` rename — 9 internal reads stay correct under `private`)"
  - "D-07 implemented: `setActive` silently rejects hidden — no save, no log, no `didChangeNotification`. `activePersonaId` is preserved unchanged on rejection; nil/unknown path falls through to `activePersonaId = nil; save()` to keep existing `PersonaStoreTests.testFirstLaunchSeedsBuiltIns` invariant green"
  - "D-08 implemented: `mergeWithBuiltIns` override of `{id, builtIn, hidden}` from seed for matching ids; bundles the PERS-07 re-merge requirement with the latent `builtIn: false` hand-edit bug fix at near-zero extra LOC"

patterns-established:
  - "Pattern A — Single-Source-of-Truth Access Migration: narrow `private(set)` to `private`, add filtered/full computed properties on the store; UI consumers gain a typed leak guard. Reference impl: `PersonaStore.visiblePersonas`/`allPersonas`."
  - "Pattern E — `mergeWithBuiltIns` Override: when the on-disk schema permits hand-edits but the model has immutable-by-design fields, the loader (not the encoder) restores invariants. This is the project's locus for upgrade-tolerant identity guards."

requirements-completed: [PERS-05, PERS-06, PERS-07, PERS-08]

# Metrics
duration: ~5min
completed: 2026-05-18
---

# Phase 01 Plan 02: PersonaStore Hidden-Persona Centralization Summary

**`PersonaStore.personas` narrowed to `private`; three new accessors (`visiblePersonas` / `allPersonas` / `shortcutConfigPersona`) become the single source of truth for hidden-aware persona reads; `setActive` silently rejects hidden ids; `mergeWithBuiltIns` overrides `{id, builtIn, hidden}` from seed on every load. PERS-07 re-merge BLOCKER closed at the loader.**

## Performance

- **Duration:** ~2 minutes wall-clock (5 minutes including context load + verification + summary)
- **Started:** 2026-05-18T13:23:07Z (first task commit)
- **Completed:** 2026-05-18T13:25:12Z (last task commit)
- **Tasks:** 3 / 3 committed atomically
- **Files modified:** 2 (`Sources/KeyMic/LLM/PersonaStore.swift`, `Tests/PersonaStoreTests.swift`)
- **Files created:** 0

## Accomplishments

- **Access narrowed.** `private(set) var personas` → `private var personas`. UI surfaces can no longer obtain a list of personas that includes the hidden seed without explicitly opting in via `allPersonas` (typed leak guard).
- **3 new accessors.** All grouped immediately after `activePersona` to keep persona reads visually colocated:
  - `var visiblePersonas: [Persona] { personas.filter { !$0.hidden } }` — the canonical UI read.
  - `var allPersonas: [Persona] { personas }` — escape hatch for tests/internal; NOT for UI.
  - `var shortcutConfigPersona: Persona? { personas.first { $0.id == "builtin-shortcut-config" } }` — convenience getter the Phase 4 coordinator will consume.
- **`setActive` guard.** The hidden persona cannot be activated even via direct programmatic call; the function silently returns before `save()` is reached, preserving the user's existing active persona unchanged. The fall-through for unknown/nil ids still calls `save()` so `PersonaStoreTests.testFirstLaunchSeedsBuiltIns`'s `setActive("user-2-doesnt-exist")` → `activePersonaId == nil` invariant stays green.
- **Re-merge override.** Hand-edited `personas.json` with `"hidden": false` and/or `"builtIn": false` on `builtin-shortcut-config` (or any built-in id) is repaired silently on next load: the seed's `{id, builtIn, hidden}` wins; user-editable fields (`stylePrompt`, `icon`, `temperature`, `hotkey`, `contextMode`, `name`, `createdAt`, `updatedAt`) survive from disk. Closes the PERS-07 BLOCKER and the latent `builtIn: false` hand-edit bug in one path.

## Task Commits

Each task was committed atomically on this worktree branch `worktree-agent-a134f26d2d5ff9bb4`:

1. **Task 1: narrow `personas` to `private` + add `visiblePersonas` / `allPersonas` / `shortcutConfigPersona`** — `9d6824a` (`refactor`)
2. **Task 2: rewrite `setActive(_:)` to silently reject hidden personas** — `0224cdf` (`feat`)
3. **Task 3: extend `mergeWithBuiltIns` to override `{id, builtIn, hidden}` from seed + migrate `PersonaStoreTests` to `.allPersonas`** — `e6e1d22` (`feat`)

SUMMARY metadata (this file) is committed in the next commit by the executor finalizer.

## Files Created/Modified

- `Sources/KeyMic/LLM/PersonaStore.swift` (the entire plan):
  - L20: `private(set) var personas` → `private var personas`.
  - +14 lines (placed immediately after the `activePersona` computed property): three doc-commented computed properties `visiblePersonas`, `allPersonas`, `shortcutConfigPersona`. Single-line bodies per D-05 minimal-spelling guidance.
  - `setActive(_:)` rewritten from a one-line `.flatMap` body to a two-branch structure:
    - If `id != nil` and a persona is found: hidden guard (early return) → otherwise assign and save.
    - Else: fall through to `activePersonaId = nil; save()` (preserves nil/unknown-id semantics).
    - No `logger.` calls added on any path (D-07 explicitly silent).
  - `mergeWithBuiltIns(loaded:)` doc comment bumped from "all 4 built-ins" to "all 5 built-ins" with an explicit enumeration of restored-from-seed fields (`id`, `builtIn`, `hidden`) vs preserved-from-disk fields (`stylePrompt`, `icon`, `temperature`, `hotkey`, `contextMode`, `name`, `createdAt`, `updatedAt`). The `if let existing` branch body changed from a 1-line `result.append(existing)` to a 5-line `var merged = existing; merged.id = …; merged.builtIn = …; merged.hidden = …; result.append(merged)`. The else branch and the post-loop trailing-customs appender are untouched.
  - **Untouched:** `Envelope.version` stays at `1` (additive schema; no migration needed — D-08 + Plan 01's `decodeIfPresent ?? false` cover backwards compat).
- `Tests/PersonaStoreTests.swift`:
  - L14: `store1.personas.count == 5` → `store1.allPersonas.count == 5`.
  - L22: `store2.personas.count == 5` → `store2.allPersonas.count == 5`.
  - L39: `store3.personas.count == 6` → `store3.allPersonas.count == 6`.
  - Reason: Task 1 narrowed `personas` to `private`; these three reads no longer compile from outside the class. `allPersonas` was added in Task 1 precisely as the escape hatch for tests and internal consumers (per D-05). Test semantics unchanged — `allPersonas` returns the same underlying array.

## Exact Diff of `setActive` (consumed by PLAN 04 D-10 #3 test assertion)

```swift
// Before (PersonaStore.swift L43–46):
func setActive(_ id: String?) {
    activePersonaId = id.flatMap { persona(id: $0) == nil ? nil : $0 }
    save()
}

// After (Plan 02 Task 2):
func setActive(_ id: String?) {
    if let id, let p = persona(id: id) {
        if p.hidden { return }   // silent reject; activePersonaId unchanged; no save
        activePersonaId = id
        save()
        return
    }
    activePersonaId = nil
    save()
}
```

**Contract for PLAN-04 tests:**
- `setActive("builtin-shortcut-config")` after a fresh `PersonaStore(storeURL:)` (where `activePersonaId == nil`) → `activePersonaId` remains `nil` (NOT explicitly demoted; the guard returns before any assignment); `save()` is NOT called; `personas.json` is NOT touched.
- `setActive("builtin-shortcut-config")` after `setActive("builtin-default")` → `activePersonaId` remains `"builtin-default"` unchanged (the canonical D-07 invariant).
- `setActive("user-99-does-not-exist")` (non-hidden unknown) → `activePersonaId = nil; save()` (preserves existing `PersonaStoreTests` behavior).
- `setActive(nil)` → `activePersonaId = nil; save()` (preserves existing behavior).

## Exact Diff of `mergeWithBuiltIns` (consumed by PLAN 04 D-10 #5 test assertion)

```swift
// Before (PersonaStore.swift L121–136):
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

// After (Plan 02 Task 3):
/// Ensures all 5 built-ins exist; restores immutable seed fields
/// ({id, builtIn, hidden}) for any disk persona whose id matches a seed.
/// User-editable fields (stylePrompt, icon, temperature, hotkey,
/// contextMode, name, createdAt, updatedAt) from disk are preserved.
/// Custom personas pass through unchanged.
private func mergeWithBuiltIns(loaded: [Persona]) -> [Persona] {
    let seeds = Persona.builtInSeeds()
    var result: [Persona] = []
    for seed in seeds {
        if let existing = loaded.first(where: { $0.id == seed.id }) {
            var merged = existing
            merged.id = seed.id            // identity guard (no-op on match, defensive)
            merged.builtIn = seed.builtIn  // immutable — restore from seed
            merged.hidden = seed.hidden    // immutable — restore from seed (PERS-07)
            result.append(merged)
        } else {
            result.append(seed)
        }
    }
    let builtInIds = Set(seeds.map(\.id))
    result.append(contentsOf: loaded.filter { !builtInIds.contains($0.id) })
    return result
}
```

**Contract for PLAN-04 tests:**
- Hand-write a `personas.json` where `builtin-shortcut-config` has `"hidden": false`, `"builtIn": false`, and a custom `stylePrompt`. After `PersonaStore(storeURL:)`, the loaded persona must have `hidden == true`, `builtIn == true`, `id == "builtin-shortcut-config"` (all 3 restored from seed), AND `stylePrompt` equal to the disk value (preserved).

## Signatures of the New Accessors

```swift
var visiblePersonas: [Persona]              // personas.filter { !$0.hidden }
var allPersonas: [Persona]                  // personas (full array, hidden included)
var shortcutConfigPersona: Persona?         // personas.first { $0.id == "builtin-shortcut-config" }
```

All three are computed properties (no caching — performance non-concern at ≤5 personas, per CONTEXT.md "Claude's Discretion"). Internal accessors inside `PersonaStore.swift` (9 reads in `persona(id:)`, `persona(forHotkey:)`, `setActive` chain, `add`, `update`, `delete`, `duplicate`, `seedFirstLaunch`, `save`) continue to read the unprefixed `personas` storage directly — `private` access permits intra-class reads.

## Verification Results

All 7 plan-level criteria from `01-02-PLAN.md <verification>`:

1. `grep -c "private var personas" Sources/KeyMic/LLM/PersonaStore.swift` == 1 ✅
2. `grep -c "var visiblePersonas" Sources/KeyMic/LLM/PersonaStore.swift` == 1 ✅
3. `grep -c "var allPersonas" Sources/KeyMic/LLM/PersonaStore.swift` == 1 ✅
4. `grep -c "var shortcutConfigPersona" Sources/KeyMic/LLM/PersonaStore.swift` == 1 ✅
5. `grep -c "if p.hidden { return }" Sources/KeyMic/LLM/PersonaStore.swift` == 1 ✅
6. `grep -c "merged.hidden = seed.hidden" Sources/KeyMic/LLM/PersonaStore.swift` == 1 ✅
7. `make test-persona-store` → `✅ PersonaStoreTests passed` ✅

Plus the regression check that Wave 1 stays green: `make test-persona` → `✅ PersonaTests passed` ✅

Plan-level expectation explicitly **not** gated here (owned by PLAN-03): project-wide `swift build` currently fails at 5 callsite files (`PersonasView.swift:395`, `KeyMonitor.swift:407`, `HotkeySettingsStore.swift:42`, `AppDelegate.swift:199` and `:614`) because they still read `.personas` directly. This is the intended, documented state at the end of Plan 02. PLAN-03's `<verification>` block will gate the project-wide clean build after the 5 callsites are swapped to `.visiblePersonas`.

## Decisions Made

None beyond the locked CONTEXT.md decisions (D-05, D-07, D-08). The plan's `<read_first>` + RESEARCH.md Pattern 2/3/4 pinned the exact spelling. The only judgment call was inside Task 3: the test-side migration to `.allPersonas`, captured as a Rule 3 deviation below.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking issue] Migrated `Tests/PersonaStoreTests.swift` from `.personas` to `.allPersonas`**

- **Found during:** Task 3 verification (`make test-persona-store` step)
- **Issue:** After Task 1 narrowed `PersonaStore.personas` from `private(set)` to `private`, the existing 3 reads of `store.personas.count` in `Tests/PersonaStoreTests.swift` (L14, L22, L39) no longer compiled — `swiftc` reported `error: 'personas' is inaccessible due to 'private' protection level`. This blocked the plan's primary test gate (`make test-persona-store` exits 0), one of the 7 plan-level verifications.
- **Fix:** Replaced all 3 reads with `.allPersonas` — the public escape-hatch accessor I added in Task 1 specifically for this category of consumer (tests + internal-only consumers; UI must never use it per D-05). The count semantics are identical: `allPersonas` returns the full underlying `personas` array unchanged.
- **Files modified:** `Tests/PersonaStoreTests.swift` (3 single-token edits)
- **Verification:** `make test-persona-store` → `✅ PersonaStoreTests passed` after the swap.
- **Committed in:** `e6e1d22` (folded into the Task 3 commit because the test gate is part of Task 3's verification).

This is a textbook Rule 3 ("auto-fix blocking issues") and is consistent with the access-narrowing intent of D-05: tests are the canonical legitimate consumer of `allPersonas`. No semantic test change; no scope creep; PLAN 04 already plans a richer `PersonaHiddenTests.swift` test file that will assert against `.visiblePersonas` / `.allPersonas` / `.shortcutConfigPersona` separately.

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** The deviation kept the plan's stated test gate (`make test-persona-store` exits 0) achievable after Task 1's access narrowing. No new behavior, no new dependencies, no architectural shift. Within the scope of the access-narrowing work the plan explicitly authorized.

## Issues Encountered

None. The plan's `<read_first>` + Pattern 2/3/4 in RESEARCH.md gave verbatim code for all three patches.

## User Setup Required

None — pure source refactor, no external services, no environment variables, no permissions, no Sparkle/Keychain interaction.

## Known Stubs

None introduced by this plan. The Phase 1 known stub is `Persona(id: "builtin-shortcut-config", ...).stylePrompt` (a placeholder per D-03), introduced and documented in Plan 01's SUMMARY and intentionally deferred to Phase 6 (`PROMPT-01..07`). Plan 02 did not touch the stylePrompt and does not introduce any new stubs.

## Threat Flags

None. No new network endpoints, no auth paths, no file access patterns added. The `setActive` hidden-guard is a defense-in-depth measure for an existing trust boundary (the persona activation API) — it tightens an invariant rather than introducing new surface. The `mergeWithBuiltIns` override is similarly a defense-in-depth measure against hand-edits to `personas.json` (a non-TCC-protected file in `~/Library/Application Support/KeyMic/`).

## Next Phase Readiness

- **PLAN 03 unblocked:** `visiblePersonas` is in place; 5 callsites can migrate. PLAN 03 owns the project-wide `swift build` integration gate.
- **PLAN 04 unblocked:** the 3 new accessors + the patched `setActive` + the extended `mergeWithBuiltIns` are the contracts `PersonaHiddenTests.swift` asserts against (D-10 cases #1–#6). The exact contracts are documented in the "Exact Diff" sections above.
- **Phase 2 unblocked at schema level:** `shortcutConfigPersona` is the getter the YAML parser doesn't need yet (Phase 2 exercises against fixtures) but the Phase 4 coordinator will consume directly.
- **No blockers carried forward.** PERS-07 (re-merge BLOCKER from PRD D4 mitigation) is closed at the loader. The latent `builtIn: false` hand-edit bug is closed incidentally.

## Self-Check: PASSED

Verified that all files claimed in this SUMMARY exist in the worktree and all commit hashes are present in `git log`:

- `Sources/KeyMic/LLM/PersonaStore.swift` — present in worktree; contains `private var personas` (1), `var visiblePersonas` (1), `var allPersonas` (1), `var shortcutConfigPersona` (1), `if p.hidden { return }` (1), `merged.hidden = seed.hidden` (1), `merged.builtIn = seed.builtIn` (1), `merged.id = seed.id` (1), `all 5 built-ins` (1).
- `Tests/PersonaStoreTests.swift` — present in worktree; `store.personas.count` reads gone (0); `store.allPersonas.count` reads present (3 — L14, L22, L39).
- Commit `9d6824a` (Task 1) — present in `git log`.
- Commit `0224cdf` (Task 2) — present in `git log`.
- Commit `e6e1d22` (Task 3) — present in `git log`.
- `make test-persona-store` → `✅ PersonaStoreTests passed`.
- `make test-persona` → `✅ PersonaTests passed` (Wave 1 regression green).

---

*Phase: 01-persona-schema-hidden-persona-centralization*
*Plan: 02*
*Completed: 2026-05-18*
