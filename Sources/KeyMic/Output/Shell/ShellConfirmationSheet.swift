import AppKit
import Foundation

/// Confirmation sheet shown BEFORE every `.runShell` invocation.
/// Default action is Cancel (Esc + Enter both cancel). Cmd+R runs.
@MainActor
enum ShellConfirmationSheet {
    static func present(command: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Run shell command?")
            alert.informativeText = String(localized:
                "This command will run in your shell with your full user environment.")

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.autohidesScrollers = true

            let textView = NSTextView(frame: scroll.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.string = command
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.autoresizingMask = [.width, .height]
            scroll.documentView = textView
            alert.accessoryView = scroll

            // Button order matters: first button is the default.
            // Default = Cancel. Run is the second button, keyed to Cmd+R.
            let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
            cancelButton.keyEquivalent = "\r"

            let runButton = alert.addButton(withTitle: String(localized: "Run"))
            runButton.keyEquivalent = "r"
            runButton.keyEquivalentModifierMask = [.command]

            let response = alert.runModal()
            cont.resume(returning: response == .alertSecondButtonReturn)
        }
    }
}
