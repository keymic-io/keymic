import AppKit
import CoreGraphics

final class HotkeyRecorder: NSButton {
    enum Mode { case combo, pureModifier, singleKey }

    typealias Validator = (HotkeyConfig) -> String?  // nil = ok, non-nil = error message

    /// Tracks how many recorders are currently capturing input. KeyMonitor reads this
    /// to bypass app-level hotkey dispatch while the user is recording, so the session
    /// CGEventTap doesn't swallow the keystroke before our local NSEvent monitor sees it.
    private static var activeRecordingCount: Int = 0
    static var isAnyRecording: Bool { activeRecordingCount > 0 }

    private var current: HotkeyConfig?
    private let validator: Validator
    private let mode: Mode
    private let onCommit: (HotkeyConfig) -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var errorTimer: Timer?

    override var canBecomeKeyView: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(initial: HotkeyConfig?, mode: Mode, validator: @escaping Validator, onCommit: @escaping (HotkeyConfig) -> Void) {
        self.current = initial
        self.mode = mode
        self.validator = validator
        self.onCommit = onCommit
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        wantsLayer = true
        renderIdle()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        removeMonitors()
        errorTimer?.invalidate()
    }

    private func removeMonitors() {
        let wasRecording = (localMonitor != nil) || (globalMonitor != nil)
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if wasRecording {
            Self.activeRecordingCount = max(0, Self.activeRecordingCount - 1)
        }
    }

    func updateValue(_ cfg: HotkeyConfig?) {
        current = cfg
        renderIdle()
    }

    private func setLabel(_ recording: Bool) {
        title = recording ? "Press keys…" : (current?.displayString() ?? "Click to record")
    }

    private func renderIdle() {
        layer?.borderWidth = 0
        toolTip = nil
        setLabel(false)
    }

    private func renderRecording() {
        setLabel(true)
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    private func renderError(_ message: String) {
        toolTip = message
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemRed.cgColor
        errorTimer?.invalidate()
        errorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.renderIdle()
        }
    }

    @objc private func toggleRecording() {
        if !isRecording {
            startRecording()
        } else {
            cancelRecording()
        }
    }

    private func startRecording() {
        renderRecording()
        window?.makeFirstResponder(self)
        Self.activeRecordingCount += 1
        let mask: NSEvent.EventTypeMask
        switch mode {
        case .pureModifier: mask = .flagsChanged
        case .combo, .singleKey: mask = [.keyDown, .flagsChanged]
        }
        // Local monitor: intercepts and swallows events before they reach any responder.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event)
        }
        // Global monitor: observes events meant for *other* apps so we can react when
        // the user's keypress goes outside our window.  Global monitors cannot swallow
        // events — they are read-only — so we still rely on the local monitor for that.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.isRecording else { return }
            // Cancel recording if the user interacted with a different app.
            self.cancelRecording()
        }
    }

    private var isRecording: Bool { localMonitor != nil }

    private func cancelRecording() {
        removeMonitors()
        renderIdle()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Esc cancels in every mode. singleKey additionally treats Return / Delete as cancel.
        if event.type == .keyDown {
            let kc = CGKeyCode(event.keyCode)
            if kc == 0x35 {
                cancelRecording()
                return nil
            }
            if mode == .singleKey, kc == 0x24 || kc == 0x33 {
                cancelRecording()
                return nil
            }
        }

        let cfg: HotkeyConfig
        switch (mode, event.type) {
        case (.pureModifier, .flagsChanged):
            let active: NSEvent.ModifierFlags = [.command, .shift, .control, .option, .function, .capsLock]
            guard !event.modifierFlags.intersection(active).isEmpty else { return nil }
            cfg = HotkeyConfig(modifiers: [], keyCode: CGKeyCode(event.keyCode))

        case (.combo, .keyDown):
            let cgFlags = cgEventFlags(from: event.modifierFlags)
            cfg = HotkeyConfig(modifiers: cgFlags, keyCode: CGKeyCode(event.keyCode))

        case (.singleKey, .keyDown):
            cfg = HotkeyConfig(modifiers: [], keyCode: CGKeyCode(event.keyCode))

        case (.singleKey, .flagsChanged):
            let modifierKeyCodes: Set<CGKeyCode> = [0x36, 0x37, 0x38, 0x3C, 0x39, 0x3A, 0x3D, 0x3B, 0x3E, 0x3F]
            let kc = CGKeyCode(event.keyCode)
            guard modifierKeyCodes.contains(kc) else { return nil }
            // Caps Lock is a toggle: emits one flagsChanged per physical press, but
            // .capsLock is asserted only on toggle-on. Accept either edge for it.
            if kc != 0x39 {
                let active: NSEvent.ModifierFlags = [.command, .shift, .control, .option, .function, .capsLock]
                guard !event.modifierFlags.intersection(active).isEmpty else { return nil }
            }
            cfg = HotkeyConfig(modifiers: [], keyCode: kc)

        default:
            return nil
        }

        if let msg = validator(cfg) {
            cancelRecording()
            renderError(msg)
        } else {
            current = cfg
            cancelRecording()
            onCommit(cfg)
        }
        return nil
    }

    private func cgEventFlags(from ns: NSEvent.ModifierFlags) -> CGEventFlags {
        var f: CGEventFlags = []
        if ns.contains(.command)  { f.insert(.maskCommand) }
        if ns.contains(.shift)    { f.insert(.maskShift) }
        if ns.contains(.control)  { f.insert(.maskControl) }
        if ns.contains(.option)   { f.insert(.maskAlternate) }
        if ns.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    static let clipboardValidator: Validator = { cfg in
        if cfg.isPureModifier { return "Need at least one regular key, not just modifiers" }
        if cfg.modifiers.isEmpty { return "Need at least one modifier" }
        if cfg.isSystemReserved { return "\(cfg.displayString()) is reserved by macOS" }
        return nil
    }

    static let voiceValidator: Validator = { cfg in
        cfg.isPureModifier ? nil : "Voice trigger must be a single modifier key"
    }
}
