import AppKit
import Foundation
import os

@MainActor
final class ClipboardMonitor {
    private static let logger = Logger(subsystem: "io.keymic.app", category: "ClipboardMonitor")
    typealias SourceAppProvider = () -> (bundleID: String?, name: String?)

    private let pasteboard: PasteboardReading
    private let store: ClipboardStore
    private let ownBundleID: String
    private let sourceAppProvider: SourceAppProvider
    private let ignoreConfidential: () -> Bool
    private let isEnabled: () -> Bool

    private var lastChangeCount: Int
    private var ignoredText: String?
    private var timer: DispatchSourceTimer?

    init(
        pasteboard: PasteboardReading,
        store: ClipboardStore,
        ownBundleID: String,
        sourceAppProvider: @escaping SourceAppProvider,
        ignoreConfidential: @escaping () -> Bool,
        isEnabled: @escaping () -> Bool
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.ownBundleID = ownBundleID
        self.sourceAppProvider = sourceAppProvider
        self.ignoreConfidential = ignoreConfidential
        self.isEnabled = isEnabled
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else {
            Self.logger.debug("start() ignored — timer already running")
            return
        }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        Self.logger.info("start() — timer scheduled, lastChangeCount=\(self.lastChangeCount, privacy: .public)")
    }

    func stop() {
        let hadTimer = timer != nil
        timer?.cancel()
        timer = nil
        if hadTimer { Self.logger.info("stop() — timer cancelled") }
    }

    /// Marks `text` as KeyMic's own write so the next observed change matching it is skipped.
    /// Identity is by content rather than changeCount because clearContents+setString and the
    /// 500 ms voice-restore both occur as separate increments that aren't trivially predictable.
    func markIgnored(text: String) {
        ignoredText = text
    }

    func tickForTesting() { tick() }

    private func tick() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        let prev = lastChangeCount
        lastChangeCount = current
        Self.logger.info("tick — changeCount \(prev, privacy: .public) → \(current, privacy: .public)")

        guard isEnabled() else {
            ignoredText = nil
            Self.logger.info("tick — skip (clipboard disabled)")
            return
        }

        if ignoreConfidential() {
            let types = Set(pasteboard.types())
            if !types.isDisjoint(with: ConfidentialClipboardType.all) {
                ignoredText = nil
                Self.logger.info("tick — skip (confidential)")
                return
            }
        }

        guard let text = pasteboard.string(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ignoredText = nil
            Self.logger.info("tick — skip (no text / empty)")
            return
        }

        if let ignored = ignoredText {
            ignoredText = nil
            if ignored == text {
                Self.logger.info("tick — skip (matches markIgnored, len=\(text.count, privacy: .public))")
                return
            }
        }

        let source = sourceAppProvider()
        if let bundleID = source.bundleID, bundleID == ownBundleID {
            Self.logger.info("tick — skip (own bundle)")
            return
        }

        Self.logger.info("tick — adding text len=\(text.count, privacy: .public) src=\(source.bundleID ?? "?", privacy: .public)")
        store.add(text: text, sourceBundleID: source.bundleID, sourceAppName: source.name)
    }
}
