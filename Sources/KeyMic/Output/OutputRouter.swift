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

    /// Test injection point — overrides `NSWorkspace.open(_:)`. Production default delegates to workspace.
    var openURLHandler: ((URL) -> Bool)?

    init(inject: @escaping (String) -> Void,
         readSelection: @escaping () -> String? = { SelectionTextProvider.currentSelection() },
         writeSelection: @escaping (String) -> Bool = { AXSelectionWriter.write($0) },
         pasteboard: NSPasteboard = .general,
         workspace: NSWorkspace = .shared,
         onMarkIgnored: @escaping (String) -> Void = { _ in }) {
        self.inject = inject
        self.readSelection = readSelection
        self.writeSelection = writeSelection
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.onMarkIgnored = onMarkIgnored
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
        case .runShell, .writeToITermPane:
            return .failed(message: "strategy not yet implemented")
        }
    }

    private func writeClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onMarkIgnored(text)
    }

    /// Restores focus to the originating app, yields one runloop tick to let it settle.
    func activateOriginatingApp(_ app: NSRunningApplication?) async {
        guard let app, !app.isTerminated else { return }
        app.activate(options: [])
        await Task.yield()
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
