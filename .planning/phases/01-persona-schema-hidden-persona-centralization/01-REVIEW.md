---
phase: 01-persona-schema-hidden-persona-centralization
reviewed: 2026-05-19T00:00:00Z
fixes_applied: 2026-05-19T12:28:00+10:00
depth: standard
files_reviewed: 9
files_reviewed_list:
  - Sources/KeyMic/AppDelegate.swift
  - Sources/KeyMic/Hotkey/HotkeySettingsStore.swift
  - Sources/KeyMic/KeyMonitor.swift
  - Sources/KeyMic/LLM/Persona.swift
  - Sources/KeyMic/LLM/PersonaStore.swift
  - Sources/KeyMic/SettingsUI/PersonasView.swift
  - Tests/PersonaHiddenTests.swift
  - Tests/PersonaStoreTests.swift
  - Tests/PersonaTests.swift
findings:
  critical: 2
  warning: 6
  info: 2
  total: 10
status: fixes_applied
---

# Phase 01: Code Review Report

**Reviewed:** 2026-05-19
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Phase 01 adds a `hidden: Bool` field to `Persona`, seeds a 5th hidden built-in (`builtin-shortcut-config`), narrows `PersonaStore.personas` to `private`, and exposes `visiblePersonas` / `allPersonas` / `shortcutConfigPersona` accessors. `setActive(_:)` now silently rejects hidden ids, and `mergeWithBuiltIns(loaded:)` restores `{id, builtIn, hidden}` from seed values on load.

The invariant the phase is trying to enforce — **a hidden persona must never be reachable from any voice / UI / hotkey runtime path** — is *almost* watertight, but is breached by `PersonaStore.load()`, which writes `envelope.activePersonaId` directly to `activePersonaId` without filtering hidden ids. The new `setActive` guard is bypassed at load time, so a hand-edited or legacy `personas.json` with `activePersonaId: "builtin-shortcut-config"` causes `AppDelegate.finishTranscription` to run the LLM with the hidden persona's stylePrompt on the next launch.

A second BLOCKER is a documented invariant / implementation mismatch: the `Persona.builtInSeeds()` docstring asserts built-in `name` is "restored from seed on load," but `mergeWithBuiltIns` does not restore `name`, and `PersonaHiddenTests.testReMergeOverridesHiddenFromSeed` actually *asserts the opposite* (`name == "Tampered Name"`). Either the docstring lies or the merge is incomplete; both interpretations require a change.

Test coverage for the new field is partial — `PersonaTests` round-trips a `Persona` with `hidden` defaulted to `false` and never exercises a `hidden: true` codable round-trip.

## Critical Issues

### CR-01: Hidden persona becomes active on load — bypasses `setActive` guard

**File:** `Sources/KeyMic/LLM/PersonaStore.swift:119-138`
**Issue:**
`load()` writes `envelope.activePersonaId` straight to `self.activePersonaId` and only nullifies it when the id is not present in the persona list. It does **not** check `persona(id: id)?.hidden`. Because `mergeWithBuiltIns` always re-injects `builtin-shortcut-config`, a `personas.json` whose `activePersonaId` is `"builtin-shortcut-config"` (legitimate sources: hand-edited disk file, pre-Phase-1 binary that wrote the value before the guard existed, manual import/restore) will silently leave the hidden persona active across launches.

Downstream effect: `AppDelegate.finishTranscription` (line 314) reads `PersonaStore.shared.activePersona`, gets the hidden persona, and refines voice transcription against its stylePrompt — the exact runtime leak Phase 01 was supposed to prevent. `PersonasView` and the menu-bar persona list filter via `visiblePersonas`, so the user has **no UI to recover** — the only way to clear the active id is via a `setActive(nil)` triggered by a different action, or by deleting the persistence file.

The patched `setActive(_:)` correctly rejects the hidden id at runtime, but `load()` is the only `activePersonaId` writer that does not go through that path. This is the same class of bug the Phase 01 plan flagged for `mergeWithBuiltIns` (immutable fields) — applied to `activePersonaId` it was missed.

**Fix:**
```swift
private func load() {
    guard FileManager.default.fileExists(atPath: storeURL.path) else {
        seedFirstLaunch()
        return
    }
    do {
        let data = try Data(contentsOf: storeURL)
        let envelope = try Self.decoder.decode(Envelope.self, from: data)
        self.personas = mergeWithBuiltIns(loaded: envelope.personas)
        self.activePersonaId = envelope.activePersonaId
        // Drop active id if the persona no longer exists OR is hidden.
        // Hidden personas must never be active — same invariant as setActive(_:).
        if let id = activePersonaId,
           let p = persona(id: id), !p.hidden {
            // OK — visible persona, keep it.
        } else if activePersonaId != nil {
            activePersonaId = nil
            save()
        }
    } catch {
        logger.error("load failed: \(error.localizedDescription, privacy: .public). Re-seeding.")
        seedFirstLaunch()
    }
}
```

A matching D-10 #7 test should be added to `PersonaHiddenTests.swift` that writes a fixture with `activePersonaId: "builtin-shortcut-config"`, loads it, and asserts `store.activePersonaId == nil` post-load.

### CR-02: `mergeWithBuiltIns` does not restore `name` despite docstring claim

**File:** `Sources/KeyMic/LLM/Persona.swift:83-84` ↔ `Sources/KeyMic/LLM/PersonaStore.swift:145-162` ↔ `Tests/PersonaHiddenTests.swift:206-208`
**Issue:**
`Persona.builtInSeeds()` docstring says:

> Built-ins: **name** + builtIn + hidden are immutable in UI / restored from seed on load; stylePrompt + icon + temperature + hotkey + contextMode editable.

The PersonasView UI honors this (`TextField(...).disabled(persona.builtIn)` at `PersonasView.swift:125`), but `mergeWithBuiltIns` (PersonaStore.swift:151-153) only restores `{id, builtIn, hidden}` — it does **not** restore `name`. And `PersonaHiddenTests.testReMergeOverridesHiddenFromSeed` (line 207-208) actively *asserts* that a tampered `"Tampered Name"` survives the merge:

```swift
expect(shortcut?.name == "Tampered Name",
       "name preserved from disk")
```

The codebase therefore has three sources of truth saying different things:
1. Docstring — `name` is restored from seed.
2. UI — `name` cannot be edited for built-ins.
3. Merge code + test — `name` is preserved from disk (i.e., editable via tampering).

For a built-in identified by stable id `builtin-shortcut-config`, the seed name "Shortcut Config" is also a localization key candidate for future i18n work. Letting it drift via disk tampering breaks any later switch to `String(localized:)` lookup keyed on the canonical name.

Pick one and align:

**Option A (recommended — matches docstring + UI intent):**
```swift
private func mergeWithBuiltIns(loaded: [Persona]) -> [Persona] {
    let seeds = Persona.builtInSeeds()
    var result: [Persona] = []
    for seed in seeds {
        if let existing = loaded.first(where: { $0.id == seed.id }) {
            var merged = existing
            merged.id      = seed.id
            merged.name    = seed.name      // immutable — restore from seed
            merged.builtIn = seed.builtIn
            merged.hidden  = seed.hidden
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
And update `testReMergeOverridesHiddenFromSeed` to assert `shortcut?.name == "Shortcut Config"`.

**Option B:** Edit the docstring on `Persona.builtInSeeds()` to drop `name` from the immutable list, and clarify on the form that the lock icon only enforces a UI restriction (not a load-time invariant).

Either fix is acceptable, but the current state is contradictory.

## Warnings

### WR-01: `Persona` Codable round-trip test never exercises `hidden: true`

**File:** `Tests/PersonaTests.swift:6-22`
**Issue:**
The round-trip test constructs a `Persona` using the memberwise initializer and lets `hidden` default to `false`. The decode-side custom initializer at `Persona.swift:67-80` parses `decodeIfPresent(Bool.self, forKey: .hidden) ?? false`, but no test exercises the `hidden: true` round-trip — i.e., that an encoded `hidden: true` re-decodes to `true` rather than being lost or coerced. `Persona.hidden` was the entire point of Phase 01; the round-trip cell of its truth table is untested.

**Fix:** Add an explicit case:
```swift
let hiddenPersona = Persona(
    id: "test-hidden", name: "Hidden", icon: "eye.slash",
    stylePrompt: "x", temperature: 0.0, hotkey: nil,
    contextMode: .none, builtIn: true, hidden: true,
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
)
let hiddenData = try! JSONEncoder().encode(hiddenPersona)
let hiddenDecoded = try! JSONDecoder().decode(Persona.self, from: hiddenData)
expect(hiddenDecoded.hidden == true, "hidden=true round-trips through Codable")
expect(hiddenDecoded == hiddenPersona, "full equality preserved for hidden persona")
```

### WR-02: `setActive(nil)` always writes to disk, even when already nil

**File:** `Sources/KeyMic/LLM/PersonaStore.swift:56-65`
**Issue:**
```swift
func setActive(_ id: String?) {
    if let id, let p = persona(id: id) {
        if p.hidden { return }
        activePersonaId = id
        save()
        return
    }
    activePersonaId = nil
    save()
}
```
The fall-through branch unconditionally calls `save()` even when `activePersonaId` is already `nil`. Each `save()` writes `personas.json` and posts `didChangeNotification`, which triggers `AppDelegate.rebuildPersonasMenu` and `syncPersonaHotkeysToRegistry` (registering then unregistering every persona hotkey for no reason). Call frequency: `AppDelegate.togglePersona` (line 645) calls `setActive(nil)` whenever the user clicks the currently-active persona to deselect, and on every "Clear Default" button click in `PersonasView`. Not a correctness defect but a write-amplification + UI-rebuild trigger.

**Fix:**
```swift
func setActive(_ id: String?) {
    if let id, let p = persona(id: id) {
        if p.hidden { return }
        guard activePersonaId != id else { return }
        activePersonaId = id
        save()
        return
    }
    guard activePersonaId != nil else { return }
    activePersonaId = nil
    save()
}
```

### WR-03: `duplicate(id:)` does not reject hidden source personas

**File:** `Sources/KeyMic/LLM/PersonaStore.swift:88-107`
**Issue:**
`duplicate(id:)` accepts any persona id, including the hidden `builtin-shortcut-config`. The resulting custom persona is constructed without passing `hidden:` (defaults to `false`) — so a hidden persona can be cloned into a visible custom persona via the API. The current UI does not expose this path (`PersonasView` shows only `visiblePersonas`, so the user cannot select the hidden persona to duplicate), but the runtime API is the choke point this phase introduced. If any future code path (Phase 6 shortcut-config UI, importer, debug menu) calls `PersonaStore.shared.duplicate("builtin-shortcut-config")`, the user gets a visible "Shortcut Config Copy" persona with the hidden persona's prompt and that won't be reverted by subsequent loads.

**Fix:** Either reject duplication of hidden personas:
```swift
@discardableResult
func duplicate(id: String) -> Persona? {
    guard let source = persona(id: id), !source.hidden else { return nil }
    // ...
}
```
Or, less restrictive, explicitly clear `hidden` on the copy and document the intent. The current implementation passes neither test of intent.

### WR-04: `persona(forHotkey:)` doesn't filter hidden personas

**File:** `Sources/KeyMic/LLM/PersonaStore.swift:52-54`
**Issue:**
```swift
func persona(forHotkey hotkey: String) -> Persona? {
    personas.first { $0.hotkey == hotkey }
}
```
This iterates the underlying `personas` array (not `visiblePersonas`) and will return the hidden persona if it carries a matching `hotkey` on disk (only reachable via hand-edit today, since the visiblePersonas-scoped `personasProvider` of `HotkeySettingsStore` never writes one — but `Persona.hotkey` is a separately persisted field from `HotkeySettingsStore.personaHotkeys`, so the two can diverge). Of the centralization callsites mentioned in the phase context this method appears to be dead in the production graph (`grep` finds no callers in Sources/), but it is exercised by `PersonaStoreTests.swift:86-88`, so removing it isn't a clean no-op. Either:

**Fix A — filter:**
```swift
func persona(forHotkey hotkey: String) -> Persona? {
    personas.first { $0.hotkey == hotkey && !$0.hidden }
}
```

**Fix B — delete this method if it has no production callers** (and the test that covers it) — dead-code reduction is preferable to fixing dead code.

### WR-05: `PersonaStore` has no documented thread affinity and no synchronization

**File:** `Sources/KeyMic/LLM/PersonaStore.swift` (whole class)
**Issue:**
`personas` (`var [Persona]`) and `activePersonaId` (`var String?`) are mutated by `setActive` / `add` / `update` / `delete` / `duplicate` / `load` and read by `visiblePersonas` / `allPersonas` / `persona(id:)` / `activePersona` / `shortcutConfigPersona`. In production these are de-facto main-thread-only (event-tap callback runs on `CFRunLoopGetMain()`, AppDelegate runs on main, PersonasView is `@MainActor`), so today it is safe — but the class has no `@MainActor` annotation, no DispatchQueue, no comment, and no precondition. The next refactor that calls `PersonaStore.shared.visiblePersonas` from a `URLSession.shared.dataTask` completion handler (LLMRefiner, perhaps) will hit a Swift array data race.

**Fix:** Annotate the class `@MainActor` (it already only mutates on main) and let the compiler enforce the invariant:
```swift
@MainActor
final class PersonaStore { ... }
```
KeyMonitor's event-tap callback is on the main thread, so reads/writes from it continue to compile. The `personasProvider` closure in `HotkeySettingsStore.shared` will need a `MainActor.assumeIsolated` shim or to flip the store to `@MainActor` as well.

### WR-06: `mergeWithBuiltIns` ignores envelope `version`, ignoring future schema migrations

**File:** `Sources/KeyMic/LLM/PersonaStore.swift:111-117, 145-162`
**Issue:**
`Envelope` carries `version: Int`, hard-coded to `currentVersion = 1`, and `load()` does not branch on it. Phase 01 added a new field (`hidden`) without bumping the version, relying on `decodeIfPresent(Bool.self, forKey: .hidden) ?? false` for backwards compat. That works once. A second additive field with a different default, or any non-additive change, will silently mis-load older envelopes because there's no schema-version dispatcher. The clipboard subsystem solved this with `clipboardSchemaVersion` + an explicit wipe path (`AppDelegate.swift:130-137`); persona persistence has none.

**Fix:** Add a comment block — or, ideally, a tiny `case version` switch — establishing the migration discipline now while the schema only has one version:
```swift
private func load() {
    // ...
    let envelope = try Self.decoder.decode(Envelope.self, from: data)
    switch envelope.version {
    case Self.currentVersion: break              // current
    case ..<Self.currentVersion:
        // No migrations yet — Phase 01 added `hidden` additively via
        // decodeIfPresent. Future schema breaks must bump currentVersion
        // and add a case here.
        break
    default:
        logger.error("envelope.version \(envelope.version) > currentVersion \(Self.currentVersion); reseeding")
        seedFirstLaunch()
        return
    }
    // ...
}
```

## Info

### IN-01: Silent rejection in `setActive(hidden id)` is undebuggable

**File:** `Sources/KeyMic/LLM/PersonaStore.swift:56-65`
**Issue:**
`if p.hidden { return }` returns with no `logger.error` / `logger.warning`. The only callers today are `AppDelegate.togglePersona` and `KeyMonitor` persona push-to-talk, neither of which can construct the hidden id from UI — but if a future caller (Phase 6 shortcut-config flow, deeplinks, test fixtures) accidentally passes it, debugging will require code reading rather than log inspection. Cheap insurance.

**Fix:**
```swift
if p.hidden {
    logger.warning("setActive(_:) rejected hidden persona id=\(id, privacy: .public)")
    return
}
```

### IN-02: Persona equality on `createdAt`/`updatedAt` makes test fixtures brittle

**File:** `Sources/KeyMic/LLM/Persona.swift:15` (`Equatable` synthesized) ↔ `Tests/PersonaTests.swift:21` (`decoded == p`)
**Issue:**
`Persona: Equatable` is synthesized over all stored properties, including `createdAt` / `updatedAt`. The current `PersonaTests` round-trip uses fixed timestamps so this works, but the JSON date strategy round-trips through ISO8601 with fractional seconds (`.withFractionalSeconds`) at decoder/encoder level: any `Date` whose sub-millisecond fraction is non-zero (e.g., `Date()` in real callsites) loses precision and breaks `==` after round-trip. Not exercised today, but will fail the moment someone writes `let p = Persona(... createdAt: Date(), updatedAt: Date())` followed by encode/decode/expect-equal. Worth noting.

**Fix (none required — informational).** If future tests construct personas with `Date()`, they should compare field-by-field, or both sides should be re-normalized through `ISO8601DateFormatter` first.

---

_Reviewed: 2026-05-19_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_

## Fix Log

**Fixes applied:** 2026-05-19T12:28:00+10:00
**Scope:** Critical + Warning (default; Info IN-01, IN-02 deferred)
**In-scope findings:** 8 (CR-01, CR-02, WR-01..WR-06)
**Fixed:** 7
**Skipped:** 1 (WR-05 — broad cascade out of scope; see entry)

### Fixed Issues

| # | Finding | Commit | Files modified | Description |
|---|---------|--------|----------------|-------------|
| 1 | CR-01 | `a514973` | `Sources/KeyMic/LLM/PersonaStore.swift`, `Tests/PersonaHiddenTests.swift` | `load()` now nullifies `activePersonaId` when the on-disk value points at a hidden persona, mirroring the runtime `setActive` guard. Added D-10 #7 regression test (`testActivePersonaIdHiddenIsNullifiedOnLoad`). |
| 2 | CR-02 | `01be249` | `Sources/KeyMic/LLM/PersonaStore.swift`, `Tests/PersonaHiddenTests.swift` | `mergeWithBuiltIns` now restores `name` from seed (Option A — matches docstring + UI intent). Updated `testReMergeOverridesHiddenFromSeed` to assert `name == "Shortcut Config"`. |
| 3 | WR-01 | `3eb126f` | `Tests/PersonaTests.swift` | Added explicit `hidden: true` Codable round-trip case. |
| 4 | WR-02 | `d78dbff` | `Sources/KeyMic/LLM/PersonaStore.swift` | `setActive(_:)` guards both branches against redundant same-state writes. Eliminates write amplification + redundant `didChangeNotification` posts on `togglePersona`-deselect and "Clear Default" button flows. |
| 5 | WR-03 | `c1f4599` | `Sources/KeyMic/LLM/PersonaStore.swift` | `duplicate(id:)` rejects hidden source personas (Fix A — `guard !source.hidden`). |
| 6 | WR-04 | `c9750d3` | `Sources/KeyMic/LLM/PersonaStore.swift`, `Tests/PersonaStoreTests.swift` | Removed dead `persona(forHotkey:)` method + the three corresponding test assertions (Fix B — zero production callers; dead-code reduction preferable to fixing dead code). |
| 7 | WR-06 | `ad5332e` | `Sources/KeyMic/LLM/PersonaStore.swift` | Added `switch envelope.version` block in `load()` to establish the schema-migration discipline now while the schema has only one version. Future > currentVersion bumps log + reseed. |

### Skipped Issues

#### WR-05: `PersonaStore` `@MainActor` annotation

**File:** `Sources/KeyMic/LLM/PersonaStore.swift` (class-level)
**Reason:** Fix caused a broad cascade across 4 source files (AppDelegate, KeyMonitor, HotkeySettingsStore, SettingsRoot) and 19 callsites. The suggested fix ("annotate the class `@MainActor` and let the compiler enforce") works in isolation, but `HotkeySettingsStore.shared` captures `PersonaStore.shared.visiblePersonas` in a nonisolated closure, which then needs `@MainActor` propagation. Annotating `HotkeySettingsStore` as `@MainActor` then cascades into KeyMonitor's `reloadHotkeys()` (event-tap CFRunLoop callback, nonisolated by Swift's actor model), AppDelegate's `syncPersonaHotkeysToRegistry()`, `finishTranscription()`, `rebuildPersonasMenu()`, `togglePersona()`, `applyVoiceShortcut()`, `applySettingsShortcut()`, and SettingsRoot's hotkey-binding helpers.

The cascade requires choosing between:
- Annotating `AppDelegate` (`NSObject, NSApplicationDelegate`) as `@MainActor` (canonical Swift pattern but adopts Swift 6 main-actor model project-wide for the delegate)
- Using `MainActor.assumeIsolated` shims at 10+ callsites (verbose; pollutes Phase-2+ subsystems)

Both are valid responses but the choice is an architectural decision (Swift 6 main-actor adoption strategy) rather than a localized fix, and exceeds the scope of an automated review-fix pass touching only `Sources/KeyMic/LLM/`. The original observation stands — `PersonaStore` is de-facto main-thread-only today — but compile-time enforcement requires a coordinated project-wide refactor.

Rollback method: `git checkout --` on `Sources/KeyMic/LLM/PersonaStore.swift` + `Sources/KeyMic/Hotkey/HotkeySettingsStore.swift` (no commits made for WR-05). Baseline `swift build` verified clean post-rollback.

**Recommendation:** Defer WR-05 to a future "Swift 6 main-actor adoption" phase that coordinates the entire app delegate + event-tap surface.

### Deferred (out of scope, no fix attempted)

- **IN-01** (silent rejection in `setActive(hidden id)` is undebuggable) — Info severity; default scope is Critical + Warning only.
- **IN-02** (Persona equality on createdAt/updatedAt makes test fixtures brittle) — Info severity; documented as informational, no fix required.

### Verification

After all fixes:
- `swift build` → exit 0
- `make test-persona` → `✅ PersonaTests passed`
- `make test-persona-store` → `✅ PersonaStoreTests passed`
- `make test-persona-hidden` → `✅ PersonaHiddenTests passed` (incl. new D-10 #7 case)
- `make test-clipboard-store` → `ClipboardStoreTests passed` (regression)
- `make test-clipboard-monitor` → `ClipboardMonitorTests passed` (regression)

_Fixes applied: 2026-05-19_
_Fixer: Claude (gsd-code-fixer)_
