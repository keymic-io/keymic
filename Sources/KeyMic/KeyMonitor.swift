import Cocoa
import IOKit
import IOKit.hid
import IOKit.hidsystem
import os.log

private let log = Logger(subsystem: "io.keymic.app", category: "KeyMonitor")

final class KeyMonitor {
    var onTriggerDown: (() -> Void)?
    var onTriggerUp: (() -> Void)?
    var onTriggerInterrupted: (() -> Void)?
    var onClipboardHotkey: (() -> Void)?
    var onVaultHotkey: (() -> Void)?
    var onClipboardQuickPaste: ((Int) -> Void)?
    var isClipboardPanelVisible: (() -> Bool)?
    var onSettingsHotkey: (() -> Void)?
    var onScreenshotHotkey: (() -> Void)?
    var onAction: (([HotkeyAction]) -> Void)?
    /// Synchronous, O(1) lookup of the bundle ID KeyMic believes is frontmost.
    /// MUST NOT call into LaunchServices — this runs in the event-tap callback on the
    /// main thread, where any sync XPC stall blocks the entire HID input pipeline.
    /// AppDelegate wires this to a cached value updated via NSWorkspace notifications.
    var currentFrontBundleID: (() -> String?)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Periodic main-queue probe that re-enables (or fully rebuilds) the event tap
    /// if it has been silently disabled — covers cases where the system stops
    /// delivering `tapDisabledByTimeout` callbacks at all (e.g. across wake from
    /// sleep, prolonged main-thread stalls). Without this, a single timeout can
    /// kill every hotkey path until the user quits and relaunches.
    private var healthCheckTimer: DispatchSourceTimer?
    private let healthCheckInterval: TimeInterval = 5
    /// Lifecycle guard for recovery paths. A queued health-check tick can fire
    /// after `stop()` cancels its timer; without this flag the recovery code
    /// would happily reinstall a tap on a stopped monitor.
    private var isRunning = false
    private var state = InputState()
    /// When `true`, app-level hotkey dispatch (clipboard/vault/settings/screenshot/persona/action/voice trigger)
    /// is bypassed. Set on Secure Input enter, cleared on Secure Input exit.
    /// Physical events still pass through unchanged.
    private var secureInputSuspended = false
    private var clipboardHotkey: HotkeyConfig?
    private var vaultHotkey: HotkeyConfig?
    private var settingsHotkey: HotkeyConfig?
    private var screenshotHotkey: HotkeyConfig?
    private var voiceTriggerHotkey: HotkeyConfig?
    private var actionBindings: [(config: HotkeyConfig, actions: [HotkeyAction], appBundleIDs: [String])] = []
    private var repeatTimers: [CGKeyCode: DispatchSourceTimer] = [:]
    private let keyMappingManager: KeyMappingManager

    private let initialRepeatDelay: TimeInterval = 0.4
    private let repeatInterval: TimeInterval = 0.05

    init(keyMappingManager: KeyMappingManager = .shared) {
        self.keyMappingManager = keyMappingManager
    }

    /// Start monitoring. Returns false if accessibility permission is missing.
    func start() -> Bool {
        guard installTap() else { return false }
        isRunning = true
        reloadHotkeys()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        startHealthCheck()
        return true
    }

    func stop() {
        isRunning = false
        stopHealthCheck()
        teardownTap()
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        resetAllInputState(reason: .stop)
    }

    /// Create the event tap + run-loop source and enable it. Idempotent only via
    /// `teardownTap()` first — call sites must ensure no prior tap is installed.
    private func installTap() -> Bool {
        // NX_SUBTYPE_AUX_CONTROL_BUTTONS systemDefined events are the only way
        // to receive F1-F12 when "Use F1, F2… as standard function keys" is
        // disabled in System Settings — F-row keyDowns are never generated.
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << HotkeyConfig.cgSystemDefinedRawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    /// Tear down the current tap and create a fresh one. Used when
    /// `CGEvent.tapEnable(..., true)` alone fails to revive a tap that was
    /// disabled by timeout — observed empirically after long main-thread stalls
    /// (e.g. ReplayKit / system sleep). Must run on the main queue so it doesn't
    /// race with the tap callback (which runs on the main run loop).
    ///
    /// Always clears `state`/timers via `resetAllInputState(.tapRebuild)` before
    /// reinstalling. Otherwise stale modifier/persona/repeat state from before
    /// the tap died would survive into the new tap and produce phantom key
    /// repeats, stuck push-to-talk, or combos matched against ghost modifiers.
    private func rebuildTap() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning else { return }
        resetAllInputState(reason: .tapRebuild)
        teardownTap()
        let ok = installTap()
        log.notice("event tap rebuild result success=\(ok, privacy: .public)")
    }

    private func startHealthCheck() {
        stopHealthCheck()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + healthCheckInterval, repeating: healthCheckInterval)
        timer.setEventHandler { [weak self] in self?.healthCheck() }
        timer.resume()
        healthCheckTimer = timer
    }

    private func stopHealthCheck() {
        healthCheckTimer?.cancel()
        healthCheckTimer = nil
    }

    private func healthCheck() {
        guard isRunning else { return }
        guard let tap = eventTap else {
            log.notice("health check — eventTap is nil, rebuilding")
            rebuildTap()
            return
        }
        if CGEvent.tapIsEnabled(tap: tap) { return }
        log.notice("health check — tap disabled, re-enabling")
        // Tap was silently disabled — same lost-events contract as the
        // tapDisabledByTimeout callback path. Clear state before re-enabling.
        resetAllInputState(reason: .tapHealthCheckReenable)
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            log.notice("health check — re-enable failed, rebuilding")
            rebuildTap()
        }
    }

    /// Central reset for every piece of mutable input state owned by `KeyMonitor`.
    /// MUST be called whenever the event tap may have lost events (timeout, user
    /// input, Secure Input enter, settings reload, stop). Idempotent.
    func resetAllInputState(reason: InputResetReason) {
        let priorTimerCount = repeatTimers.count
        let prior = state.resetTransient()
        cancelAllRepeatTimers()

        // Interrupt any active voice session — fn-held trigger OR persona-hotkey
        // push-to-talk. AppDelegate's cancelRecording is idempotent so a single
        // notification covers both sources.
        if prior.triggerActive || prior.personaHotkeyKeyDown != nil {
            DispatchQueue.main.async { [weak self] in self?.onTriggerInterrupted?() }
        }

        log.info("resetAllInputState reason=\(reason.rawValue, privacy: .public) trigger=\(prior.triggerActive, privacy: .public) heldMods=\(prior.heldModifiers.count, privacy: .public) remappedDown=\(prior.remappedKeysDown.count, privacy: .public) timers=\(priorTimerCount, privacy: .public) personaHotkey=\(prior.personaHotkeyKeyDown != nil, privacy: .public)")
    }

    func onSecureInputEnter() {
        log.info("Secure Input active — suspending hotkey dispatch and resetting state")
        secureInputSuspended = true
        resetAllInputState(reason: .secureInputEnter)
    }

    func onSecureInputExit() {
        log.info("Secure Input inactive — resuming hotkey dispatch")
        secureInputSuspended = false
    }

    @objc private func userDefaultsChanged() {
        reloadHotkeys()
    }

    private func reloadHotkeys() {
        let hotkeys = HotkeySettingsStore.shared
        clipboardHotkey = hotkeys.hotkey(for: .clipboardPanel)
        vaultHotkey = hotkeys.hotkey(for: .vaultPanel)
        settingsHotkey = hotkeys.hotkey(for: .settingsWindow)
        screenshotHotkey = hotkeys.hotkey(for: .screenshot)
        voiceTriggerHotkey = hotkeys.hotkey(for: .voiceTrigger)
        actionBindings = HotkeyBindingsStore.shared.bindings.compactMap { b in
            guard b.enabled,
                  let cfg = HotkeyConfig.parse(b.trigger),
                  !cfg.isPureModifier
            else { return nil }
            return (cfg, b.actions, b.appBundleIDs)
        }
    }

    static func clipboardPanelQuickPasteIndex(keyCode: CGKeyCode, flags: CGEventFlags) -> Int? {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
        guard flags.intersection(mask) == .maskAlternate else { return nil }

        switch keyCode {
        case 0x12: return 0
        case 0x13: return 1
        case 0x14: return 2
        case 0x15: return 3
        case 0x17: return 4
        case 0x16: return 5
        case 0x1A: return 6
        case 0x1C: return 7
        case 0x19: return 8
        case 0x1D: return 9
        default: return nil
        }
    }

    // MARK: - Private

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason: InputResetReason = (type == .tapDisabledByTimeout)
                ? .tapDisabledByTimeout
                : .tapDisabledByUserInput
            log.error("event tap disabled reason=\(reason.rawValue, privacy: .public) — resetting state and re-enabling")
            resetAllInputState(reason: reason)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                let stillEnabled = CGEvent.tapIsEnabled(tap: tap)
                // `.notice` (not `.info`) so the result actually persists in the
                // unified log — `.info` is memory-only by default and made this
                // exact failure mode invisible in past incidents.
                log.notice("event tap re-enable result enabled=\(stillEnabled, privacy: .public)")
                if !stillEnabled {
                    // tapEnable alone can't always revive a tap killed by a long
                    // main-thread stall. Tear down + recreate on the main queue
                    // — must be async because this callback is currently
                    // executing on the run-loop source we're about to remove.
                    DispatchQueue.main.async { [weak self] in self?.rebuildTap() }
                }
            }
            return Unmanaged.passRetained(event)
        }

        if let remapped = remapIfNeeded(type: type, event: event) {
            return remapped
        }

        // NOTE on Secure Input: the prior implementation early-returned here whenever
        // `secureInputSuspended` was true, which killed every hotkey (clipboard, vault,
        // settings, screenshot, action bindings) any time a misbehaving app held Secure
        // Input — Chrome in particular keeps it engaged for long stretches and frequently
        // fails to release. The blanket gate is overkill: single-shot hotkeys read only
        // keyDown and don't care about lost keyUps. The actual risk (lost keyUp leaving
        // a session stuck) only applies to the voice-trigger and persona push-to-talk
        // state machines, so we now gate just those two activation paths below and let
        // single-shot dispatch run normally.

        // Bypass app-level hotkey dispatch while a HotkeyRecorder is capturing input.
        // Forward the raw CGEvent directly to the active recorder — this is more
        // reliable than NSEvent.addLocalMonitorForEvents, which silently drops bare
        // F-row keyDowns and some media-key systemDefined events even when the app
        // is frontmost. Mirrors how skhd captures F1-F12.
        if HotkeyRecorder.isAnyRecording {
            if let recorder = HotkeyRecorder.activeRecorder,
               recorder.handleCGEvent(type: type, event: event) {
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        // Persona push-to-talk: while a persona hotkey is held, every event for
        // its primary key (auto-repeat keyDowns and the final keyUp) must be
        // swallowed. Passing auto-repeats through causes a system beep on every
        // repeat tick because the focused app has no binding for the combo and
        // treats the event as unhandled. Modifier state at release time doesn't
        // have to match the original combo — tracking by primary keyCode is enough.
        if let downKey = state.personaHotkeyKeyDown,
           type == .keyDown || type == .keyUp {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == downKey {
                if type == .keyUp {
                    state.personaHotkeyKeyDown = nil
                    DispatchQueue.main.async { [weak self] in self?.onTriggerUp?() }
                }
                return nil
            }
        }

        if let fKey = HotkeyConfig.decodeMediaFKey(type: type, event: event) {
            if dispatchFRowHotkey(keyCode: fKey, flags: event.flags) {
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1

            if state.triggerActive && !isAutoRepeat {
                DispatchQueue.main.async { [weak self] in self?.onTriggerInterrupted?() }
            }

            if isClipboardPanelVisible?() == true,
               let index = Self.clipboardPanelQuickPasteIndex(keyCode: keyCode, flags: event.flags) {
                DispatchQueue.main.async { [weak self] in self?.onClipboardQuickPaste?(index) }
                return nil
            }

            // Action bindings (skip on autorepeat or disabled)
            if !isAutoRepeat, HotkeyPreferences.enabled {
                let frontBundleID = currentFrontBundleID?()
                for binding in actionBindings {
                    if binding.config.matches(keyCode: keyCode, flags: event.flags) {
                        if !binding.appBundleIDs.isEmpty {
                            guard let bid = frontBundleID, binding.appBundleIDs.contains(bid) else {
                                continue
                            }
                        }
                        let actions = binding.actions
                        DispatchQueue.main.async { [weak self] in self?.onAction?(actions) }
                        return nil
                    }
                }
            }

            // Clipboard hotkey
            if let cfg = clipboardHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags) {
                DispatchQueue.main.async { [weak self] in self?.onClipboardHotkey?() }
                return nil
            }

            // Vault hotkey
            if let cfg = vaultHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags) {
                DispatchQueue.main.async { [weak self] in self?.onVaultHotkey?() }
                return nil
            }

            // Settings hotkey
            if let cfg = settingsHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags) {
                DispatchQueue.main.async { [weak self] in self?.onSettingsHotkey?() }
                return nil
            }

            // Screenshot hotkey
            if let cfg = screenshotHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags),
               UserDefaults.standard.object(forKey: "screenshotEnabled") as? Bool ?? true {
                DispatchQueue.main.async { [weak self] in self?.onScreenshotHotkey?() }
                return nil
            }

            // Persona hotkeys: push-to-talk per persona. Activate the persona and
            // start a voice session; the matching keyUp ends it. Swallow the event
            // to prevent dead-key side effects (e.g. ⌥E → ´). Gate on no other
            // voice session being active so fn-trigger and persona-trigger don't
            // overlap. Also gate on `!secureInputSuspended` so we never *start* a
            // push-to-talk session whose keyUp might be eaten by Secure Input,
            // leaving a session logically stuck. Already-running sessions still
            // get their keyUp handled above — that path is intentionally ungated.
            if !isAutoRepeat,
               !secureInputSuspended,
               state.personaHotkeyKeyDown == nil,
               !state.triggerActive {
                let hotkeys = HotkeySettingsStore.shared
                for persona in PersonaStore.shared.personas {
                    guard let cfg = hotkeys.personaHotkey(personaId: persona.id),
                          !cfg.isPureModifier,
                          cfg.matches(keyCode: keyCode, flags: event.flags) else { continue }
                    let id = persona.id
                    state.personaHotkeyKeyDown = keyCode
                    DispatchQueue.main.async { [weak self] in
                        PersonaStore.shared.setActive(id)
                        self?.onTriggerDown?()
                    }
                    return nil
                }
            }
        }

        // Always call computeTriggerActive so heldModifiers stays in sync, but
        // suppress fn voice trigger callbacks while a persona push-to-talk owns
        // the recording session. Without this guard, pressing fn during a persona
        // hotkey would start a second voice session AppDelegate doesn't gate, and
        // its release would prematurely stop the persona recording.
        let nowActive = computeTriggerActive(type: type, event: event)
        if state.personaHotkeyKeyDown != nil {
            return Unmanaged.passRetained(event)
        }
        // Voice trigger: gate *activation* on `!secureInputSuspended` so we
        // never start a recording session whose release keyUp could be lost,
        // but always honour *deactivation* — if Secure Input toggles on while
        // a session is already running, releasing the trigger must still stop
        // the recording cleanly.
        if nowActive && !state.triggerActive && !secureInputSuspended {
            state.triggerActive = true
            DispatchQueue.main.async { [weak self] in self?.onTriggerDown?() }
            return nil
        } else if !nowActive && state.triggerActive {
            state.triggerActive = false
            DispatchQueue.main.async { [weak self] in self?.onTriggerUp?() }
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    /// Match a synthetic F-row keyDown (built from a systemDefined media-key
    /// event) against the same hotkey set the regular keyDown path checks.
    /// Skips push-to-talk / persona logic — those rely on a paired keyUp that
    /// media events don't deliver.
    private func dispatchFRowHotkey(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        if HotkeyPreferences.enabled {
            let frontBundleID = currentFrontBundleID?()
            for binding in actionBindings {
                if binding.config.matches(keyCode: keyCode, flags: flags) {
                    if !binding.appBundleIDs.isEmpty {
                        guard let bid = frontBundleID, binding.appBundleIDs.contains(bid) else { continue }
                    }
                    let actions = binding.actions
                    DispatchQueue.main.async { [weak self] in self?.onAction?(actions) }
                    return true
                }
            }
        }
        if let cfg = clipboardHotkey, !cfg.isPureModifier, cfg.matches(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.onClipboardHotkey?() }
            return true
        }
        if let cfg = vaultHotkey, !cfg.isPureModifier, cfg.matches(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.onVaultHotkey?() }
            return true
        }
        if let cfg = settingsHotkey, !cfg.isPureModifier, cfg.matches(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.onSettingsHotkey?() }
            return true
        }
        if let cfg = screenshotHotkey, !cfg.isPureModifier,
           cfg.matches(keyCode: keyCode, flags: flags),
           UserDefaults.standard.object(forKey: "screenshotEnabled") as? Bool ?? true {
            DispatchQueue.main.async { [weak self] in self?.onScreenshotHotkey?() }
            return true
        }
        return false
    }

    private func computeTriggerActive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .flagsChanged {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if HotkeyConfig.modifierKeyCodes.contains(keyCode) {
                if keyCode == 0x3F {
                    if event.flags.contains(.maskSecondaryFn) {
                        state.heldModifiers.insert(keyCode)
                    } else {
                        state.heldModifiers.remove(keyCode)
                    }
                } else {
                    if state.heldModifiers.contains(keyCode) {
                        state.heldModifiers.remove(keyCode)
                    } else {
                        state.heldModifiers.insert(keyCode)
                    }
                }
            }
        }

        guard let voice = voiceTriggerHotkey, voice.isPureModifier else { return false }
        return state.heldModifiers.contains(voice.keyCode)
    }

    private func remapIfNeeded(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>?? {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return nil }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard let mapping = keyMappingManager.mapping(for: keyCode),
              let toKeyCode = mapping.toKeyCode else { return nil }

        let isKeyDown = keyIsDown(type: type, keyCode: keyCode, mapping: mapping, event: event)

        // Source = Caps Lock is handled at the HID layer via `HIDRemapper` (hidutil
        // UserKeyMapping). Session-level event taps cannot suppress the HID lock-state
        // toggle, so we don't try to remap Caps Lock here.
        if keyCode == 0x39 { return nil }

        // Special-case: target is Caps Lock toggle. Synthetic 0x39 events do not flip
        // the system Caps Lock state — must call IOKit HID API directly.
        if toKeyCode == 0x39 && mapping.toFlag == .maskAlphaShift {
            if isKeyDown {
                CapsLockToggler.toggle()
            }
            return .some(nil)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let remapped = CGEvent(
            keyboardEventSource: source,
            virtualKey: toKeyCode,
            keyDown: isKeyDown
        ) else {
            return .some(Unmanaged.passRetained(event))
        }
        remapped.flags = remappedFlags(for: event.flags, mapping: mapping, isKeyDown: isKeyDown)

        // Auto-repeat: when target is a non-modifier key (e.g., Forward Delete) and the
        // source is held down, post repeat keyDowns until released.
        if mapping.toFlag == nil {
            if isKeyDown {
                startRepeatTimer(for: keyCode, targetKeyCode: toKeyCode)
            } else {
                stopRepeatTimer(for: keyCode)
            }
        }

        return .some(Unmanaged.passRetained(remapped))
    }

    private func keyIsDown(type: CGEventType, keyCode: CGKeyCode, mapping: KeyMapping, event: CGEvent) -> Bool {
        switch type {
        case .keyDown:
            return true
        case .keyUp:
            return false
        case .flagsChanged:
            let wasDown = state.remappedKeysDown.contains(keyCode)
            let isDown = !wasDown
            if isDown {
                state.remappedKeysDown.insert(keyCode)
            } else {
                state.remappedKeysDown.remove(keyCode)
            }
            return isDown
        default:
            return true
        }
    }

    private func remappedFlags(for flags: CGEventFlags, mapping: KeyMapping, isKeyDown: Bool) -> CGEventFlags {
        var remappedFlags = flags
        if let fromFlag = mapping.fromFlag {
            remappedFlags.remove(fromFlag)
        }
        if isKeyDown, let toFlag = mapping.toFlag {
            remappedFlags.insert(toFlag)
        }
        return remappedFlags
    }

    // MARK: - Repeat timers

    private func startRepeatTimer(for sourceKey: CGKeyCode, targetKeyCode: CGKeyCode) {
        stopRepeatTimer(for: sourceKey)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + initialRepeatDelay, repeating: repeatInterval)
        timer.setEventHandler {
            // Use private state source so the event does NOT inherit physical modifier
            // state (the user is still physically holding the source modifier key, e.g.,
            // Right Cmd). Post at session level to skip HID-level modifier merging, which
            // would otherwise add .maskCommand back onto the synthesized event.
            let source = CGEventSource(stateID: .privateState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: targetKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: targetKeyCode, keyDown: false)
            else { return }
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
        timer.resume()
        repeatTimers[sourceKey] = timer
    }

    private func stopRepeatTimer(for sourceKey: CGKeyCode) {
        repeatTimers[sourceKey]?.cancel()
        repeatTimers.removeValue(forKey: sourceKey)
    }

    private func cancelAllRepeatTimers() {
        for (_, timer) in repeatTimers {
            timer.cancel()
        }
        repeatTimers.removeAll()
    }
}

// MARK: - Caps Lock toggle via IOKit HID

private enum CapsLockToggler {
    static func toggle() {
        var connect: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard kr == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }

        var state: Bool = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state)
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), !state)
    }
}
