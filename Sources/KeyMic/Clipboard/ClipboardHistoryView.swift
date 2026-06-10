import AppKit
import SwiftData
import SwiftUI

private struct FilteredItems {
    var pinned: [ClipboardItem]
    var history: [ClipboardItem]
    var all: [ClipboardItem] { pinned + history }
}

struct ClipboardHistoryView: View {
    @Bindable var selectionBridge: ClipboardPanelSelectionBridge

    @Query(sort: \ClipboardItem.createdAt, order: .reverse) private var items: [ClipboardItem]

    @State private var query: String = ""
    @State private var tab: PanelTab = .clipboard
    @State private var filtered: FilteredItems = FilteredItems(pinned: [], history: [])
    @State private var suppressScrollOnce: Bool = false
    @State private var keyboardNavMouseLock: NSPoint?
    @FocusState private var focusedField: FocusedField?

    let focus: ClipboardPanelFocus
    let clipboardCacheURL: URL
    let onPaste: (ClipboardItem) -> Void
    let onDelete: (UUID) -> Void
    let onTogglePin: (UUID) -> Void
    let onVaultPaste: (VaultItem) -> Void
    let onVaultDelete: (VaultItem) -> Void
    let onDismiss: () -> Void
    let onTransformSelected: () -> Void

    private var selectedIDs: Set<UUID> { selectionBridge.selectedIDs }
    private var primaryID: UUID? { selectionBridge.primarySelection }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private enum FocusedField {
        case search
    }

    private enum SelectionRefreshMode {
        case selectFirst
        case selectFirstIfPrimaryChanged
        case pruneInvisible
    }

    private func computeFiltered() -> FilteredItems {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var pinned: [ClipboardItem] = []
        var history: [ClipboardItem] = []

        for item in items {
            if !trimmed.isEmpty, !item.text.localizedCaseInsensitiveContains(trimmed) {
                continue
            }
            if item.isPinned {
                pinned.append(item)
            } else {
                history.append(item)
            }
        }

        pinned.sort { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
        return FilteredItems(pinned: pinned, history: history)
    }

    private func refreshFiltered(selection mode: SelectionRefreshMode) {
        filtered = computeFiltered()
        let visibleIDs = filtered.all.map(\.id)
        selectionBridge.visibleOrderedIDs = visibleIDs
        // Mirror the section sizes so ClipboardPanel.sendEvent can decide whether an
        // ⌥-shortcut has an actual target while the user is typing in the search field.
        focus.visiblePinnedCount = filtered.pinned.count
        focus.visibleHistoryCount = filtered.history.count

        switch mode {
        case .selectFirst:
            selectOnly(visibleIDs.first)
        case .selectFirstIfPrimaryChanged:
            let firstID = visibleIDs.first
            if primaryID != firstID {
                selectOnly(firstID)
            }
        case .pruneInvisible:
            let visibleSet = Set(visibleIDs)
            let pruned = selectionBridge.selectedIDs.intersection(visibleSet)
            if pruned != selectionBridge.selectedIDs {
                selectionBridge.selectedIDs = pruned
            }
            if selectionBridge.selectedIDs.isEmpty {
                selectOnly(visibleIDs.first)
            }
        }
    }

    private func selectOnly(_ id: UUID?) {
        if let id {
            selectionBridge.selectedIDs = [id]
            selectionBridge.lastClickedID = id
        } else {
            selectionBridge.selectedIDs.removeAll()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if tab == .clipboard {
                searchField
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                Divider().overlay(Color.white.opacity(0.08))

                if filtered.all.isEmpty {
                    emptyState
                } else {
                    list
                }
            } else {
                VaultListView(
                    focus: focus,
                    onPaste: onVaultPaste,
                    onDelete: onVaultDelete,
                    onDismiss: onDismiss
                )
            }

            Divider().overlay(Color.white.opacity(0.08))
            tabSwitcher
        }
        .background(VisualEffectBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            let trace = ClipboardOpenTrace.shared
            trace.mark("view.onAppear (first body + @Query fetch done)")
            refreshFiltered(selection: .selectFirst)
            trace.mark("computeFiltered (\(items.count) items)")
            focusedField = .search
            trace.end("view.onAppear done")
        }
        .onChange(of: focus.requestID) { _, _ in
            let trace = ClipboardOpenTrace.shared
            trace.mark("view.refresh (requestID — reuse open)")
            query = ""
            refreshFiltered(selection: .selectFirst)
            trace.mark("computeFiltered (\(items.count) items)")
            focusedField = .search
            trace.end("view.refresh done")
        }
        .onChange(of: focus.quickPasteRequestID) { _, _ in
            triggerQuickPaste(focus.quickPasteIndex)
        }
        .onChange(of: focus.pinnedQuickPasteRequestID) { _, _ in
            triggerPinnedQuickPaste(focus.pinnedQuickPasteIndex)
        }
        .onChange(of: focus.togglePinRequestID) { _, _ in
            triggerTogglePin()
        }
        .onChange(of: focus.tabRequestID) { _, _ in
            tab = focus.initialTab
            query = ""
        }
        .onChange(of: tab) { _, newTab in
            focus.currentTab = newTab
        }
        .onChange(of: query) { _, _ in
            refreshFiltered(selection: .selectFirstIfPrimaryChanged)
        }
        .onChange(of: items) { _, _ in
            refreshFiltered(selection: .pruneInvisible)
        }
        .background(
            KeyEventMonitor(
                isEnabled: tab == .clipboard,
                onArrowUp: moveSelection(by: -1),
                onArrowDown: moveSelection(by: 1),
                onReturn: triggerPaste,
                onCommandDelete: triggerDelete,
                onTogglePin: triggerTogglePin,
                onEscape: onDismiss,
                onQuickPaste: triggerQuickPaste,
                onPinnedQuickPaste: triggerPinnedQuickPaste
            ))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search clipboard history", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focusedField, equals: .search)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "No Clipboard History" : "No Matches")
                .font(.headline)
            Text(query.isEmpty ? "Copied text will appear here." : "Try a different search term.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 8) {
            Picker("", selection: $tab) {
                Text("📋 Clipboard").tag(PanelTab.clipboard)
                Text("🔒 Vault").tag(PanelTab.vault)
            }
            .pickerStyle(.segmented)

            if tab == .clipboard {
                Button {
                    onTransformSelected()
                } label: {
                    Label("Transform", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("l", modifiers: .option)
                .disabled(selectedIDs.isEmpty)
                .help(String(localized: "Transform selected items via LLM (⌥L)"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var list: some View {
        let transformRow: (UUID) -> Void = { id in
            selectionBridge.selectedIDs = [id]
            selectionBridge.lastClickedID = id
            onTransformSelected()
        }
        return ScrollViewReader { proxy in
            List {
                if !filtered.pinned.isEmpty {
                    Section(header: sectionHeader("Pinned")) {
                        ForEach(Array(filtered.pinned.enumerated()), id: \.element.id) { index, item in
                            row(item, quickKeyLabel: pinnedQuickKeyLabel(for: index), onTransformRow: transformRow)
                                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                                .listRowSeparator(.hidden)
                                .listRowBackground(rowBackground(for: item))
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering, primaryID != item.id {
                                        suppressScrollOnce = true
                                        selectionBridge.selectedIDs = [item.id]
                                        selectionBridge.lastClickedID = item.id
                                    }
                                }
                                .onTapGesture { onPaste(item) }
                                .simultaneousGesture(
                                    TapGesture(count: 1).modifiers(.command).onEnded {
                                        if selectionBridge.selectedIDs.contains(item.id) {
                                            selectionBridge.selectedIDs.remove(item.id)
                                        } else {
                                            selectionBridge.selectedIDs.insert(item.id)
                                        }
                                        selectionBridge.lastClickedID = item.id
                                    }
                                )
                                .simultaneousGesture(
                                    TapGesture(count: 1).modifiers(.shift).onEnded {
                                        extendRange(to: item.id)
                                    }
                                )
                                .id(item.id)
                        }
                    }
                }

                Section(header: sectionHeader("History")) {
                    ForEach(Array(filtered.history.enumerated()), id: \.element.id) { index, item in
                        row(item, quickKeyLabel: historyQuickKeyLabel(for: index), onTransformRow: transformRow)
                            .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(rowBackground(for: item))
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                handleHover(hovering, item: item)
                            }
                            .onTapGesture { onPaste(item) }
                            .simultaneousGesture(
                                TapGesture(count: 1).modifiers(.command).onEnded {
                                    if selectionBridge.selectedIDs.contains(item.id) {
                                        selectionBridge.selectedIDs.remove(item.id)
                                    } else {
                                        selectionBridge.selectedIDs.insert(item.id)
                                    }
                                    selectionBridge.lastClickedID = item.id
                                }
                            )
                            .simultaneousGesture(
                                TapGesture(count: 1).modifiers(.shift).onEnded {
                                    extendRange(to: item.id)
                                }
                            )
                            .id(item.id)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onChange(of: selectionBridge.selectedIDs) { _, newSet in
                if suppressScrollOnce {
                    suppressScrollOnce = false
                    return
                }
                // Scroll to primary (single selection) or the most recently clicked anchor.
                let target: UUID? = newSet.count == 1
                    ? newSet.first
                    : (selectionBridge.lastClickedID.flatMap { newSet.contains($0) ? $0 : nil })
                guard let id = target else { return }
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    @ViewBuilder
    private func row(
        _ item: ClipboardItem,
        quickKeyLabel label: String,
        onTransformRow: @escaping (UUID) -> Void
    ) -> some View {
        switch item.kind {
        case .file:
            FileRow(
                item: item, quickKeyLabel: label, isSelected: selectedIDs.contains(item.id),
                relativeTime: relativeTime,
                onTransformRow: onTransformRow)
        case .image:
            ImageRow(
                item: item, quickKeyLabel: label,
                cacheURL: clipboardCacheURL,
                relativeTime: relativeTime,
                onTransformRow: onTransformRow)
        default:
            TextRow(
                item: item,
                quickKeyLabel: label,
                query: query,
                onTransformRow: onTransformRow)
        }
    }

    private func rowBackground(for item: ClipboardItem) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(selectedIDs.contains(item.id) ? Color.accentColor.opacity(0.35) : Color.clear)
    }

    private func historyQuickKeyLabel(for index: Int) -> String {
        guard index < 10 else { return "" }
        return "⌥" + (index == 9 ? "0" : "\(index + 1)")
    }

    private func pinnedQuickKeyLabel(for index: Int) -> String {
        let chars = ["Q", "W", "E", "A", "S", "D", "Z", "X", "C"]
        guard index < chars.count else { return "" }
        return "⌥" + chars[index]
    }

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func moveSelection(by delta: Int) -> () -> Void {
        return {
            let list = filtered.all
            guard !list.isEmpty else { return }
            let currentIndex = list.firstIndex(where: { selectedIDs.contains($0.id) }) ?? 0
            let newIndex = (currentIndex + delta + list.count) % list.count
            let newID = list[newIndex].id
            selectionBridge.selectedIDs = [newID]
            selectionBridge.lastClickedID = newID
            keyboardNavMouseLock = NSEvent.mouseLocation
        }
    }

    private func handleHover(_ hovering: Bool, item: ClipboardItem) {
        guard hovering else { return }
        if let lock = keyboardNavMouseLock, NSEvent.mouseLocation == lock {
            return
        }
        keyboardNavMouseLock = nil
        if primaryID != item.id {
            suppressScrollOnce = true
            selectionBridge.selectedIDs = [item.id]
            selectionBridge.lastClickedID = item.id
        }
    }

    private func triggerPaste() {
        guard let id = primaryID, let item = filtered.all.first(where: { $0.id == id }) else { return }
        onPaste(item)
    }

    private func triggerDelete() {
        guard let id = primaryID, let item = filtered.all.first(where: { $0.id == id }) else { return }
        onDelete(item.id)
    }

    @discardableResult
    private func triggerTogglePin() -> Bool {
        guard let id = primaryID else { return false }
        onTogglePin(id)
        // togglePin mutates isPinned/pinnedAt in place; the @Query array's membership,
        // order, and object identities are all unchanged, so `.onChange(of: items)`
        // never fires — re-partition Pinned/History explicitly.
        refreshFiltered(selection: .pruneInvisible)
        return true
    }

    private func extendRange(to targetID: UUID) {
        guard let anchor = selectionBridge.lastClickedID,
              let aIdx = filtered.all.firstIndex(where: { $0.id == anchor }),
              let tIdx = filtered.all.firstIndex(where: { $0.id == targetID }) else {
            selectionBridge.selectedIDs = [targetID]
            selectionBridge.lastClickedID = targetID
            return
        }
        let range = aIdx <= tIdx ? aIdx...tIdx : tIdx...aIdx
        let ids = filtered.all[range].map(\.id)
        selectionBridge.selectedIDs.formUnion(ids)
    }

    @discardableResult
    private func triggerQuickPaste(_ index: Int) -> Bool {
        guard filtered.history.indices.contains(index) else { return false }
        onPaste(filtered.history[index])
        return true
    }

    @discardableResult
    private func triggerPinnedQuickPaste(_ index: Int) -> Bool {
        guard filtered.pinned.indices.contains(index) else { return false }
        onPaste(filtered.pinned[index])
        return true
    }
}

private struct AppIconView: View {
    let bundleID: String?
    var body: some View {
        if let image = ApplicationImageCache.shared.image(forBundleID: bundleID) {
            Image(nsImage: image).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app").foregroundStyle(.secondary)
        }
    }
}

private struct TransformRowButton: View {
    let itemID: UUID
    let isHovered: Bool
    let onTransformRow: (UUID) -> Void

    var body: some View {
        Button {
            onTransformRow(itemID)
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Transform this item"))
        .opacity(isHovered ? 1.0 : 0.0)
        .allowsHitTesting(isHovered)
    }
}

private struct TextRow: View {
    let item: ClipboardItem
    let quickKeyLabel: String
    let query: String
    let onTransformRow: (UUID) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Text(quickKeyLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .leading)

            if let symbol = item.kind.iconSymbolName {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }

            HighlightedText(source: item.displayPreview, query: query)
                .foregroundStyle(.primary)
                .font(.system(size: 14))
                .lineLimit(1)

            Spacer(minLength: 8)

            TransformRowButton(itemID: item.id, isHovered: isHovered, onTransformRow: onTransformRow)

            AppIconView(bundleID: item.sourceBundleID).frame(width: 18, height: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
    }
}

private struct FileRow: View {
    let item: ClipboardItem
    let quickKeyLabel: String
    let isSelected: Bool
    let relativeTime: (Date) -> String
    let onTransformRow: (UUID) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Text(quickKeyLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .leading)

            fileIcon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text((item.fileURLPath as NSString?)?.lastPathComponent ?? item.text)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(item.fileURLPath ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            TransformRowButton(itemID: item.id, isHovered: isHovered, onTransformRow: onTransformRow)

            AppIconView(bundleID: item.sourceBundleID).frame(width: 18, height: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .onHover { isHovered = $0 }
    }

    private var fileIcon: some View {
        Group {
            if let path = item.fileURLPath {
                Image(nsImage: FileIconCache.shared.image(forPath: path))
                    .resizable()
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ImageRow: View {
    let item: ClipboardItem
    let quickKeyLabel: String
    let cacheURL: URL
    let relativeTime: (Date) -> String
    let onTransformRow: (UUID) -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(quickKeyLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .leading)
                .padding(.top, 4)

            thumbView
                .frame(width: 100, height: 72)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text("\(item.imageWidth)×\(item.imageHeight) · \(formattedSize(item.byteSize))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(relativeTime(item.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            TransformRowButton(itemID: item.id, isHovered: isHovered, onTransformRow: onTransformRow)

            AppIconView(bundleID: item.sourceBundleID).frame(width: 18, height: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .onHover { isHovered = $0 }
        .task { loadThumbnailIfNeeded() }
    }

    @ViewBuilder
    private var thumbView: some View {
        if let img = thumbnail {
            Image(nsImage: img).resizable().scaledToFill()
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func loadThumbnailIfNeeded() {
        guard thumbnail == nil, let rel = item.imageRelativePath else { return }
        let url = cacheURL.appendingPathComponent(rel)
        if let cached = ThumbnailLoader.shared.thumbnail(
            fileURL: url,
            completion: { img in
                self.thumbnail = img
            })
        {
            thumbnail = cached
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct KeyEventMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onReturn: () -> Void
    let onCommandDelete: () -> Void
    /// ⌥-shortcut handlers return whether they actually executed, so the monitor can
    /// pass the keystroke through to a focused text field when there was no target
    /// (e.g. ⌥E dead key / ⌥A=å typed into the search field).
    let onTogglePin: () -> Bool
    let onEscape: () -> Void
    let onQuickPaste: (Int) -> Bool
    let onPinnedQuickPaste: (Int) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        apply(to: view)
    }

    private func apply(to view: MonitorView) {
        view.isEnabled = isEnabled
        view.onArrowUp = onArrowUp
        view.onArrowDown = onArrowDown
        view.onReturn = onReturn
        view.onCommandDelete = onCommandDelete
        view.onTogglePin = onTogglePin
        view.onEscape = onEscape
        view.onQuickPaste = onQuickPaste
        view.onPinnedQuickPaste = onPinnedQuickPaste
    }

    private final class MonitorView: NSView {
        var isEnabled = true
        var onArrowUp: (() -> Void)?
        var onArrowDown: (() -> Void)?
        var onReturn: (() -> Void)?
        var onCommandDelete: (() -> Void)?
        var onTogglePin: (() -> Bool)?
        var onEscape: (() -> Void)?
        var onQuickPaste: ((Int) -> Bool)?
        var onPinnedQuickPaste: ((Int) -> Bool)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handle(event) ?? event
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let window, window.isVisible, event.window === window else { return event }

            let isCmd = event.modifierFlags.contains(.command)
            let isAltOnly =
                event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.control)
                && !event.modifierFlags.contains(.shift)

            // While the user is typing in a text field (the search box is focused as
            // soon as the panel opens), only swallow an ⌥-shortcut when it actually
            // fires; otherwise let the field handle it (⌥-letter composed characters,
            // dead keys on international layouts).
            let typingInText = window.firstResponder is NSText

            if isAltOnly, event.keyCode == 0x23 {
                let executed = onTogglePin?() ?? false
                return (executed || !typingInText) ? nil : event
            }

            if isAltOnly, let pinIndex = pinnedQuickPasteIndex(for: event.keyCode) {
                let executed = onPinnedQuickPaste?(pinIndex) ?? false
                return (executed || !typingInText) ? nil : event
            }

            if isAltOnly, let index = quickPasteIndex(for: event.keyCode) {
                let executed = onQuickPaste?(index) ?? false
                return (executed || !typingInText) ? nil : event
            }

            switch (event.keyCode, isCmd) {
            case (126, _):
                onArrowUp?()
                return nil
            case (125, _):
                onArrowDown?()
                return nil
            case (36, _), (76, _):
                onReturn?()
                return nil
            case (51, true):
                onCommandDelete?()
                return nil
            case (53, _):
                onEscape?()
                return nil
            default: return event
            }
        }

        private func pinnedQuickPasteIndex(for keyCode: UInt16) -> Int? {
            switch keyCode {
            case 0x0C: return 0  // Q
            case 0x0D: return 1  // W
            case 0x0E: return 2  // E
            case 0x00: return 3  // A
            case 0x01: return 4  // S
            case 0x02: return 5  // D
            case 0x06: return 6  // Z
            case 0x07: return 7  // X
            case 0x08: return 8  // C
            default: return nil
            }
        }

        private func quickPasteIndex(for keyCode: UInt16) -> Int? {
            switch keyCode {
            case 18: return 0
            case 19: return 1
            case 20: return 2
            case 21: return 3
            case 23: return 4
            case 22: return 5
            case 26: return 6
            case 28: return 7
            case 25: return 8
            case 29: return 9
            default: return nil
            }
        }
    }
}
