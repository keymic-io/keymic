import AppKit
import Foundation
import os

@MainActor
final class ClipboardController {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "ClipboardController")
    private let store: ClipboardStore
    let vaultStore: VaultStore
    private let scanner: SecretScanner
    weak var overlayPanel: OverlayPanel?
    private let pasteboard: SystemPasteboard
    private let monitor: ClipboardMonitor
    private lazy var panel: ClipboardPanel = makePanel()
    private weak var pasteTargetApplication: NSRunningApplication?

    private static let pasteSourceID: CGEventSourceStateID = .combinedSessionState

    init() {
        self.store = ClipboardStore.makeDefault(maxHistory: ClipboardPreferences.maxHistory)
        self.pasteboard = SystemPasteboard()
        self.vaultStore = VaultStore(modelContainer: store.modelContainer, keychain: KeychainVault())
        self.scanner = SecretScanner.shared

        let ownBundle = Bundle.main.bundleIdentifier ?? "io.keymic.app"
        self.monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            store: store,
            ownBundleID: ownBundle,
            sourceAppProvider: {
                let app = NSWorkspace.shared.frontmostApplication
                return (app?.bundleIdentifier, app?.localizedName)
            },
            ignoreConfidential: { ClipboardPreferences.ignoreConfidential },
            isEnabled: { ClipboardPreferences.enabled }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        store.installInsertHook { [weak self] item in
            self?.handleNewlyInserted(item)
        }
    }

    func start() {
        guard ClipboardPreferences.enabled else { return }
        monitor.start()
    }

    var isPanelVisible: Bool {
        panel.isVisible
    }

    func toggle(initialTab: PanelTab = .clipboard) {
        if panel.isVisible {
            if panel.currentTab == initialTab {
                panel.dismiss()
            } else {
                panel.switchTab(to: initialTab)
            }
            return
        }
        guard ClipboardPreferences.enabled else { return }
        pasteTargetApplication = NSWorkspace.shared.frontmostApplication
        panel.showAtCursor(initialTab: initialTab)
    }

    func quickPaste(index: Int) {
        guard ClipboardPreferences.enabled, panel.isVisible else { return }
        panel.quickPaste(index: index)
    }

    /// Hook for other components (e.g. TextInjector) that write to the pasteboard themselves
    /// and want their writes excluded from clipboard history.
    func markPasteboardWrite(_ text: String) {
        monitor.markIgnored(text: text)
    }

    @objc private func preferencesChanged() {
        store.updateMaxHistory(ClipboardPreferences.maxHistory)
        store.applyCleanup()
        let enabled = ClipboardPreferences.enabled
        Self.logger.info("preferencesChanged — clipboard enabled=\(enabled, privacy: .public)")
        if enabled {
            monitor.start()
        } else {
            monitor.stop()
            panel.dismiss()
        }
    }

    func togglePin(id: UUID) {
        store.togglePin(id: id)
    }

    private func makePanel() -> ClipboardPanel {
        ClipboardPanel(
            modelContainer: store.modelContainer,
            onPaste: { [weak self] item in self?.paste(item) },
            onDelete: { [weak self] id in self?.store.delete(id: id) },
            onTogglePin: { [weak self] id in self?.store.togglePin(id: id) },
            onVaultPaste: { [weak self] item in self?.pasteVault(item) },
            onVaultDelete: { [weak self] item in self?.vaultStore.delete(item) },
            onDismiss: { [weak self] in self?.panel.dismiss() }
        )
    }

    private func pasteVault(_ item: VaultItem) {
        let plain: String
        do {
            plain = try vaultStore.reveal(item)
        } catch {
            // Authentication failed / cancelled / orphan — silently dismiss.
            panel.dismiss()
            return
        }
        let savedText = pasteboard.string()
        let writeChangeCount = pasteboard.write(plain)
        monitor.markIgnored(text: plain)
        panel.dismiss()
        if let target = pasteTargetApplication, !target.isTerminated {
            target.activate(options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.synthesizeCommandV()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.pasteboard.changeCount == writeChangeCount else { return }
            if let savedText {
                self.pasteboard.write(savedText)
                self.monitor.markIgnored(text: savedText)
            } else {
                self.pasteboard.clear()
            }
        }
    }

    private func paste(_ item: ClipboardItem) {
        store.bumpToTop(id: item.id)
        pasteboard.write(item.text)
        monitor.markIgnored(text: item.text)
        panel.dismiss()

        if let target = pasteTargetApplication, !target.isTerminated {
            target.activate(options: [])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.synthesizeCommandV()
        }
    }

    private func handleNewlyInserted(_ item: ClipboardItem) {
        let text = item.text
        let bundleID = item.sourceBundleID
        scanner.scan(text) { [weak self] match in
            guard let self, let match else { return }
            _ = self.vaultStore.ingest(match: match, copiedFrom: bundleID)
            self.overlayPanel?.showSecretToast(ruleName: match.rule.description)
        }
    }

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: pasteSourceID)
        let vKeyCode: CGKeyCode = 0x09
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
