---
status: partial
phase: 01-persona-schema-hidden-persona-centralization
source: [01-VERIFICATION.md]
started: 2026-05-19T00:08:00Z
updated: 2026-05-19T00:08:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Settings → Personas list omits `Shortcut Config`
expected: Launch built KeyMic.app, open Settings → Personas tab. The list shows only `Default`, `Auto Translate`, `CLI Wizard`, `Context`. `Shortcut Config` does NOT appear.
result: [pending]

### 2. Menu-bar persona switcher omits `Shortcut Config`
expected: Click the KeyMic menu-bar icon, hover/expand the persona submenu. It shows 4 visible persona rows; `Shortcut Config` is NOT present.
result: [pending]

### 3. Hotkey settings for persona-hotkey assignment omits `Shortcut Config`
expected: Open Settings → Shortcuts (or wherever persona-hotkey assignment lives). No row, picker, or sheet allows assigning a hotkey to `Shortcut Config`.
result: [pending]

### 4. Tampered `personas.json` repairs on relaunch
expected: Quit KeyMic. Open `~/Library/Application Support/KeyMic/personas.json` in a text editor and set `hidden = false` on the `builtin-shortcut-config` entry. Relaunch KeyMic. Re-open the file (or invoke the in-app debug surface if available) and confirm `hidden` is back to `true` for that entry, AND that `Shortcut Config` still does NOT appear in any visible UI list.
result: [pending]

## Summary

total: 4
passed: 0
issues: 0
pending: 4
skipped: 0
blocked: 0

## Gaps
