import Cocoa
import IOKit
import IOKit.hid
import IOKit.hidsystem
import os.log

private let log = Logger(subsystem: "io.keymic.app", category: "KeyMonitor")

final class KeyMonitor {
    var onTriggerDown: ((VoiceTriggerSource) -> Void)?
    var onTriggerUp: (() -> Void)?
    var onTriggerInterrupted: (() -> Void)?
    /// Fired on the main queue when a non-trigger keyDown arrives while voice
    /// state is `.listening` or `.transcribing`. The event itself is still
    /// forwarded to the system unchanged — only the in-flight voice session
    /// should be aborted by the consumer.
    var onExtraneousKeyDuringVoice: (() -> Void)?
    /// Fired on the main queue when Tab (forward) / Shift+Tab (backward) is
    /// pressed during an active voice-trigger session. The event is swallowed;
    /// the consumer cycles the voice picker highlight. Does NOT cancel voice.
    var onPersonaCycle: ((_ forward: Bool) -> Void)?
    /// O(1) lookup of whether the voice state machine is non-idle. Used by
    /// the extraneous-key branch so it doesn't need to track session state.
    var isVoiceActive: (() -> Bool)?
    /// Synchronous, O(1): true only while a DEFAULT-trigger voice session is
    /// recording. Gates Tab-cycle interception so persona-hotkey push-to-talk keeps
    /// its cancel-on-Tab behavior even after the hotkey key is released.
    var isDefaultTriggerVoiceActive: (() -> Bool)?
    /// Synchronous, O(1): true while the post-release context console is open. The
    /// event tap then passes the trigger key through (no activation, no interrupt)
    /// so the console stays usable — including Option-modified typing.
    var isConsoleOpen: (() -> Bool)?
    /// O(1) lookup of the user-level "Voice Enabled" toggle. When it returns
    /// false, voice-trigger and persona push-to-talk *activation* must not
    /// swallow events — fn keeps its system behavior and persona hotkeys pass
    /// through. Deactivation of an already-running session stays ungated.
    var isVoiceEnabled: (() -> Bool)?
    var onClipboardHotkey: (() -> Void)?
    /// One step of the hold-modifier switcher gesture: open the panel + highlight
    /// the first item, or move the highlight down if already open.
    var onClipboardSwitcherStep: (() -> Void)?
    /// Commit the switcher gesture: paste the highlighted item and close.
    var onClipboardSwitcherCommit: (() -> Void)?
    var onVaultHotkey: (() -> Void)?
    var onClipboardQuickPaste: ((Int) -> Void)?
    var isClipboardPanelVisible: (() -> Bool)?
    var onSettingsHotkey: (() -> Void)?
    var onScreenshotHotkey: (() -> Void)?
    var onSelectedTextEditorHotkey: (() -> Void)?
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
    /// After any `resetAllInputState` the tracked modifier sets are empty while
    /// keys may physically still be held, so per-key toggle tracking can't be
    /// trusted. While set, `updateTrackedModifierState`/`isModifierKeyDown` use
    /// recovery semantics (mask bit present ⇒ insert); cleared once a
    /// flagsChanged event reports no live modifiers at all (sets and hardware
    /// agree again). Starts `true` because launch has the same unknown-physical-
    /// state premise as a reset.
    private var isResetRecoveryMode = true
    /// Tracks the recording-session edge so `handle()` resets input state
    /// exactly once when a `HotkeyRecorder` starts capturing.
    private var wasHotkeyRecording = false
    /// When `true`, app-level hotkey dispatch (clipboard/vault/settings/screenshot/persona/action/voice trigger)
    /// is bypassed. Set on Secure Input enter, cleared on Secure Input exit.
    /// Physical events still pass through unchanged.
    private var secureInputSuspended = false
    private var clipboardHotkey: HotkeyConfig?
    /// Cmd+Tab-style state for the clipboard hotkey (hold modifier + repeated tap).
    private var clipboardSwitcher = ClipboardSwitcherState()
    private var vaultHotkey: HotkeyConfig?
    private var settingsHotkey: HotkeyConfig?
    private var screenshotHotkey: HotkeyConfig?
    private var selectedTextEditorHotkey: HotkeyConfig?
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
                // Pass-through paths must return the incoming event UNRETAINED:
                // the caller only balances the retain it already holds when the
                // same event comes back; an extra retain here leaks one CGEvent
                // per keystroke. Only newly-created replacement events are
                // returned retained (+1 ownership transfer).
                guard let refcon else { return Unmanaged.passUnretained(event) }
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
        clipboardSwitcher.reset()
        isResetRecoveryMode = true

        // Interrupt any active voice session — fn-held trigger OR persona-hotkey
        // push-to-talk OR an open post-release console (which has neither a held
        // trigger nor a persona-hotkey keyDown, yet must still be torn down on a
        // reset such as settings reload / stop / secure-input). onTriggerInterrupted
        // is idempotent (guards on isActive), so a single notification covers all.
        if prior.triggerActive || prior.personaHotkeyKeyDown != nil || (isConsoleOpen?() ?? false) {
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
        selectedTextEditorHotkey = hotkeys.hotkey(for: .selectedTextEditor)
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

    /// Tab (0x30) → forward; Shift+Tab → backward; anything else → nil.
    static func personaCycleDirection(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool? {
        guard keyCode == 0x30 else { return nil }
        return !flags.contains(.maskShift)
    }

    static func shouldCancelVoiceForUnexpectedKeyPress(
        keyCode: CGKeyCode,
        isAutoRepeat: Bool,
        isVoiceActive: Bool,
        voiceTriggerKeyCode: CGKeyCode?,
        personaHotkeyKeyDown: CGKeyCode?
    ) -> Bool {
        guard !isAutoRepeat, isVoiceActive else { return false }
        return keyCode != voiceTriggerKeyCode && keyCode != personaHotkeyKeyDown
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
            return Unmanaged.passUnretained(event)
        }

        // Reset-recovery convergence: once the hardware reports no live
        // modifiers, physical reality matches the (cleared) tracked sets and
        // normal per-key toggle tracking is trustworthy again. Drop anything a
        // recovery-mode insert may have wrongly left behind (releasing one of
        // two same-mask keys is ambiguous while in recovery). `cgModifierMask`
        // deliberately excludes `.maskAlphaShift` — that is a lock bit which
        // stays set while Caps Lock is on, not a held-key indicator.
        if isResetRecoveryMode, type == .flagsChanged,
           event.flags.intersection(HotkeyConfig.cgModifierMask).isEmpty {
            isResetRecoveryMode = false
            state.heldModifiers.removeAll()
            state.remappedKeysDown.removeAll()
        }

        // Recorder capture must take precedence over remap: the user is trying
        // to register the *physical* keystroke they just pressed, not whatever
        // it gets rewritten to (e.g. Right Cmd → Forward Delete). Without this
        // ordering the recorder either records the remapped key or never sees
        // the keystroke at all because remapIfNeeded swallowed it.
        if HotkeyRecorder.isAnyRecording {
            // Everything below remapIfNeeded is skipped while recording, so
            // modifier tracking and repeat timers would run blind: a source key
            // held when recording starts (repeat timer live) releases into this
            // branch and the timer would never stop. Reset once on entry —
            // cancels timers and clears state we can no longer keep consistent.
            if !wasHotkeyRecording {
                wasHotkeyRecording = true
                resetAllInputState(reason: .hotkeyRecorderStart)
            }
            if let recorder = HotkeyRecorder.activeRecorder,
               recorder.handleCGEvent(type: type, event: event) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        wasHotkeyRecording = false

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

        // Voice picker: while a DEFAULT-TRIGGER voice session is recording, Tab /
        // Shift+Tab cycle the highlighted persona instead of cancelling. Swallow both
        // the keyDown (cycle on non-autorepeat only) and its matching keyUp. Gated on
        // an explicit default-trigger signal — NOT on `personaHotkeyKeyDown == nil`,
        // which goes stale once a persona hotkey's key is released while transcription
        // is still live (that would wrongly swallow Tab for a persona-hotkey session).
        // Must precede the keyDown cancel paths below (triggerActive interrupt +
        // shouldCancelVoiceForUnexpectedKeyPress).
        if (type == .keyDown || type == .keyUp),
           isDefaultTriggerVoiceActive?() == true {
            let tabCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if let forward = Self.personaCycleDirection(keyCode: tabCode, flags: event.flags) {
                if type == .keyDown,
                   event.getIntegerValueField(.keyboardEventAutorepeat) != 1 {
                    DispatchQueue.main.async { [weak self] in self?.onPersonaCycle?(forward) }
                }
                return nil
            }
        }

        if let fKey = HotkeyConfig.decodeMediaFKey(type: type, event: event) {
            if Self.shouldCancelVoiceForUnexpectedKeyPress(
                keyCode: fKey,
                isAutoRepeat: false,
                isVoiceActive: isVoiceActive?() == true,
                voiceTriggerKeyCode: voiceTriggerHotkey?.keyCode,
                personaHotkeyKeyDown: state.personaHotkeyKeyDown
            ) {
                DispatchQueue.main.async { [weak self] in self?.onExtraneousKeyDuringVoice?() }
                return Unmanaged.passUnretained(event)
            }
            if dispatchFRowHotkey(keyCode: fKey, flags: event.flags, fnHeld: state.heldModifiers.contains(0x3F)) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
            let fnHeld = state.heldModifiers.contains(0x3F)

            if state.triggerActive && !isAutoRepeat {
                DispatchQueue.main.async { [weak self] in self?.onTriggerInterrupted?() }
            }

            if Self.shouldCancelVoiceForUnexpectedKeyPress(
                keyCode: keyCode,
                isAutoRepeat: isAutoRepeat,
                isVoiceActive: isVoiceActive?() == true,
                voiceTriggerKeyCode: voiceTriggerHotkey?.keyCode,
                personaHotkeyKeyDown: state.personaHotkeyKeyDown
            ) {
                DispatchQueue.main.async { [weak self] in self?.onExtraneousKeyDuringVoice?() }
                return Unmanaged.passUnretained(event)
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
                    if binding.config.matches(keyCode: keyCode, flags: event.flags, fnHeld: fnHeld) {
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

            // Clipboard hotkey — hold-modifier switcher gesture (Cmd+Tab style).
            if let cfg = clipboardHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags, fnHeld: fnHeld) {
                if cfg.modifiers.isEmpty {
                    // No modifier to detect release on — fall back to plain toggle.
                    DispatchQueue.main.async { [weak self] in self?.onClipboardHotkey?() }
                    return nil
                }
                // Only discrete taps drive the gesture; swallow auto-repeat so the
                // held key neither types nor rapidly cycles the highlight.
                if !isAutoRepeat {
                    _ = clipboardSwitcher.onHotkeyTap(hotkeyModifiers: cfg.modifiers)
                    DispatchQueue.main.async { [weak self] in self?.onClipboardSwitcherStep?() }
                }
                return nil
            }

            // Vault hotkey
            if let cfg = vaultHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags, fnHeld: fnHeld) {
                DispatchQueue.main.async { [weak self] in self?.onVaultHotkey?() }
                return nil
            }

            // Settings hotkey
            if let cfg = settingsHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags, fnHeld: fnHeld) {
                DispatchQueue.main.async { [weak self] in self?.onSettingsHotkey?() }
                return nil
            }

            // Screenshot hotkey
            if let cfg = screenshotHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags, fnHeld: fnHeld),
               UserDefaults.standard.object(forKey: "screenshotEnabled") as? Bool ?? true {
                DispatchQueue.main.async { [weak self] in self?.onScreenshotHotkey?() }
                return nil
            }

            // Selected Text Editor hotkey
            if let cfg = selectedTextEditorHotkey,
               !cfg.isPureModifier,
               cfg.matches(keyCode: keyCode, flags: event.flags) {
                DispatchQueue.main.async { [weak self] in self?.onSelectedTextEditorHotkey?() }
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
            // Also gate on the user-level Voice Enabled toggle: with voice off,
            // a persona hotkey must pass through instead of becoming a dead key.
            if !isAutoRepeat,
               !secureInputSuspended,
               isVoiceEnabled?() ?? true,
               state.personaHotkeyKeyDown == nil,
               !state.triggerActive {
                let hotkeys = HotkeySettingsStore.shared
                for persona in PersonaStore.shared.personas {
                    guard let cfg = hotkeys.personaHotkey(personaId: persona.id),
                          !cfg.isPureModifier,
                          cfg.matches(keyCode: keyCode, flags: event.flags, fnHeld: fnHeld) else { continue }
                    let id = persona.id
                    state.personaHotkeyKeyDown = keyCode
                    DispatchQueue.main.async { [weak self] in
                        PersonaStore.shared.setActive(id)
                        self?.onTriggerDown?(.personaHotkey(personaId: id))
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

        // Clipboard switcher: releasing the held hotkey modifier commits the
        // gesture (paste highlighted + close). Never swallows the flagsChanged —
        // voice/persona logic below still needs it.
        if type == .flagsChanged {
            let visible = isClipboardPanelVisible?() ?? false
            if clipboardSwitcher.onFlagsChanged(currentFlags: event.flags, panelVisible: visible) == .commitPaste {
                DispatchQueue.main.async { [weak self] in self?.onClipboardSwitcherCommit?() }
            }
        }

        if state.personaHotkeyKeyDown != nil {
            return Unmanaged.passUnretained(event)
        }
        // Voice trigger: gate *activation* on `!secureInputSuspended` so we
        // never start a recording session whose release keyUp could be lost,
        // and on the Voice Enabled toggle so a disabled trigger key keeps its
        // system behavior instead of being swallowed into a no-op session.
        // Always honour *deactivation* — if Secure Input toggles on while
        // a session is already running, releasing the trigger must still stop
        // the recording cleanly.
        // Also gate on `!isConsoleOpen`: while the post-release console is open the
        // trigger key must pass through unchanged (return the event below) so it
        // doesn't set `triggerActive` — otherwise the next keyDown would fire
        // `onTriggerInterrupted` and close the console mid-edit (e.g. Option+Arrow
        // when Right Option is the trigger).
        if nowActive && !state.triggerActive && !secureInputSuspended && (isVoiceEnabled?() ?? true)
            && !(isConsoleOpen?() ?? false) {
            state.triggerActive = true
            DispatchQueue.main.async { [weak self] in self?.onTriggerDown?(.defaultTrigger) }
            return nil
        } else if !nowActive && state.triggerActive {
            state.triggerActive = false
            DispatchQueue.main.async { [weak self] in self?.onTriggerUp?() }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    /// Match a synthetic F-row keyDown (built from a systemDefined media-key
    /// event) against the same hotkey set the regular keyDown path checks.
    /// Skips push-to-talk / persona logic — those rely on a paired keyUp that
    /// media events don't deliver.
    private func dispatchFRowHotkey(keyCode: CGKeyCode, flags: CGEventFlags, fnHeld: Bool) -> Bool {
        if HotkeyPreferences.enabled {
            let frontBundleID = currentFrontBundleID?()
            for binding in actionBindings {
                if binding.config.matches(keyCode: keyCode, flags: flags, fnHeld: fnHeld) {
                    if !binding.appBundleIDs.isEmpty {
                        guard let bid = frontBundleID, binding.appBundleIDs.contains(bid) else { continue }
                    }
                    let actions = binding.actions
                    DispatchQueue.main.async { [weak self] in self?.onAction?(actions) }
                    return true
                }
            }
        }
        if let cfg = clipboardHotkey, !cfg.isPureModifier, cfg.matches(keyCode: keyCode, flags: flags, fnHeld: fnHeld) {
            DispatchQueue.main.async { [weak self] in self?.onClipboardHotkey?() }
            return true
        }
        if let cfg = vaultHotkey, !cfg.isPureModifier, cfg.matches(keyCode: keyCode, flags: flags, fnHeld: fnHeld) {
            DispatchQueue.main.async { [weak self] in self?.onVaultHotkey?() }
            return true
        }
        if let cfg = settingsHotkey, !cfg.isPureModifier, cfg.matches(keyCode: keyCode, flags: flags, fnHeld: fnHeld) {
            DispatchQueue.main.async { [weak self] in self?.onSettingsHotkey?() }
            return true
        }
        if let cfg = screenshotHotkey, !cfg.isPureModifier,
           cfg.matches(keyCode: keyCode, flags: flags, fnHeld: fnHeld),
           UserDefaults.standard.object(forKey: "screenshotEnabled") as? Bool ?? true {
            DispatchQueue.main.async { [weak self] in self?.onScreenshotHotkey?() }
            return true
        }
        if let cfg = selectedTextEditorHotkey, !cfg.isPureModifier,
           cfg.matches(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.onSelectedTextEditorHotkey?() }
            return true
        }
        return false
    }

    private func flag(for keyCode: CGKeyCode) -> CGEventFlags? {
        Self.flag(for: keyCode)
    }

    static func flag(for keyCode: CGKeyCode) -> CGEventFlags? {
        switch keyCode {
        case 0x38, 0x3C: return .maskShift
        case 0x3B, 0x3E: return .maskControl
        case 0x3A, 0x3D: return .maskAlternate
        case 0x37, 0x36: return .maskCommand
        case 0x3F: return .maskSecondaryFn
        case 0x39: return .maskAlphaShift
        default: return nil
        }
    }

    static func updateTrackedModifierState(
        heldModifiers: inout Set<CGKeyCode>,
        keyCode: CGKeyCode,
        eventFlags: CGEventFlags,
        isResetRecoveryMode: Bool
    ) {
        guard let mask = flag(for: keyCode) else { return }
        if !eventFlags.contains(mask) {
            heldModifiers.remove(keyCode)
            return
        }
        if isResetRecoveryMode {
            heldModifiers.insert(keyCode)
            return
        }
        if heldModifiers.contains(keyCode) {
            heldModifiers.remove(keyCode)
        } else {
            heldModifiers.insert(keyCode)
        }
    }

    static func isModifierKeyDown(
        remappedKeysDown: inout Set<CGKeyCode>,
        keyCode: CGKeyCode,
        eventFlags: CGEventFlags,
        isResetRecoveryMode: Bool
    ) -> Bool {
        guard let mask = flag(for: keyCode) else {
            let wasDown = remappedKeysDown.contains(keyCode)
            let isDown = !wasDown
            if isDown {
                remappedKeysDown.insert(keyCode)
            } else {
                remappedKeysDown.remove(keyCode)
            }
            return isDown
        }
        if !eventFlags.contains(mask) {
            remappedKeysDown.remove(keyCode)
            return false
        }
        if isResetRecoveryMode {
            remappedKeysDown.insert(keyCode)
            return true
        }
        let isDown = !remappedKeysDown.contains(keyCode)
        if isDown {
            remappedKeysDown.insert(keyCode)
        } else {
            remappedKeysDown.remove(keyCode)
        }
        return isDown
    }

    private func computeTriggerActive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .flagsChanged {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if HotkeyConfig.modifierKeyCodes.contains(keyCode) {
                Self.updateTrackedModifierState(
                    heldModifiers: &state.heldModifiers,
                    keyCode: keyCode,
                    eventFlags: event.flags,
                    isResetRecoveryMode: isResetRecoveryMode
                )
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
            return .some(Unmanaged.passUnretained(event))
        }
        remapped.flags = remappedFlags(for: event.flags, mapping: mapping, isKeyDown: isKeyDown)
        // Preserve hardware auto-repeat on forwarded events from non-modifier
        // sources (flagsChanged events carry 0 here, so this is a no-op for
        // modifier sources).
        remapped.setIntegerValueField(
            .keyboardEventAutorepeat,
            value: event.getIntegerValueField(.keyboardEventAutorepeat)
        )

        // Auto-repeat timer: only for a *modifier* source mapped to a non-modifier
        // target (e.g., Right Cmd → Forward Delete). Modifier sources never repeat
        // in hardware, so we synthesize repeats; non-modifier sources already
        // deliver hardware auto-repeat keyDowns (forwarded above), and a timer
        // would stack a second, fixed-rate repeat stream on top.
        if mapping.fromFlag != nil && mapping.toFlag == nil {
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
            return Self.isModifierKeyDown(
                remappedKeysDown: &state.remappedKeysDown,
                keyCode: keyCode,
                eventFlags: event.flags,
                isResetRecoveryMode: isResetRecoveryMode
            )
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
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: targetKeyCode, keyDown: true)
            else { return }
            down.flags = []
            down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
            down.post(tap: .cgSessionEventTap)
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
