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
        dispatchPrecondition(condition: .notOnQueue(DispatchQueue.main))
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
            // Block the runner queue on the agent task so `[runAgent, typeText]`
            // and similar composed bindings execute sequentially, matching
            // every other action kind. A re-fired hotkey will cancel the in-
            // flight agent via `AgentRunner`'s in-flight-task tracking, which
            // signals the semaphore promptly so the queue doesn't stall.
            let provider = agentRunnerProvider
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                defer { semaphore.signal() }
                guard let runner = provider() else {
                    Self.logger.warning("runAgent fired but no AgentRunner wired; ignoring")
                    return
                }
                let task = runner.runForHotkey(prompt: prompt, sink: ConsoleSink.shared)
                _ = await task.value
            }
            semaphore.wait()
        }
    }

    /// Hotkey shell actions route through `ShellRunner.shared.run` so a single
    /// hung command can't lock the runner's serial dispatch queue: ShellRunner
    /// enforces a 30s timeout with SIGTERM then SIGKILL of the whole process
    /// tree, plus it pipes through the cached login-shell PATH snapshot so
    /// homebrew/asdf/rbenv shims resolve the same way an interactive shell
    /// would.
    static func defaultShell(_ command: String) -> Int32 {
        ShellRunner.shared.run(command)
    }

    // TODO: Synthetic CGEvents posted here may be re-intercepted by KeyMonitor's
    // .cgSessionEventTap, causing re-entrant action loops if a keyPress action's
    // keyCode+modifiers matches another binding. Fix: tag synthetic events with a
    // distinguishable CGEventSource stateID and filter in KeyMonitor.
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
