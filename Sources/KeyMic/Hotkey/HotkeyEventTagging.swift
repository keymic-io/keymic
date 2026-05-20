import CoreGraphics

// MARK: - KEYMIC_SYNTHETIC_TAG

/// Defense-in-depth tag carried on every CGEvent synthesized by
/// `HotkeyActionRunner.defaultKeyPress`. `KeyMonitor.handle` reads the
/// same value at the top of its cgEventCallback and early-returns to
/// break the self-trigger feedback loop — even if Phase 3's importer-
/// layer rejection (IMP-05) fails to catch a future broken binding.
///
/// Set via `CGEventSourceSetUserData(source, KEYMIC_SYNTHETIC_TAG)` ONCE
/// per source construction in `HotkeyActionRunner.defaultKeyPress`; both
/// the `keyDown` and `keyUp` CGEvents derived from that source inherit
/// the tag automatically per Apple's `CGEventSource.h` contract — this
/// is the canonical pattern (vs per-event `setIntegerValueField`, which
/// is fragile and easy to forget on a future second post site).
///
/// Read via `event.getIntegerValueField(.eventSourceUserData)`, wrapped
/// inside `HotkeyEventTagging.isSynthetic(_:)` so there is exactly ONE
/// definition of the predicate in the source tree.
///
/// Scope is `internal` (default module visibility): `KeyMonitor.handle`
/// + `HotkeyActionRunner.defaultKeyPress` + future
/// `Tests/KeyMonitorSyntheticTagTests.swift` need read/write access;
/// no `public` modifier is required because every consumer compiles
/// into the same Swift module.
///
/// Collisions with other CGEventField user-data writers are vanishingly
/// unlikely (1 in 2^64). The literal `0x4B6E_7950_4D69_4373` is the
/// ASCII byte sequence for `"KnyPMiCs"` (mnemonic only — the value is
/// not security-sensitive; an attacker who can synthesize CGEvents
/// reaching our session tap already has larger capabilities than the
/// tag protects against).
let KEYMIC_SYNTHETIC_TAG: Int64 = 0x4B6E_7950_4D69_4373    // "KnyPMiCs" ASCII

// MARK: - HotkeyEventTagging

/// Caseless enum acting as a namespace for the synthetic-tag predicate.
/// Callers write `HotkeyEventTagging.isSynthetic(event)` — clearer at
/// call sites than a free function and unambiguously sourced from this
/// file when grepped.
///
/// The predicate is centralised here so production (`KeyMonitor.handle`)
/// and tests reuse the SAME implementation — no string-literal divergence,
/// no two-sites-must-stay-in-sync anti-pattern. The function is `static`
/// and pure (no side effects, no allocations) so it is safe to call from
/// the cgEventCallback hot path.
enum HotkeyEventTagging {
    /// Single source of truth for the synthetic-tag predicate.
    /// Used by `KeyMonitor.handle` (production early-return) AND by
    /// the optional `Tests/KeyMonitorSyntheticTagTests.swift` runner —
    /// both call sites must agree on the predicate by construction.
    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == KEYMIC_SYNTHETIC_TAG
    }
}
