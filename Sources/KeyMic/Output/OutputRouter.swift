import AppKit
import ApplicationServices
import Foundation
import os.log

enum InjectionStrategy: Codable, Equatable {
    case replaceFocusedText
    case replaceSelection
    case clipboard
    case openURL(template: String)
    case runShell(commandTemplate: String)
    case writeToITermPane(paneIndex: Int)
}

/// What gets routed. Built by AppDelegate.finishTranscription (or any future consumer).
struct PersonaOutput {
    let text: String
    let strategy: InjectionStrategy
    /// Frontmost app at the time the persona was triggered. Router restores focus
    /// to this app before injecting where applicable.
    let originatingApp: NSRunningApplication?
    /// Optional context payload for templating (openURL placeholders).
    let context: PersonaContext?
}

enum RouteResult: Equatable {
    case injected
    case fellBackToClipboard(reason: FallbackReason)
    case userCancelled
    case failed(message: String)
}

enum FallbackReason: String, Equatable {
    case selectionNotEditable
    case noFocusedElement
    case axPermissionMissing
    case strategyNotImplemented
}

enum OutputRouterError: Error {
    case invalidURLTemplate(String)
    case unsupportedStrategy(InjectionStrategy)
}

/// Pure helper for openURL strategy. Extracted to a namespace so tests can call it
/// without spinning up an OutputRouter instance.
enum URLTemplate {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Replaces `{query}`, `{selection}`, `{clipboard}` placeholders with URL-encoded values.
    /// Unknown placeholders are left literal.
    static func substitute(template: String, text: String, context: PersonaContext?) -> String? {
        let chars = CharacterSet.urlQueryAllowed.subtracting(.init(charactersIn: "&=+"))
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: chars) ?? s
        }
        var out = template
        out = out.replacingOccurrences(of: "{query}", with: enc(text))
        out = out.replacingOccurrences(of: "{selection}", with: enc(context?.selection ?? ""))
        out = out.replacingOccurrences(of: "{clipboard}", with: enc(context?.clipboardTop ?? ""))
        return out
    }

    /// Returns true if the scheme is in the safelist.
    static func validateScheme(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return allowedSchemes.contains(scheme)
    }
}

private let routerLogger = Logger(subsystem: "io.keymic.app", category: "OutputRouter")

/// Routes persona output to the destination declared by the strategy.
/// `@MainActor` because every concrete strategy touches AppKit (pasteboard, workspace, accessibility).
@MainActor
final class OutputRouter {
    /// Initialized once by AppDelegate.applicationDidFinishLaunching.
    nonisolated(unsafe) static var shared: OutputRouter!

    /// Injected for testability. AppDelegate constructs production instance with real deps.
    /// `readSelection` defaults to the read-enhanced SelectionTextProvider (AX → Cmd+C fallback).
    /// `writeSelection` defaults to `AXSelectionWriter.write(_:)` which sets `kAXSelectedTextAttribute`
    /// on the focused element. The pair has no `isEditable` probe — we try the write and treat
    /// failure as the signal to fall back to clipboard.
    private let inject: (String) -> Void
    private let readSelection: () -> String?
    private let writeSelection: (String) -> Bool
    private let pasteboard: NSPasteboard
    private let workspace: NSWorkspace
    private let onMarkIgnored: (String) -> Void
    /// `.runShell` confirmation gate. Returns true if the user approved. Default is a
    /// safety stub that always returns false — production wires `ShellConfirmationSheet.present`.
    private let confirmShellRun: (String) async -> Bool

    /// Test injection point — overrides `NSWorkspace.open(_:)`. Production default delegates to workspace.
    var openURLHandler: ((URL) -> Bool)?

    /// Test injection point — overrides `ShellOutputRunner.run(_:)`. Production default delegates
    /// to the real runner with the default 30 s timeout.
    var runShellExecutor: ((String) async throws -> ShellOutputResult)?

    init(inject: @escaping (String) -> Void,
         readSelection: @escaping () -> String? = { SelectionTextProvider.currentSelection() },
         writeSelection: @escaping (String) -> Bool = { AXSelectionWriter.write($0) },
         pasteboard: NSPasteboard = .general,
         workspace: NSWorkspace = .shared,
         onMarkIgnored: @escaping (String) -> Void = { _ in },
         confirmShellRun: @escaping (String) async -> Bool = { _ in false }) {
        self.inject = inject
        self.readSelection = readSelection
        self.writeSelection = writeSelection
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.onMarkIgnored = onMarkIgnored
        self.confirmShellRun = confirmShellRun
    }

    /// Main entry point.
    func route(_ output: PersonaOutput) async -> RouteResult {
        routerLogger.debug("route strategy=\(String(describing: output.strategy), privacy: .public) bundle=\(output.originatingApp?.bundleIdentifier ?? "nil", privacy: .public)")
        switch output.strategy {
        case .replaceFocusedText:
            await activateOriginatingApp(output.originatingApp)
            inject(output.text)
            return .injected
        case .clipboard:
            writeClipboard(output.text)
            return .injected
        case .replaceSelection:
            await activateOriginatingApp(output.originatingApp)
            guard readSelection() != nil else {
                writeClipboard(output.text)
                return .fellBackToClipboard(reason: .noFocusedElement)
            }
            if writeSelection(output.text) {
                return .injected
            }
            writeClipboard(output.text)
            return .fellBackToClipboard(reason: .selectionNotEditable)
        case .openURL(let template):
            guard let substituted = URLTemplate.substitute(
                template: template, text: output.text, context: output.context),
                  URLTemplate.validateScheme(substituted),
                  let url = URL(string: substituted) else {
                routerLogger.error("openURL invalid: template=\(template, privacy: .public)")
                return .failed(message: "invalid URL after template substitution")
            }
            let opened = openURLHandler?(url) ?? workspace.open(url)
            return opened ? .injected : .failed(message: "workspace failed to open URL")
        case .runShell(let commandTemplate):
            return await runShell(template: commandTemplate, output: output)
        case .writeToITermPane(let paneIndex):
            return await writeToITerm(paneIndex: paneIndex, text: output.text)
        }
    }

    /// `.writeToITermPane` dispatch.
    private func writeToITerm(paneIndex: Int, text: String) async -> RouteResult {
        guard ITermAvailability.isInstalled() else {
            return .failed(message: "iTerm 2 is not installed")
        }
        do {
            try await ITermBridge.write(text: text, paneIndex: paneIndex)
            return .injected
        } catch ITermBridge.Error.permissionDenied {
            return .failed(message: "Automation permission for iTerm 2 is required (System Settings → Privacy & Security → Automation → KeyMic)")
        } catch ITermBridge.Error.iTermNotRunning {
            return .failed(message: "iTerm 2 has no open window")
        } catch ITermBridge.Error.paneOutOfRange {
            return .failed(message: "iTerm pane index out of range")
        } catch {
            return .failed(message: "iTerm write failed: \(error.localizedDescription)")
        }
    }

    /// `.runShell` dispatch. Substitutes the template, refuses empty / all-empty-placeholder
    /// commands, asks `confirmShellRun` (cancel → `.userCancelled`), runs `ShellOutputRunner`,
    /// strips ANSI from stdout, then routes through `inject(_:)` (same path as
    /// `.replaceFocusedText`). stderr present (with any exit code) surfaces as `.failed`.
    private func runShell(template: String, output: PersonaOutput) async -> RouteResult {
        guard let substituted = ShellTemplate.substitute(
                template: template, text: output.text, context: output.context) else {
            return .failed(message: "shell template substitution failed")
        }
        let command = substituted.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            return .failed(message: "Empty shell command after substitution")
        }
        guard ShellTemplate.hasResolvedSubstantialContent(
                original: template, resolved: substituted) else {
            return .failed(message: "Refusing to run command with empty placeholders")
        }

        let confirmed = await confirmShellRun(command)
        guard confirmed else {
            routerLogger.debug("runShell user cancelled (length=\(command.count, privacy: .public))")
            return .userCancelled
        }

        do {
            let result: ShellOutputResult
            if let executor = runShellExecutor {
                result = try await executor(command)
            } else {
                result = try await ShellOutputRunner.run(command)
            }
            routerLogger.debug("runShell exit=\(result.exitCode, privacy: .public) stdout_len=\(result.stdout.count, privacy: .public) stderr_len=\(result.stderr.count, privacy: .public)")
            let cleanStdout = ANSIStripper.strip(result.stdout)
            if !cleanStdout.isEmpty {
                await activateOriginatingApp(output.originatingApp)
                inject(cleanStdout)
            }
            if result.exitCode != 0 {
                let msg: String
                if result.stderr.isEmpty {
                    msg = "shell command exited with code \(result.exitCode)"
                } else {
                    msg = result.stderr.count > 200
                        ? String(result.stderr.prefix(200)) + "…"
                        : result.stderr
                }
                return .failed(message: msg)
            }
            return .injected
        } catch ShellOutputRunnerError.timeout {
            return .failed(message: "shell command timed out after 30s")
        } catch {
            return .failed(message: "shell run failed: \(error.localizedDescription)")
        }
    }

    private func writeClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onMarkIgnored(text)
    }

    /// Restores focus to the originating app and waits (bounded) until it is actually
    /// frontmost — activation takes tens of milliseconds and a single runloop yield
    /// routinely observed the OLD frontmost app, sending AX reads/writes to the wrong
    /// target. Polls every 20 ms up to 500 ms; on timeout falls through so callers'
    /// existing fallback paths (e.g. clipboard) take over. Used by async route() paths.
    func activateOriginatingApp(_ app: NSRunningApplication?) async {
        guard let app, !app.isTerminated else { return }
        app.activate(options: [])
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if workspace.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        routerLogger.debug("activateOriginatingApp: \(app.bundleIdentifier ?? "?", privacy: .public) not frontmost after 500ms")
    }

    /// Sync version for callers (like ClipboardController) that already provide their own
    /// post-activate delay before synthesizing Cmd+V. No yield — caller is responsible for timing.
    func activateOriginatingAppSync(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        app.activate(options: [])
    }
}

/// Inline AX write helper for `.replaceSelection`. Mirrors LOR-17 spec §5.2 minus the
/// isEditable probe — we try the write directly and treat non-`.success` as "not editable".
/// Lives here (fileprivate) until LOR-17 ships a structured `SelectedTextReader` module.
fileprivate enum AXSelectionWriter {
    /// Writes `text` to the focused element's `kAXSelectedTextAttribute`.
    /// Returns true only on `.success`. Does NOT re-read to verify (some Electron clients
    /// reflect the write one runloop tick later — verification would falsely report failure).
    static func write(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(systemWide,
                                          kAXFocusedUIElementAttribute as CFString,
                                          &focused) == .success,
            let any = focused,
            CFGetTypeID(any) == AXUIElementGetTypeID()
        else { return false }
        let element = any as! AXUIElement
        let status = AXUIElementSetAttributeValue(element,
                                                  kAXSelectedTextAttribute as CFString,
                                                  text as CFString)
        if status != .success {
            routerLogger.debug("AXSelectionWriter: setAttributeValue status=\(status.rawValue, privacy: .public)")
        }
        return status == .success
    }
}
