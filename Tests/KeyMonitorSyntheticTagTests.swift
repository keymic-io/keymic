import Foundation
import CoreGraphics

// Plan 04-06 Task 2 — KeyMonitor synthetic-tag round-trip + early-return
// wiring verification.
//
// Covers ROADMAP Phase 4 success criterion 4 ("synthesized event is
// tagged and early-returned at KeyMonitor.handle, no re-entry into voice
// path") via four standalone tests:
//
//   1. testTaggedEventCarriesKeymicTag        — source.userData setter
//                                                round-trip via getInteger…
//   2. testUntaggedEventReturnsZeroOrUnequal  — baseline (no tagging)
//   3. testKeyDownAndKeyUpInheritSourceTag    — Apple-canonical pattern:
//                                                tagging the SOURCE
//                                                propagates to every event
//                                                created from it
//   4. testSyntheticEventTagEarlyReturnsFromKeyMonitor (NEW — B-1 fix):
//        (a) positive: HotkeyEventTagging.isSynthetic(taggedEvent) == true
//        (b) negative: HotkeyEventTagging.isSynthetic(untaggedEvent) == false
//        (c) source-grep: KeyMonitor.swift contains exactly one
//            `if HotkeyEventTagging.isSynthetic` line, the next non-blank
//            non-comment line contains `return Unmanaged.passRetained`,
//            and the early-return appears BEFORE `tapDisabledByTimeout`.
//
// This runner does NOT compile KeyMonitor.swift — the source-grep check
// reads it from disk as a string. The Makefile rule's compile-set is
// minimal: HotkeyEventTagging.swift + this test file.
//
// The runner MUST be invoked with the repo root as cwd so the relative
// path `Sources/KeyMic/KeyMonitor.swift` resolves. The Makefile invokes
// the host binary without `cd`, so the default `pwd` (== repo root)
// satisfies this.

@main
struct KeyMonitorSyntheticTagTestRunner {
    static func main() throws {
        try testTaggedEventCarriesKeymicTag()
        try testUntaggedEventReturnsZeroOrUnequal()
        try testKeyDownAndKeyUpInheritSourceTag()
        try testSyntheticEventTagEarlyReturnsFromKeyMonitor()

        print("KeyMonitorSyntheticTagTests passed")
    }

    // MARK: - 1. positive round-trip

    /// Setting `source.userData = KEYMIC_SYNTHETIC_TAG` tags the source;
    /// events created from the source carry the tag in
    /// `.eventSourceUserData`. The Swift bridge for the now-deprecated C
    /// symbol `CGEventSourceSetUserData(_:_:)` is the `userData` property —
    /// the same pattern used by `HotkeyActionRunner.defaultKeyPress`.
    private static func testTaggedEventCarriesKeymicTag() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fail("CGEventSource(stateID: .combinedSessionState) returned nil — test infrastructure broken")
        }
        source.userData = KEYMIC_SYNTHETIC_TAG

        // ANSI_A virtual keycode = 0x00.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x0, keyDown: true) else {
            fail("CGEvent(keyboardEventSource:…) returned nil — test infrastructure broken")
        }
        let read = event.getIntegerValueField(.eventSourceUserData)
        expect(read == KEYMIC_SYNTHETIC_TAG,
               "tagged event must carry KEYMIC_SYNTHETIC_TAG (expected \(KEYMIC_SYNTHETIC_TAG), got \(read))")

        print("testTaggedEventCarriesKeymicTag: ok")
    }

    // MARK: - 2. negative baseline

    /// An untagged source's events return 0 (or any value != KEYMIC_SYNTHETIC_TAG).
    private static func testUntaggedEventReturnsZeroOrUnequal() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fail("CGEventSource(stateID: .combinedSessionState) returned nil")
        }
        // Deliberately do NOT set `source.userData`.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x0, keyDown: true) else {
            fail("CGEvent(keyboardEventSource:…) returned nil")
        }
        let read = event.getIntegerValueField(.eventSourceUserData)
        expect(read != KEYMIC_SYNTHETIC_TAG,
               "untagged event must NOT carry KEYMIC_SYNTHETIC_TAG (got \(read))")

        print("testUntaggedEventReturnsZeroOrUnequal: ok")
    }

    // MARK: - 3. Apple-canonical inheritance

    /// Per Apple CGEventSource.h: a single tagged source propagates the
    /// userData field to EVERY event created from it — keyDown AND keyUp
    /// alike. This is the reason Plan 04-02 used source-side tagging vs
    /// per-event `setIntegerValueField` (single call, no two-sites risk).
    private static func testKeyDownAndKeyUpInheritSourceTag() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fail("CGEventSource(stateID: .combinedSessionState) returned nil")
        }
        source.userData = KEYMIC_SYNTHETIC_TAG

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: 0x0, keyDown: false)
        else {
            fail("CGEvent down/up construction returned nil")
        }
        let downTag = down.getIntegerValueField(.eventSourceUserData)
        let upTag = up.getIntegerValueField(.eventSourceUserData)
        expect(downTag == KEYMIC_SYNTHETIC_TAG,
               "keyDown event inherits source tag (got \(downTag))")
        expect(upTag == KEYMIC_SYNTHETIC_TAG,
               "keyUp event inherits source tag (got \(upTag))")

        print("testKeyDownAndKeyUpInheritSourceTag: ok")
    }

    // MARK: - 4. End-to-end early-return wiring (B-1 fix)

    /// Three-part assertion that combines a predicate round-trip with a
    /// source-grep gate on `Sources/KeyMic/KeyMonitor.swift`. Together
    /// these prove ROADMAP Phase 4 SC 4 end-to-end without compiling
    /// KeyMonitor.swift into the test binary:
    ///
    ///   (a) The SHARED predicate `HotkeyEventTagging.isSynthetic(_:)`
    ///       returns true for a tagged event.
    ///   (b) The SAME predicate returns false for an untagged event.
    ///   (c) `KeyMonitor.handle` body contains exactly one
    ///       `if HotkeyEventTagging.isSynthetic` line; the next non-blank
    ///       non-comment line contains `return Unmanaged.passRetained`;
    ///       the early-return appears BEFORE the `tapDisabledByTimeout`
    ///       check (matching Plan 04-02 Task 3 done-criterion).
    private static func testSyntheticEventTagEarlyReturnsFromKeyMonitor() throws {
        // ---- (a) positive predicate ----
        guard let posSource = CGEventSource(stateID: .combinedSessionState) else {
            fail("CGEventSource (positive) returned nil")
        }
        posSource.userData = KEYMIC_SYNTHETIC_TAG
        guard let posEvent = CGEvent(keyboardEventSource: posSource, virtualKey: 0x0, keyDown: true) else {
            fail("CGEvent (positive) returned nil")
        }
        expect(HotkeyEventTagging.isSynthetic(posEvent) == true,
               "HotkeyEventTagging.isSynthetic returns true for tagged event")

        // ---- (b) negative predicate ----
        guard let negSource = CGEventSource(stateID: .combinedSessionState) else {
            fail("CGEventSource (negative) returned nil")
        }
        // Deliberately do NOT tag.
        guard let negEvent = CGEvent(keyboardEventSource: negSource, virtualKey: 0x0, keyDown: true) else {
            fail("CGEvent (negative) returned nil")
        }
        expect(HotkeyEventTagging.isSynthetic(negEvent) == false,
               "HotkeyEventTagging.isSynthetic returns false for untagged event")

        // ---- (c) source-grep gate ----
        let keyMonitorPath = "Sources/KeyMic/KeyMonitor.swift"
        let keyMonitorURL = URL(fileURLWithPath: keyMonitorPath)
        let source: String
        do {
            source = try String(contentsOf: keyMonitorURL, encoding: .utf8)
        } catch {
            fail("could not read \(keyMonitorPath) — cwd is '\(FileManager.default.currentDirectoryPath)' "
                 + "(error: \(error.localizedDescription)). Makefile rule must invoke the host binary from repo root.")
        }

        let lines: [String] = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Production-line filter: drop blank lines AND single-line comments.
        // Inline `// …` comments on a code line are kept because the code
        // portion still counts as a production line.
        func isCommentOrBlank(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            if trimmed.hasPrefix("//") { return true }
            return false
        }

        // (c1) Exactly one production line matches `if HotkeyEventTagging.isSynthetic`.
        let matchIndices: [Int] = lines.enumerated().compactMap { (idx, line) in
            if isCommentOrBlank(line) { return nil }
            return line.contains("if HotkeyEventTagging.isSynthetic") ? idx : nil
        }
        if matchIndices.count != 1 {
            fail("expected EXACTLY ONE production line matching 'if HotkeyEventTagging.isSynthetic' in "
                 + "\(keyMonitorPath); got \(matchIndices.count). Offending indices: \(matchIndices). "
                 + "Lines: \(matchIndices.map { "[\($0)] \(lines[$0])" })")
        }
        let earlyReturnIdx = matchIndices[0]

        // (c2) The next non-blank non-comment line contains `return Unmanaged.passRetained`.
        // The early-return may be on the SAME line as the if (Plan 04-02 lands it
        // as a one-liner: "if HotkeyEventTagging.isSynthetic(event) { return Unmanaged.passRetained(event) }"),
        // in which case the SAME line satisfies the requirement.
        let matchLine = lines[earlyReturnIdx]
        if matchLine.contains("return Unmanaged.passRetained") {
            // Single-line form — early-return is on the if-line itself. Pass.
        } else {
            // Multi-line form — walk forward to find the next non-blank,
            // non-comment line and verify it contains the return.
            var nextIdx: Int? = nil
            var i = earlyReturnIdx + 1
            while i < lines.count {
                if !isCommentOrBlank(lines[i]) {
                    nextIdx = i
                    break
                }
                i += 1
            }
            guard let n = nextIdx else {
                fail("no production line follows the early-return at index \(earlyReturnIdx) "
                     + "in \(keyMonitorPath); line was: '\(matchLine)'")
            }
            let nextLine = lines[n]
            if !nextLine.contains("return Unmanaged.passRetained") {
                fail("expected next non-blank non-comment line after index \(earlyReturnIdx) "
                     + "to contain 'return Unmanaged.passRetained' in \(keyMonitorPath); "
                     + "got line [\(n)]: '\(nextLine)'. The if-line was [\(earlyReturnIdx)]: '\(matchLine)'.")
            }
        }

        // (c3) Early-return index < first index containing `tapDisabledByTimeout`.
        // This proves Plan 04-02 Task 3 — the synthetic-tag check is wired
        // at the very TOP of `handle`, before the existing tap-disabled
        // early-return.
        guard let tapDisabledIdx = lines.firstIndex(where: { $0.contains("tapDisabledByTimeout") }) else {
            fail("could not locate 'tapDisabledByTimeout' marker in \(keyMonitorPath) — "
                 + "Plan 04-02 ordering invariant cannot be verified")
        }
        expect(earlyReturnIdx < tapDisabledIdx,
               "synthetic-tag early-return must appear BEFORE 'tapDisabledByTimeout' (early-return idx=\(earlyReturnIdx), tapDisabled idx=\(tapDisabledIdx))")

        print("testSyntheticEventTagEarlyReturnsFromKeyMonitor: ok")
    }

    // MARK: - Helpers (verbatim project-wide test idiom from Tests/ShortcutYAMLImporterTests.swift:1014-1026)

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
