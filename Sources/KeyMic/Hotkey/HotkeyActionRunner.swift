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
    private let queue = DispatchQueue(label: "io.keymic.app.hotkey-action-runner", qos: .userInitiated)
    private let logger = Logger(subsystem: "io.keymic.app", category: "HotkeyActionRunner")

    /// Wait after a `.typeText` step to let `Cmd+V` settle in the target app.
    private let pasteSettleSeconds: TimeInterval = 0.15

    init(
        typeText: @escaping TypeTextFn,
        keyPress: @escaping KeyPressFn = HotkeyActionRunner.defaultKeyPress,
        shell:    @escaping ShellFn    = HotkeyActionRunner.defaultShell
    ) {
        self.typeText = typeText
        self.keyPress = keyPress
        self.shell = shell
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
                logger.warning("shell exit \(code): \(cmd, privacy: .public)")
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

    static func defaultShell(_ command: String) -> Int32 {
        let p = Process()
        p.launchPath = "/bin/zsh"
        p.arguments = ["-lc", command]
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        p.standardOutput = devNull
        p.standardError = devNull
        do {
            try p.run()
        } catch {
            NSLog("HotkeyActionRunner.defaultShell failed to launch: \(error)")
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
