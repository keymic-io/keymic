import Cocoa
import IOKit
import IOKit.hid
import IOKit.hidsystem

final class KeyMonitor {
    var onTriggerDown: (() -> Void)?
    var onTriggerUp: (() -> Void)?
    var onTriggerInterrupted: (() -> Void)?
    var onClipboardHotkey: (() -> Void)?
    var onVaultHotkey: (() -> Void)?
    var onClipboardQuickPaste: ((Int) -> Void)?
    var isClipboardPanelVisible: (() -> Bool)?
    var onSettingsHotkey: (() -> Void)?
    var onAction: (([HotkeyAction]) -> Void)?
    /// Synchronous, O(1) lookup of the bundle ID KeyMic believes is frontmost.
    /// MUST NOT call into LaunchServices — this runs in the event-tap callback on the
    /// main thread, where any sync XPC stall blocks the entire HID input pipeline.
    /// AppDelegate wires this to a cached value updated via NSWorkspace notifications.
    var currentFrontBundleID: (() -> String?)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var triggerActive = false
    private var clipboardHotkey: HotkeyConfig?
    private var vaultHotkey: HotkeyConfig?
    private var settingsHotkey: HotkeyConfig?
    private var voiceTriggerHotkey: HotkeyConfig?
    private var actionBindings: [(config: HotkeyConfig, actions: [HotkeyAction], appBundleIDs: [String])] = []
    private var heldModifiers = Set<CGKeyCode>()
    private var remappedKeysDown = Set<CGKeyCode>()
    private var repeatTimers: [CGKeyCode: DispatchSourceTimer] = [:]
    private let keyMappingManager: KeyMappingManager

    private let initialRepeatDelay: TimeInterval = 0.4
    private let repeatInterval: TimeInterval = 0.05

    init(keyMappingManager: KeyMappingManager = .shared) {
        self.keyMappingManager = keyMappingManager
    }

    /// Start monitoring. Returns false if accessibility permission is missing.
    func start() -> Bool {
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
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
        reloadHotkeys()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        runLoopSource = nil
        eventTap = nil
        cancelAllRepeatTimers()
        triggerActive = false
        heldModifiers.removeAll()
    }

    func resetTriggerState() {
        triggerActive = false
        heldModifiers.removeAll()
    }

    @objc private func userDefaultsChanged() {
        reloadHotkeys()
    }

    private func reloadHotkeys() {
        let clip = UserDefaults.standard.string(forKey: "clipboardHotkey") ?? "alt+v"
        clipboardHotkey = HotkeyConfig.parse(clip)
        let vault = UserDefaults.standard.string(forKey: "vaultHotkey") ?? "alt+b"
        vaultHotkey = HotkeyConfig.parse(vault)
        let settings = UserDefaults.standard.string(forKey: "settingsHotkey") ?? "cmd+shift+,"
        settingsHotkey = HotkeyConfig.parse(settings)
        let voice = UserDefaults.standard.string(forKey: "voiceTriggerKey") ?? "fn"
        voiceTriggerHotkey = HotkeyConfig.parse(voice)
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
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if let remapped = remapIfNeeded(type: type, event: event) {
            return remapped
        }

        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1

            if triggerActive && !isAutoRepeat {
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
        }

        let nowActive = computeTriggerActive(type: type, event: event)
        if nowActive && !triggerActive {
            triggerActive = true
            DispatchQueue.main.async { [weak self] in self?.onTriggerDown?() }
            return nil
        } else if !nowActive && triggerActive {
            triggerActive = false
            DispatchQueue.main.async { [weak self] in self?.onTriggerUp?() }
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    private func computeTriggerActive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .flagsChanged {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if HotkeyConfig.modifierKeyCodes.contains(keyCode) {
                if keyCode == 0x3F {
                    if event.flags.contains(.maskSecondaryFn) {
                        heldModifiers.insert(keyCode)
                    } else {
                        heldModifiers.remove(keyCode)
                    }
                } else {
                    if heldModifiers.contains(keyCode) {
                        heldModifiers.remove(keyCode)
                    } else {
                        heldModifiers.insert(keyCode)
                    }
                }
            }
        }

        guard let voice = voiceTriggerHotkey, voice.isPureModifier else { return false }
        return heldModifiers.contains(voice.keyCode)
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
            let wasDown = remappedKeysDown.contains(keyCode)
            let isDown = !wasDown
            if isDown {
                remappedKeysDown.insert(keyCode)
            } else {
                remappedKeysDown.remove(keyCode)
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
