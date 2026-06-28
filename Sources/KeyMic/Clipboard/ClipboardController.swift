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

    /// Multi-selection bridge between ClipboardPanel and external triggers (hotkey, magic-wand).
    let selectionBridge = ClipboardPanelSelectionBridge()

    /// Injected by AppDelegate after construction. Optional so the controller is testable
    /// without an LLM dependency.
    var transformController: ClipboardTransformController?

    private static let pasteSourceID: CGEventSourceStateID = .combinedSessionState

    private var observedPreferences = ObservedPreferences.current()

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
        // Pre-warm the panel during idle. The first ⌥V press otherwise pays the
        // one-time NSHostingController + SwiftUI graph construction synchronously on
        // the main thread (see `makePanel`'s "first-open hosting init" trace marks).
        // That stall can exceed the event-tap timeout — and the tap shares the main
        // run loop — silently dropping every global hotkey (incl. ⌥V) until recovery.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.prewarm()
        }
    }

    /// Build the lazy clipboard panel (and its NSHostingController) ahead of first
    /// use so the construction cost lands during idle, not on the ⌥V hotkey press.
    /// Idempotent — resolving the lazy `panel` again is a no-op.
    func prewarm() {
        _ = panel
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
        let trace = ClipboardOpenTrace.shared
        trace.begin(reason: "toggle(\(initialTab))")

        // First access to the lazy `panel` triggers makePanel() on the very first
        // open (one-time NSHostingController construction); mark it explicitly.
        let panel = self.panel
        trace.mark("panel.ready")

        if panel.isVisible {
            if panel.currentTab == initialTab {
                panel.dismiss()
            } else {
                panel.switchTab(to: initialTab)
            }
            trace.end("toggle no-op (already visible)")
            return
        }
        guard ClipboardPreferences.enabled else {
            trace.end("disabled")
            return
        }
        pasteTargetApplication = NSWorkspace.shared.frontmostApplication
        trace.mark("frontmostApplication")
        panel.showAtCursor(initialTab: initialTab)
        trace.mark("showAtCursor returned")
    }

    func quickPaste(index: Int) {
        guard ClipboardPreferences.enabled, panel.isVisible else { return }
        panel.quickPaste(index: index)
    }

    /// Triggered by ⌥L hotkey, the Transform button, and the per-row magic-wand button.
    func transformSelected() {
        guard let transformer = transformController else { return }

        // panel closed → open it + toast; do not invoke LLM
        if !isPanelVisible {
            toggle(initialTab: .clipboard)
            overlayPanel?.showTransientToast(
                String(localized: "Select items to transform"),
                durationSeconds: 2.0
            )
            return
        }

        let items = currentSelectedItems()
        transformer.transform(items: items)
    }

    private func currentSelectedItems() -> [ClipboardItem] {
        let idsToTransform: [UUID]
        let ordered = selectionBridge.orderedSelection()
        if !ordered.isEmpty {
            idsToTransform = ordered
        } else if let focused = selectionBridge.focusedID {
            idsToTransform = [focused]
        } else if let cursor = selectionBridge.lastClickedID {
            idsToTransform = [cursor]
        } else if let firstVisible = selectionBridge.visibleOrderedIDs.first {
            idsToTransform = [firstVisible]
        } else {
            idsToTransform = []
        }

        return idsToTransform.compactMap { id in
            store.item(id: id)
        }
    }

    func pasteSelectedItemsInOrder() {
        let ids = selectionBridge.orderedSelection()
        guard !ids.isEmpty else {
            if let focused = selectionBridge.focusedID,
               let item = store.item(id: focused) {
                paste(item)
            }
            return
        }

        let items = ids.compactMap { store.item(id: $0) }
        guard !items.isEmpty else { return }
        paste(itemsInOrder: items)
    }

    private func paste(itemsInOrder items: [ClipboardItem]) {
        monitor.capturePendingChange()
        panel.dismiss()
        OutputRouter.shared.activateOriginatingAppSync(pasteTargetApplication)

        let initialDelay: TimeInterval = 0.10
        let interval: TimeInterval = 0.16

        for (index, item) in items.enumerated() {
            let delay = initialDelay + (Double(index) * interval)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.writePasteboardContents(for: item) else { return }
                Self.synthesizeCommandV()
            }
        }
    }

    @discardableResult
    private func writePasteboardContents(for item: ClipboardItem) -> Bool {
        switch item.kind {
        case .image:
            return writeImage(item)
        case .file:
            return writeFile(item)
        case .richText:
            return writeRichText(item)
        default:
            return writeText(item)
        }
    }

    /// Hook for other components (e.g. TextInjector) that write to the pasteboard themselves
    /// and want their writes excluded from clipboard history. Preferred variant: the writer
    /// passes the changeCount its own write returned, so a third-party process claiming the
    /// pasteboard between the write and this call can't get its copy wrongly excluded.
    func markPasteboardWrite(_ changeCount: Int) {
        monitor.markIgnoredChangeCount(changeCount)
    }

    /// Legacy variant for writers that only expose the written text (SelectionTextProvider,
    /// OutputRouter): falls back to reading the pasteboard's current changeCount.
    func markPasteboardWrite(_ text: String) {
        monitor.markIgnoredChangeCount(pasteboard.changeCount)
    }

    /// Hook for components that overwrite the pasteboard themselves (e.g. TextInjector's
    /// voice-injection path). Call right before the own write so a user copy made since the
    /// monitor's last 0.5 s tick is drained into history first — otherwise the own write
    /// advances `lastChangeCount` past it while its changeCount is marked ignored, and that
    /// copy is lost forever. The controller's own paste paths already do this internally.
    func capturePendingChange() {
        monitor.capturePendingChange()
    }

    /// Clipboard-relevant UserDefaults values, snapshotted so `preferencesChanged`
    /// can ignore the (very chatty) `UserDefaults.didChangeNotification` unless one
    /// of these actually changed.
    private struct ObservedPreferences: Equatable {
        var enabled: Bool
        var maxHistory: Int
        var cleanupMode: CleanupMode
        var cleanupDays: Int

        static func current() -> ObservedPreferences {
            ObservedPreferences(
                enabled: ClipboardPreferences.enabled,
                maxHistory: ClipboardPreferences.maxHistory,
                cleanupMode: ClipboardPreferences.cleanupMode,
                cleanupDays: ClipboardPreferences.cleanupDays
            )
        }
    }

    @objc private func preferencesChanged() {
        // UserDefaults.didChangeNotification fires for *every* defaults write (voice/LLM
        // settings, panel size, …). Only react when a clipboard-relevant key changed —
        // otherwise each unrelated write would run a fetchAll + truncate + save here.
        let current = ObservedPreferences.current()
        guard current != observedPreferences else { return }
        let previous = observedPreferences
        observedPreferences = current

        if current.maxHistory != previous.maxHistory
            || current.cleanupMode != previous.cleanupMode
            || current.cleanupDays != previous.cleanupDays {
            store.updateMaxHistory(current.maxHistory)
            store.applyCleanup()
        }

        if current.enabled != previous.enabled {
            Self.logger.debug("preferencesChanged — clipboard enabled=\(current.enabled, privacy: .public)")
            if current.enabled {
                monitor.start()
            } else {
                monitor.stop()
                panel.dismiss()
            }
        }
    }

    func togglePin(id: UUID) {
        store.togglePin(id: id)
    }

    private func makePanel() -> ClipboardPanel {
        let trace = ClipboardOpenTrace.shared
        trace.mark("makePanel begin (first-open hosting init)")
        defer { trace.mark("makePanel end") }
        return ClipboardPanel(
            modelContainer: store.modelContainer,
            clipboardCacheURL: store.clipboardCacheURL,
            selectionBridge: selectionBridge,
            onPaste: { [weak self] item in self?.paste(item) },
            onDelete: { [weak self] id in self?.store.delete(id: id) },
            onTogglePin: { [weak self] id in self?.store.togglePin(id: id) },
            onVaultPaste: { [weak self] item in self?.pasteVault(item) },
            onVaultDelete: { [weak self] item in self?.vaultStore.delete(item) },
            onDismiss: { [weak self] in self?.panel.dismiss() },
            onPasteSelected: { [weak self] in self?.pasteSelectedItemsInOrder() },
            onTransformSelected: { [weak self] in self?.transformSelected() }
        )
    }

    private func pasteVault(_ item: VaultItem) {
        // Drain any not-yet-polled user copy into history before this flow starts
        // rewriting the pasteboard (the own-write ignore mark would skip it forever).
        monitor.capturePendingChange()
        // Snapshot the current pasteboard *now*, before the biometric prompt.
        let preRevealSnapshot = pasteboard.copyItems()
        let preRevealChangeCount = pasteboard.changeCount
        // `vaultStore.reveal` awaits a TouchID/passcode prompt. Running it inside a
        // Task (rather than a synchronous call) keeps the main thread — and the
        // `CGEvent` tap on its run loop — responsive while the prompt is up; a prior
        // implementation blocked main on a semaphore, which froze every global hotkey
        // (incl. ⌥V) until the user answered. VaultStore is @MainActor, so the
        // continuation and the pasteboard/Cmd+V work below resume on the main thread.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let plain: String
            do {
                plain = try await self.vaultStore.reveal(item)
            } catch {
                self.panel.dismiss()
                return
            }
            // The biometric prompt can stay up for many seconds. If the user copied
            // something while it was showing, restore *that* afterwards — not the
            // stale pre-prompt snapshot, which would silently destroy their copy.
            let savedItems: [NSPasteboardItem]?
            if self.pasteboard.changeCount != preRevealChangeCount {
                self.monitor.capturePendingChange()
                savedItems = self.pasteboard.copyItems()
            } else {
                savedItems = preRevealSnapshot
            }
            // Concealed write: declares org.nspasteboard marker types so third-party
            // clipboard managers don't persist the revealed secret.
            let writeChangeCount = self.pasteboard.writeConcealed(plain)
            self.monitor.markIgnoredChangeCount(writeChangeCount)
            self.panel.dismiss()
            self.activateTargetAndSendCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.pasteboard.changeCount == writeChangeCount else { return }
                if let savedItems {
                    let restoreCount = self.pasteboard.writeItems(savedItems)
                    self.monitor.markIgnoredChangeCount(restoreCount)
                } else {
                    let clearCount = self.pasteboard.clear()
                    self.monitor.markIgnoredChangeCount(clearCount)
                }
            }
        }
    }

    private func paste(_ item: ClipboardItem) {
        monitor.capturePendingChange()
        guard writePasteboardContents(for: item) else {
            panel.dismiss()
            return
        }
        panel.dismiss()
        activateTargetAndSendCommandV()
    }

    @discardableResult
    private func writeText(_ item: ClipboardItem) -> Bool {
        store.bumpToTop(id: item.id)
        let cc = pasteboard.write(item.text)
        monitor.markIgnoredChangeCount(cc)
        return true
    }

    @discardableResult
    private func writeImage(_ item: ClipboardItem) -> Bool {
        guard let rel = item.imageRelativePath else {
            return false
        }
        let url = store.clipboardCacheURL.appendingPathComponent(rel)
        guard let data = try? Data(contentsOf: url) else {
            Self.logger.error("paste image — cache file missing: \(url.path, privacy: .public)")
            overlayPanel?.showMessage("图片缓存已丢失")
            return false
        }
        let format: ImageFormat = url.pathExtension.lowercased() == "tiff" ? .tiff : .png
        store.bumpToTop(id: item.id)
        let cc = pasteboard.write(payloads: [(type: format.pasteboardType, data: data)])
        monitor.markIgnoredChangeCount(cc)
        return true
    }

    @discardableResult
    private func writeFile(_ item: ClipboardItem) -> Bool {
        guard let path = item.fileURLPath, FileManager.default.fileExists(atPath: path) else {
            overlayPanel?.showMessage("文件已不存在")
            return false
        }
        let url = URL(fileURLWithPath: path)
        store.bumpToTop(id: item.id)
        let cc = pasteboard.write(fileURL: url)
        monitor.markIgnoredChangeCount(cc)
        return true
    }

    @discardableResult
    private func writeRichText(_ item: ClipboardItem) -> Bool {
        guard let blob = item.richBlob, let format = item.richBlobFormat else {
            // Fall back to plain text if the blob is somehow gone.
            return writeText(item)
        }
        var payloads: [(type: String, data: Data)] = [
            (type: format.pasteboardType, data: blob)
        ]
        payloads.append((type: "public.utf8-plain-text", data: Data(item.text.utf8)))
        store.bumpToTop(id: item.id)
        let cc = pasteboard.write(payloads: payloads)
        monitor.markIgnoredChangeCount(cc)
        return true
    }

    private func activateTargetAndSendCommandV() {
        OutputRouter.shared.activateOriginatingAppSync(pasteTargetApplication)
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
        let itemID = item.id
        scanner.scan(text) { [weak self] match in
            guard let self, let match else { return }
            guard self.vaultStore.ingest(match: match, copiedFrom: bundleID) != nil else {
                // Keychain write failed — keep the history row rather than losing the
                // user's copy entirely (plaintext retention is the lesser evil here).
                Self.logger.error(
                    "vault ingest failed — keeping clipboard item \(itemID.uuidString, privacy: .public) in history")
                return
            }
            // Divert, don't copy: once the secret is safely in the Keychain, remove
            // the plaintext row from the (unencrypted) SwiftData history store.
            self.store.delete(id: itemID)
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
