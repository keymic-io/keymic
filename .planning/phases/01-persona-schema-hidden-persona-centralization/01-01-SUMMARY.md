---
phase: 01-persona-schema-hidden-persona-centralization
plan: 01
subsystem: persona-schema
tags: [swift, codable, persona, schema-migration, hidden-persona]

# Dependency graph
requires: []
provides:
  - "Persona schema carries `hidden: Bool` (default false), Codable-backwards-compatible"
  - "Persona has restored explicit memberwise init with `hidden: Bool = false` as trailing default — every pre-Phase-1 call site compiles unchanged"
  - "`Persona.builtInSeeds()` returns 5 elements (4 originals + builtin-shortcut-config as 5th hidden seed)"
  - "Co-located tests bumped to assert 5 built-ins on first launch + 6 after one custom add"
affects:
  - "01-02-PLAN (PersonaStore visiblePersonas / allPersonas / shortcutConfigPersona + setActive rejection + mergeWithBuiltIns override)"
  - "01-03-PLAN (5 callsite migrations from personas → visiblePersonas)"
  - "01-04-PLAN (PersonaHiddenTests.swift + Makefile rule)"
  - "Phase 2 (YAML parser — will use shortcutConfigPersona's stylePrompt; placeholder is intentional)"
  - "Phase 6 (PROMPT-01..07 — will replace the D-03 placeholder stylePrompt with the final prompt)"

# Tech tracking
tech-stack:
  added: []  # No new dependencies — pure schema extension
  patterns:
    - "Custom `init(from:)` + restored memberwise init (Pattern 1 Option A in RESEARCH.md) — additive Codable field with backwards-compat via `decodeIfPresent ?? false`"
    - "Hidden built-in seed via boolean field on Codable struct — single source of truth for filter centralization (D-05 territory in PLAN 02)"

key-files:
  created: []
  modified:
    - "Sources/KeyMic/LLM/Persona.swift — +54 lines: hidden field, CodingKeys, custom init(from:), restored memberwise init, comment update; +16 lines: builtin-shortcut-config seed"
    - "Tests/PersonaTests.swift — 2 lines changed: seeds.count 4→5 + id-array append builtin-shortcut-config"
    - "Tests/PersonaStoreTests.swift — 3 lines changed: store1.personas.count 4→5, store2.personas.count 4→5, store3.personas.count 5→6"

key-decisions:
  - "D-01 implemented: Persona.hidden + Codable round-trip + restored memberwise init (Option A — hidden positioned between builtIn and createdAt in both field declaration and memberwise init signature)"
  - "D-02 implemented: builtin-shortcut-config seed with exact field values (id, name, icon=command, temperature=0.0, hotkey=nil, contextMode=.none, builtIn=true, hidden=true)"
  - "D-03 implemented: stylePrompt is the verbatim placeholder `# Configured in Phase 6.\\nOutput YAML only. No prose. No fences.` — Phase 6 will replace; placeholder makes phase boundary grep-visible"
  - "D-04 implemented: seed appended last (after builtin-context); positions of 4 existing seeds unchanged; co-located tests bumped (4→5 / 5→6) rather than reorganized"

patterns-established:
  - "Pattern 1 Option A (Custom init(from:) + restored memberwise init): the file under `Sources/KeyMic/LLM/Persona.swift` is now the reference implementation for adding any future additive Codable field"
  - "Hidden-seed convention: a hidden built-in persona is `builtIn: true, hidden: true` with a stable id prefix `builtin-*`; future hidden seeds (if any) follow this shape"

requirements-completed: [PERS-01, PERS-02, PERS-03, PERS-04]

# Metrics
duration: ~10min
completed: 2026-05-18
---

# Phase 01 Plan 01: Persona Schema + Hidden Seed Foundation

**Persona gains `hidden: Bool` (Codable-backwards-compatible default `false`) and a 5th hidden built-in seed `builtin-shortcut-config`; co-located test count-assertions bumped from 4→5 / 5→6. Foundation for PLAN 02 (store accessors) and PLAN 03 (callsite migrations).**

## Performance

- **Duration:** ~10 min (3 tasks + summary + verification)
- **Completed:** 2026-05-18
- **Tasks:** 3 / 3 committed atomically
- **Files modified:** 3 (Sources/KeyMic/LLM/Persona.swift, Tests/PersonaTests.swift, Tests/PersonaStoreTests.swift)
- **Files created:** 0 — pure schema extension

## Accomplishments

- `Persona` carries `hidden: Bool` (default `false`) and decodes pre-Phase-1 `personas.json` (no `hidden` key) with every persona getting `hidden = false` automatically (`decodeIfPresent(Bool.self, forKey: .hidden) ?? false`).
- Restored explicit memberwise initializer with `hidden: Bool = false` as a trailing-with-default parameter — every existing `Persona(...)` call site (PersonaStore.duplicate, PersonasView.addCustom, PersonaStoreTests, PersonaTests) compiles unchanged.
- `Persona.builtInSeeds()` now returns 5 seeds; the 5th (`builtin-shortcut-config`) is the only one with `hidden: true` and carries the D-03 placeholder stylePrompt for Phase 6 to finalize.
- Co-located tests pass with bumped seed-count assertions. Regression tests for clipboard (which exercise the broader build graph) still green.

## Task Commits

Each task was committed atomically inside this worktree branch `worktree-agent-abe8a0d0658295141`:

1. **Task 1: add `hidden: Bool` field + custom Codable + restored memberwise init** — `01d675f` (`feat`)
2. **Task 2: append `builtin-shortcut-config` as 5th hidden built-in seed** — `f57cf4b` (`feat`)
3. **Task 3: bump seed-count assertions in PersonaTests + PersonaStoreTests** — `0dc2ef6` (`test`)

Plan metadata (this SUMMARY) is committed in the next commit by the executor finalizer.

## Files Created/Modified

- `Sources/KeyMic/LLM/Persona.swift` — schema extension:
  - Added `var hidden: Bool` between `builtIn` and `createdAt` (matches memberwise-init arg order; matches D-02 seed-literal field order).
  - Added `private enum CodingKeys: String, CodingKey` enumerating all 11 fields.
  - Added custom `init(from decoder: Decoder) throws` with `self.hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false` (other fields use plain `decode(...)` except `hotkey` which keeps `decodeIfPresent` because it's an existing optional).
  - Did **not** define `encode(to:)` — Swift continues to synthesize it.
  - Restored explicit memberwise init signature `init(id:name:icon:stylePrompt:temperature:hotkey:contextMode:builtIn:hidden:createdAt:updatedAt:)` with `hidden: Bool = false` as trailing default so every existing call site compiles unchanged.
  - Updated L30 doc-comment from `name + builtIn flag are immutable in UI` to `name + builtIn + hidden are immutable in UI / restored from seed on load`.
  - Appended 5th seed `builtin-shortcut-config` inside `builtInSeeds()` array literal (positions of 4 existing seeds unchanged per D-04).
- `Tests/PersonaTests.swift` — L26 `seeds.count == 4` → `== 5`; L28 id-array literal gained `"builtin-shortcut-config"` appended at the end.
- `Tests/PersonaStoreTests.swift` — L14 `store1.personas.count == 4` → `== 5` (first load seeds 5 built-ins; message updated); L22 `store2.personas.count == 4` → `== 5` (reload keeps 5; message updated); L39 `store3.personas.count == 5` → `== 6` (5 built-ins + 1 custom = 6; message expanded to "add appends (5 built-ins + 1 custom)").

## Exact Field Values of the New Seed (consumed by PLAN 02 + PLAN 04)

```swift
Persona(
    id: "builtin-shortcut-config",
    name: "Shortcut Config",
    icon: "command",
    stylePrompt: """
        # Configured in Phase 6.
        Output YAML only. No prose. No fences.
        """,
    temperature: 0.0,
    hotkey: nil,
    contextMode: .none,
    builtIn: true,
    hidden: true,
    createdAt: now,
    updatedAt: now
)
```

- The stylePrompt literal renders as exactly `"# Configured in Phase 6.\nOutput YAML only. No prose. No fences."` because both content lines are aligned with the closing `"""` (mirrors the existing `builtin-default` multi-line indentation pattern).
- `icon: "command"` is the SF Symbol ⌘ — available since macOS 11, safe on the macOS 14 deployment floor (verified by RESEARCH.md Pitfall 6 + A4).
- This seed is the **only** built-in with `hidden: true`. Other 4 built-ins (`builtin-default`, `builtin-translate`, `builtin-cli`, `builtin-context`) all get `hidden == false` via the memberwise-init trailing default — none of their call sites changed.

## Per-Test-File Integer Bumps (consumed by PLAN 04 when adding PersonaHiddenTests assertions)

| File | Line | Before | After | Reason |
|------|------|--------|-------|--------|
| `Tests/PersonaTests.swift` | 26 | `seeds.count == 4` (`"exactly 4 built-in seeds"`) | `seeds.count == 5` (`"exactly 5 built-in seeds"`) | builtInSeeds() now returns 5 |
| `Tests/PersonaTests.swift` | 28 | `["builtin-default", "builtin-translate", "builtin-cli", "builtin-context"]` | …`, "builtin-shortcut-config"]` (append last) | preserves canonical order of first 4; new seed appended per D-04 |
| `Tests/PersonaStoreTests.swift` | 14 | `store1.personas.count == 4` (`"first load seeds 4 built-ins"`) | `== 5` (`"first load seeds 5 built-ins"`) | first launch now seeds 5 |
| `Tests/PersonaStoreTests.swift` | 22 | `store2.personas.count == 4` (`"reload keeps 4 personas"`) | `== 5` (`"reload keeps 5 personas"`) | reload also sees 5 |
| `Tests/PersonaStoreTests.swift` | 39 | `store3.personas.count == 5` (`"add appends"`) | `== 6` (`"add appends (5 built-ins + 1 custom)"`) | 5 built-ins + 1 user-added = 6 |

## Verification Results

All 8 plan-level criteria from `01-01-PLAN.md <verification>`:

1. `swift build` → exit 0 ✅
2. `make test-persona` → exit 0 (`✅ PersonaTests passed`) ✅
3. `make test-persona-store` → exit 0 (`✅ PersonaStoreTests passed`) ✅
4. Regression `make test-clipboard-store` + `make test-clipboard-monitor` → both pass ✅
5. `grep -c 'var hidden: Bool' Sources/KeyMic/LLM/Persona.swift` = 1 ✅
6. `grep -c 'builtin-shortcut-config' Sources/KeyMic/LLM/Persona.swift` = 1 ✅
7. `grep -cE 'decodeIfPresent\(Bool\.self, *forKey: \.hidden\)' Sources/KeyMic/LLM/Persona.swift` = 1 ✅
8. `grep -c 'hidden: Bool = false' Sources/KeyMic/LLM/Persona.swift` = 1 ✅

## Deviations from Plan

**None — plan executed exactly as written.**

The plan's `<read_first>` sections plus RESEARCH.md Pattern 1 Option A pinned the exact spelling. The only judgment call was inside Task 3: ensure `grep -c "builtin-shortcut-config" Tests/PersonaTests.swift == 1` by NOT putting the id in the surrounding comment (the id appears exactly once, on line 28 inside the expected-id-array literal).

## Process Note — Worktree Path Safety

Initial Task 1 Edit landed at the **main repo** absolute path `/Users/lorneluo/Workspace/lorne/keymic/Sources/KeyMic/LLM/Persona.swift` because the absolute path was constructed from prior context, not from `git rev-parse --show-toplevel` run inside the worktree. The main-repo edit was reverted with `git checkout -- Sources/KeyMic/LLM/Persona.swift` immediately upon detection (worktree-side `git status` showed `M` on `Persona.swift` but `grep -c` on the worktree copy returned 0, exposing the cwd-vs-target-path mismatch). All subsequent edits used the canonical worktree-rooted absolute path. No data lost; no commits made against the main repo. This is the failure mode described in `references/worktree-path-safety.md` issue #3099 and serves as a reminder for future tasks.

## Known Stubs

- `Persona(id: "builtin-shortcut-config", ...).stylePrompt` is intentionally a **placeholder** per D-03. Phase 6 (`PROMPT-01..07`) replaces it with the final prompt. This is documented inline in the seed literal and recorded in CONTEXT.md "deferred ideas". Not a blocker — Phase 2 (parser) is exercised against fixture LLM output, not live calls.

## Self-Check: PASSED

Verified that all files claimed in this SUMMARY exist and all commit hashes are present:

- `Sources/KeyMic/LLM/Persona.swift` — present (7050 bytes, includes `var hidden: Bool`, `decodeIfPresent(... .hidden) ?? false`, and `id: "builtin-shortcut-config"`)
- `Tests/PersonaTests.swift` — present, `seeds.count == 5` on L26
- `Tests/PersonaStoreTests.swift` — present, `personas.count == 6` after add on L39
- Commit `01d675f` — present in `git log`
- Commit `f57cf4b` — present in `git log`
- Commit `0dc2ef6` — present in `git log`
