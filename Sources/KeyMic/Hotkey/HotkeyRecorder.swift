import AppKit
import CoreGraphics

final class HotkeyRecorder: NSButton {
    enum Mode { case combo, pureModifier, singleKey }

    typealias Validator = (HotkeyConfig) -> String?  // nil = ok, non-nil = error message

    /// Tracks how many recorders are currently capturing input. KeyMonitor reads this
    /// to bypass app-level hotkey dispatch while the user is recording, so the session
    /// CGEventTap doesn't swallow the keystroke before our local monitor sees it.
    private static var activeRecordingCount: Int = 0
    static var isAnyRecording: Bool { activeRecordingCount > 0 }

    /// The currently-recording recorder, if any. KeyMonitor's CGEventTap consults
    /// this and routes raw events here directly — bypassing NSEvent dispatch,
    /// which silently drops bare F1-F12 keyDowns on some macOS configurations
    /// even when the app is frontmost. Same approach as skhd.
    static weak var activeRecorder: HotkeyRecorder?


    private var current: HotkeyConfig?
    private let validator: Validator
    private let mode: Mode
    private let onCommit: (HotkeyConfig) -> Void
    private var errorTimer: Timer?
    private var recording = false

    override var canBecomeKeyView: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // SwiftUI may pull the NSView out of its window without deallocating it
        // (sheet dismiss, tab switch, view hidden). Without this hook the
        // activeRecordingCount leaks, permanently bypassing hotkey dispatch.
        if newWindow == nil, isRecording {
            cancelRecording()
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned && isRecording {
            cancelRecording()
        }
        return resigned
    }


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
        stopRecording()
        errorTimer?.invalidate()
    }

    private func stopRecording() {
        guard recording else { return }
        Self.activeRecordingCount = max(0, Self.activeRecordingCount - 1)
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        recording = false
    }

    func updateValue(_ cfg: HotkeyConfig?) {
        // If a parent state push lands while we are still recording, cancel the
        // session first so renderIdle() doesn't show idle while the static
        // activeRecordingCount stays elevated.
        if isRecording { cancelRecording() }
        current = cfg
        renderIdle()
    }

    private func setLabel(_ recording: Bool) {
        title = recording ? String(localized: "Press keys…") : (current?.displayString() ?? String(localized: "Click to record"))
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
        Self.activeRecorder = self
        recording = true
    }

    private var isRecording: Bool { recording }

    private func cancelRecording() {
        stopRecording()
        renderIdle()
    }

    /// Called from KeyMonitor's CGEventTap callback for every event while a
    /// recorder is active. Returns true if the recorder consumed the event.
    @discardableResult
    func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard isRecording else { return false }

        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Esc cancels in every mode. singleKey additionally treats Return / Delete as cancel.
        if type == .keyDown {
            if kc == 0x35 { cancelRecording(); return true }
            if mode == .singleKey, kc == 0x24 || kc == 0x33 {
                cancelRecording(); return true
            }
        }

        // Media-mode F-keys arrive as systemDefined / NX_SUBTYPE_AUX_CONTROL_BUTTONS.
        if mode != .pureModifier, let fKey = HotkeyConfig.decodeMediaFKey(type: type, event: event) {
            // singleKey mode (key remap target) ignores modifiers — match the
            // (.singleKey, .keyDown) branch below to keep behavior consistent.
            let mods: CGEventFlags = (mode == .singleKey) ? [] : HotkeyConfig.recordedFlags(event: event, keyCode: fKey)
            commit(HotkeyConfig(modifiers: mods, keyCode: fKey))
            return true
        }

        let cfg: HotkeyConfig
        switch (mode, type) {
        case (.pureModifier, .flagsChanged):
            guard !event.flags.intersection(HotkeyConfig.cgModifierMask).isEmpty else { return false }
            cfg = HotkeyConfig(modifiers: [], keyCode: kc)

        case (.combo, .keyDown):
            cfg = HotkeyConfig(modifiers: HotkeyConfig.recordedFlags(event: event, keyCode: kc), keyCode: kc)

        case (.singleKey, .keyDown):
            cfg = HotkeyConfig(modifiers: [], keyCode: kc)

        case (.singleKey, .flagsChanged):
            guard HotkeyConfig.modifierKeyCodes.contains(kc) else { return false }
            if kc != 0x39 {
                guard !event.flags.intersection(HotkeyConfig.cgModifierMask).isEmpty else { return false }
            }
            cfg = HotkeyConfig(modifiers: [], keyCode: kc)

        default:
            return false
        }

        commit(cfg)
        return true
    }

    private func commit(_ cfg: HotkeyConfig) {
        if let msg = validator(cfg) {
            cancelRecording()
            renderError(msg)
        } else {
            current = cfg
            cancelRecording()
            onCommit(cfg)
        }
    }

    static let clipboardValidator: Validator = { cfg in
        if cfg.isPureModifier { return String(localized: "Need at least one regular key, not just modifiers") }
        // The clipboard panel hotkey drives the hold-modifier switcher gesture,
        // which detects commit via modifier release — so a modifier is required
        // even for function-row keys.
        if cfg.modifiers.isEmpty {
            return String(localized: "Need at least one modifier")
        }
        if cfg.isSystemReserved { return String(localized: "\(cfg.displayString()) is reserved by macOS") }
        return nil
    }

    static let voiceValidator: Validator = { cfg in
        cfg.isPureModifier ? nil : String(localized: "Voice trigger must be a single modifier key")
    }
}
