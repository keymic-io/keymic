import AppKit
import Foundation
import os

@MainActor
final class ClipboardController {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "ClipboardController")
    let store: ClipboardStore
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

    /// One-time schema upgrade. Drops every ClipboardItem (preserving VaultItem
    /// in the shared container) and clears the cache directory of any leftovers.
    /// Idempotent; AppDelegate gates calls on a UserDefaults version key.
    func performSchemaWipe() {
        store.deleteAllClipboardItems()
        // After wipe there are no referenced cache files, so this sweeps everything left.
        store.collectOrphanCacheFiles()
    }

    /// Boot-time orphan sweep — call once on launch after `performSchemaWipe`
    /// (if any) to clean up files left behind by previous crashes.
    func sweepOrphanCacheFiles() {
        store.collectOrphanCacheFiles()
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
            clipboardCacheURL: store.clipboardCacheURL,
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
        activateTargetAndSendCommandV()
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
        switch item.kind {
        case .image:
            pasteImage(item)
        case .file:
            pasteFile(item)
        case .richText:
            pasteRichText(item)
        default:
            pasteText(item)
        }
    }

    private func pasteText(_ item: ClipboardItem) {
        store.bumpToTop(id: item.id)
        pasteboard.write(item.text)
        monitor.markIgnored(token: item.text)
        panel.dismiss()
        activateTargetAndSendCommandV()
    }

    private func pasteImage(_ item: ClipboardItem) {
        guard let rel = item.imageRelativePath else {
            panel.dismiss()
            return
        }
        let url = store.clipboardCacheURL.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: url) else {
            Self.logger.error("paste image — cache file missing: \(url.path, privacy: .public)")
            overlayPanel?.showMessage("图片缓存已丢失")
            panel.dismiss()
            return
        }
        let format: ImageFormat = url.pathExtension.lowercased() == "tiff" ? .tiff : .png
        store.bumpToTop(id: item.id)
        pasteboard.write(payloads: [(type: format.pasteboardType, data: data)])
        if let hash = item.contentHash {
            monitor.markIgnored(token: hash)
        }
        panel.dismiss()
        activateTargetAndSendCommandV()
    }

    private func pasteFile(_ item: ClipboardItem) {
        guard let path = item.fileURLPath, FileManager.default.fileExists(atPath: path) else {
            overlayPanel?.showMessage("文件已不存在")
            panel.dismiss()
            return
        }
        let url = URL(fileURLWithPath: path)
        store.bumpToTop(id: item.id)
        pasteboard.write(fileURL: url)
        monitor.markIgnored(token: path)
        panel.dismiss()
        activateTargetAndSendCommandV()
    }

    private func pasteRichText(_ item: ClipboardItem) {
        guard let blob = item.richBlob, let format = item.richBlobFormat else {
            // Fall back to plain text if the blob is somehow gone.
            pasteText(item)
            return
        }
        var payloads: [(type: String, data: Data)] = [
            (type: format.pasteboardType, data: blob)
        ]
        payloads.append((type: "public.utf8-plain-text", data: Data(item.text.utf8)))
        store.bumpToTop(id: item.id)
        pasteboard.write(payloads: payloads)
        monitor.markIgnored(token: item.text)
        panel.dismiss()
        activateTargetAndSendCommandV()
    }

    private func activateTargetAndSendCommandV() {
        if let target = pasteTargetApplication, !target.isTerminated {
            target.activate(options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.synthesizeCommandV()
        }
    }

    private func handleNewlyInserted(_ item: ClipboardItem) {
        switch item.kind {
        case .image, .file:
            return  // no text content to scan for secrets
        default:
            break
        }
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
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
