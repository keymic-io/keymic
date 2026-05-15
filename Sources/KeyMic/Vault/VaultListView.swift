// Sources/KeyMic/Vault/VaultListView.swift
import AppKit
import SwiftData
import SwiftUI

struct VaultListView: View {
    @Query(sort: \VaultItem.copiedAt, order: .reverse) private var items: [VaultItem]
    @State private var query: String = ""
    @State private var selectedID: UUID?
    @State private var hoverID: UUID?
    @State private var pendingDelete: VaultItem?

    let focus: ClipboardPanelFocus
    let onPaste: (VaultItem) -> Void
    let onDelete: (VaultItem) -> Void
    let onDismiss: () -> Void

    private var filtered: [VaultItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.ruleName.localizedCaseInsensitiveContains(q) ||
            $0.maskedPreview.localizedCaseInsensitiveContains(q) ||
            ($0.sourceBundleID ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            search
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider().overlay(Color.white.opacity(0.08))
            if filtered.isEmpty { empty } else { list }
        }
        .onAppear { selectedID = filtered.first?.id }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if let cur = selectedID, !ids.contains(cur) { selectedID = ids.first }
            else if selectedID == nil { selectedID = ids.first }
        }
        .onChange(of: focus.quickPasteRequestID) { _, _ in
            quickPaste(focus.quickPasteIndex)
        }
        .background(VaultKeyMonitor(
            onArrowUp: { move(-1) },
            onArrowDown: { move(1) },
            onReturn: { triggerPaste() },
            onCommandDelete: { confirmDelete(selectedID) },
            onEscape: onDismiss,
            onQuickPaste: quickPaste
        ))
        .alert("Delete this secret?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { item in
            Button("Delete", role: .destructive) { onDelete(item); pendingDelete = nil }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Removing a secret from the Vault is permanent and cannot be undone.")
        }
    }

    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search Vault", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Vault is empty").font(.headline)
            Text("Detected secrets will appear here.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowBackground(for: item))
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            hoverID = hovering ? item.id : (hoverID == item.id ? nil : hoverID)
                            if hovering, selectedID != item.id { selectedID = item.id }
                        }
                        .onTapGesture { onPaste(item) }
                        .id(item.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    private func row(_ item: VaultItem, index: Int) -> some View {
        HStack(spacing: 10) {
            Text(quickKeyLabel(for: index))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .leading)

            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow.opacity(0.85))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.ruleName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(secondLine(item))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if hoverID == item.id {
                Button {
                    confirmDelete(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rowBackground(for item: VaultItem) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(item.id == selectedID ? Color.accentColor.opacity(0.35) : Color.clear)
    }

    private func secondLine(_ item: VaultItem) -> String {
        var parts: [String] = [item.maskedPreview]
        if let b = item.sourceBundleID, !b.isEmpty { parts.append(b) }
        parts.append(relative(item.copiedAt))
        return parts.joined(separator: " · ")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    private func relative(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func quickKeyLabel(for index: Int) -> String {
        guard index < 10 else { return "" }
        return "⌥" + (index == 9 ? "0" : "\(index + 1)")
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let idx = filtered.firstIndex(where: { $0.id == selectedID }) ?? 0
        let new = (idx + delta + filtered.count) % filtered.count
        selectedID = filtered[new].id
    }

    private func triggerPaste() {
        guard let id = selectedID, let item = filtered.first(where: { $0.id == id }) else { return }
        onPaste(item)
    }

    private func quickPaste(_ index: Int) {
        guard filtered.indices.contains(index) else { return }
        onPaste(filtered[index])
    }

    private func confirmDelete(_ id: UUID?) {
        guard let id, let item = filtered.first(where: { $0.id == id }) else { return }
        pendingDelete = item
    }
}

private struct VaultKeyMonitor: NSViewRepresentable {
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onReturn: () -> Void
    let onCommandDelete: () -> Void
    let onEscape: () -> Void
    let onQuickPaste: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = MonitorView()
        v.onArrowUp = onArrowUp
        v.onArrowDown = onArrowDown
        v.onReturn = onReturn
        v.onCommandDelete = onCommandDelete
        v.onEscape = onEscape
        v.onQuickPaste = onQuickPaste
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? MonitorView else { return }
        v.onArrowUp = onArrowUp
        v.onArrowDown = onArrowDown
        v.onReturn = onReturn
        v.onCommandDelete = onCommandDelete
        v.onEscape = onEscape
        v.onQuickPaste = onQuickPaste
    }

    private final class MonitorView: NSView {
        var onArrowUp: (() -> Void)?
        var onArrowDown: (() -> Void)?
        var onReturn: (() -> Void)?
        var onCommandDelete: (() -> Void)?
        var onEscape: (() -> Void)?
        var onQuickPaste: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                    self?.handle(e) ?? e
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m); monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, window.isVisible, event.window === window else { return event }
            if window.firstResponder is NSTextView { return event }
            let isCmd = event.modifierFlags.contains(.command)
            let isAltOnly = event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.control)
                && !event.modifierFlags.contains(.shift)
            if isAltOnly, let i = quickPasteIndex(for: event.keyCode) {
                onQuickPaste?(i); return nil
            }
            switch (event.keyCode, isCmd) {
            case (126, _): onArrowUp?(); return nil
            case (125, _): onArrowDown?(); return nil
            case (36, _), (76, _): onReturn?(); return nil
            case (51, true): onCommandDelete?(); return nil
            case (53, _): onEscape?(); return nil
            default: return event
            }
        }

        private func quickPasteIndex(for keyCode: UInt16) -> Int? {
            switch keyCode {
            case 18: return 0; case 19: return 1; case 20: return 2; case 21: return 3
            case 23: return 4; case 22: return 5; case 26: return 6; case 28: return 7
            case 25: return 8; case 29: return 9
            default: return nil
            }
        }
    }
}
