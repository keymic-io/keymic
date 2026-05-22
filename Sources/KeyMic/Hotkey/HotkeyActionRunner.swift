import AppKit
import CoreGraphics
import Foundation
import os

final class HotkeyActionRunner {
    typealias TypeTextFn = (String) -> Void
    typealias KeyPressFn = (UInt16, UInt64) -> Void
    typealias ShellFn = (String) -> Int32

    private let typeText: TypeTextFn
    private let keyPress: KeyPressFn
    private let shell: ShellFn
    private let skillBridge: SkillHotkeyBridge?
    private let agentRunner: AgentRunner?
    private let queue = DispatchQueue(label: "io.keymic.app.hotkey-action-runner", qos: .userInitiated)
    private static let logger = Logger(subsystem: "io.keymic.app", category: "HotkeyActionRunner")

    /// Wait after a `.typeText` step to let `Cmd+V` settle in the target app.
    private let pasteSettleSeconds: TimeInterval = 0.15

    init(
        typeText: @escaping TypeTextFn,
        keyPress: @escaping KeyPressFn = HotkeyActionRunner.defaultKeyPress,
        shell:    @escaping ShellFn    = { ShellRunner.shared.run($0) },
        skillBridge: SkillHotkeyBridge? = nil,
        agentRunner: AgentRunner? = nil
    ) {
        self.typeText = typeText
        self.keyPress = keyPress
        self.shell = shell
        self.skillBridge = skillBridge
        self.agentRunner = agentRunner
    }

    func run(_ actions: [HotkeyAction]) {
        guard !actions.isEmpty else { return }
        queue.async { [self] in
            for action in actions { execute(action) }
        }
    }

    private func execute(_ action: HotkeyAction) {
        switch action {
        case .typeText(let s):
            DispatchQueue.main.sync { typeText(s) }
            Thread.sleep(forTimeInterval: pasteSettleSeconds)
        case .keyPress(let kc, let mods):
            DispatchQueue.main.sync { keyPress(kc, mods) }
        case .wait(let ms):
            Thread.sleep(forTimeInterval: TimeInterval(ms) / 1000.0)
        case .shell(let cmd):
            let code = shell(cmd)
            if code != 0 {
                Self.logger.warning("shell exit \(code): \(cmd, privacy: .public)")
            }
        case .runSkill(let name):
            guard let bridge = skillBridge else {
                Self.logger.warning("runSkill('\(name, privacy: .public)') fired but no SkillHotkeyBridge wired; ignoring")
                return
            }
            bridge.fire(name: name)
        case .runAgent(let prompt):
            guard let runner = agentRunner else {
                Self.logger.warning("runAgent fired but no AgentRunner wired; ignoring")
                return
            }
            Task { @MainActor in
                _ = runner.runForHotkey(prompt: prompt, sink: ConsoleSink.shared)
            }
        }
    }

    static func defaultKeyPress(_ keyCode: UInt16, _ modifiersRaw: UInt64) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags = CGEventFlags(rawValue: modifiersRaw)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
