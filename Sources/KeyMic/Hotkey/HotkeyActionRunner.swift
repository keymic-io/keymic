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
    /// Resolved lazily so `.runAgent` hotkeys still work when the AgentRunner
    /// is constructed asynchronously after launch (or is intentionally absent).
    /// Invoked on the MainActor inside `execute(.runAgent)` so it's safe for
    /// the closure body to touch `@MainActor`-isolated state.
    private let agentRunnerProvider: @Sendable () -> AgentRunner?
    private let queue = DispatchQueue(label: "io.keymic.app.hotkey-action-runner", qos: .userInitiated)
    private static let logger = Logger(subsystem: "io.keymic.app", category: "HotkeyActionRunner")

    /// Wait after a `.typeText` step to let `Cmd+V` settle in the target app.
    private let pasteSettleSeconds: TimeInterval = 0.15

    init(
        typeText: @escaping TypeTextFn,
        keyPress: @escaping KeyPressFn = HotkeyActionRunner.defaultKeyPress,
        shell:    @escaping ShellFn    = HotkeyActionRunner.defaultShell,
        skillBridge: SkillHotkeyBridge? = nil,
        agentRunnerProvider: @escaping @Sendable () -> AgentRunner? = { nil }
    ) {
        self.typeText = typeText
        self.keyPress = keyPress
        self.shell = shell
        self.skillBridge = skillBridge
        self.agentRunnerProvider = agentRunnerProvider
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
            let provider = agentRunnerProvider
            Task { @MainActor in
                guard let runner = provider() else {
                    Self.logger.warning("runAgent fired but no AgentRunner wired; ignoring")
                    return
                }
                _ = runner.runForHotkey(prompt: prompt, sink: ConsoleSink.shared)
            }
        }
    }

    static func defaultShell(_ command: String) -> Int32 {
        let process = Process()
        process.launchPath = "/bin/zsh"
        process.arguments = ["-lc", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 127
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
