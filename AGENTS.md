# AGENTS.md

KeyMic-specific gotchas for macOS event tap / HID work. Read before touching `KeyMonitor.swift` or related event handling.

## Apple keyboard arrow/fn-row keys carry `.maskSecondaryFn`

On Apple keyboards, regular `keyDown` events for arrow keys, function row, and the navigation cluster are emitted **with `.maskSecondaryFn` already set** in `event.flags`. This is hardware behavior, not something that requires holding Fn.

**Wrong:**
```swift
let fnPressed = event.flags.contains(.maskSecondaryFn)  // false positive on every arrow keydown
```

**Right:** Track Fn state from `flagsChanged` events filtered by `keyCode == 0x3F` (kVK_Function). Only that event indicates a real Fn transition.

```swift
if type == .flagsChanged {
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    if keyCode == 0x3F {
        fnDown = event.flags.contains(.maskSecondaryFn)
    }
}
```

Same pattern applies to other modifiers when distinguishing left vs right (e.g., right Option = 0x3D, right Cmd = 0x36, right Shift = 0x3C). The shared mask flags (`.maskAlternate`, `.maskCommand`, `.maskShift`) cannot tell sides apart — use the keyCode in the flagsChanged event.

## Modifier-key sources don't auto-repeat

When remapping a modifier (e.g., Right Cmd) to a regular key (e.g., Forward Delete), holding the modifier produces **only two `flagsChanged` events** — one on press, one on release. There is no auto-repeat from the OS because the source is a modifier.

Synthesizing a single `keyDown` from the press won't repeat either. The OS only auto-repeats keyDowns originating from real HID hardware.

**Fix:** Run a `DispatchSourceTimer` while the source is held. Post repeat events with the autorepeat field set:

```swift
let event = CGEvent(keyboardEventSource: source, virtualKey: targetKeyCode, keyDown: true)
event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
event?.post(tap: .cghidEventTap)
```

Initial delay ~0.4s, repeat ~0.05s matches macOS defaults closely enough.

## Synthetic Caps Lock keyDown does NOT toggle system state

Posting a `CGEvent` with `virtualKey: 0x39` (Caps Lock) and `.maskAlphaShift` does **not** flip the system Caps Lock state, the LED, or the `kIOHIDCapsLockState` HID flag. Caps Lock state is owned by the IOKit HID layer, below the session event tap.

**Fix:** Call IOKit directly. Skip the synthetic event entirely.

```swift
import IOKit
import IOKit.hid
import IOKit.hidsystem

var connect: io_connect_t = 0
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
guard service != 0 else { return }
defer { IOObjectRelease(service) }
let kr = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
guard kr == KERN_SUCCESS else { return }
defer { IOServiceClose(connect) }

var state = false
IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
```

`kIOMainPortDefault` requires macOS 12+. Project targets macOS 14, fine. Use `kIOMasterPortDefault` if backporting.

## flagsChanged toggle semantics for modifier keyDown/keyUp

`flagsChanged` events do not carry a "is down" boolean. The same event type fires on press and release. Two reliable ways to derive state:

1. **Track per-keyCode set:** maintain `Set<CGKeyCode>` of currently-down modifier keys. On each `flagsChanged` for a tracked keyCode, toggle membership.
2. **Read flag bit from `event.flags`:** works only for the modifier whose dedicated keyCode just fired. E.g., Fn keyCode 0x3F + check `.maskSecondaryFn` in flags. Don't rely on this for shared masks (shift/cmd/alt/ctrl) without keyCode filtering.

## Event tap layers

- `.cgSessionEventTap` (used here): per-user-session, sees logical keyboard events. Good for remap.
- `.cghidEventTap`: lowest layer. Posting here makes events visible to your own session tap too — guard against re-entry by ensuring posted keyCodes don't have mappings.

## Reset safety (Milestone 1)

- `KeyMonitor.resetAllInputState(reason:)` is the single entry point for clearing
  trigger state, held modifiers, remapped-key-down state, and repeat timers. Call
  it from any code path that may leave input state inconsistent: tap-disabled
  notifications, Secure Input enter, settings reload, app stop.
- The event tap may be disabled by macOS (`.tapDisabledByTimeout` /
  `.tapDisabledByUserInput`) when the callback is too slow. `KeyMonitor` logs
  these via `os.Logger` (`subsystem=io.keymic.app`, `category=KeyMonitor`),
  resets state, then re-enables the tap. Do **not** add work to the callback path
  without checking that it remains fast.
- Secure Input (sudo prompts, password fields, lock screen) can drop key-up
  events from the session tap. `SecureInputMonitor` polls every 200ms and tells
  `KeyMonitor` to suspend hotkey dispatch until Secure Input exits.


## Modifier keys reference

| Key             | keyCode | Flag                |
|-----------------|---------|---------------------|
| Caps Lock       | 0x39    | `.maskAlphaShift`   |
| Left Shift      | 0x38    | `.maskShift`        |
| Right Shift     | 0x3C    | `.maskShift`        |
| Left Control    | 0x3B    | `.maskControl`      |
| Right Control   | 0x3E    | `.maskControl`      |
| Left Option     | 0x3A    | `.maskAlternate`    |
| Right Option    | 0x3D    | `.maskAlternate`    |
| Left Command    | 0x37    | `.maskCommand`      |
| Right Command   | 0x36    | `.maskCommand`      |
| Fn              | 0x3F    | `.maskSecondaryFn`  |


## Github
- always switch to `lorne-luo` first before run gh cmd
<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->
