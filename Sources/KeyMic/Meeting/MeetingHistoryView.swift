import SwiftData
import SwiftUI

/// History section for the Settings "Meeting" tab (embedded by MeetingSettingsView in M5).
/// Lists meetings newest-first; selecting one shows its transcript (offset-sorted, source-labeled).
///
/// Outer view ONLY injects the model container. The `@Query` lives in `MeetingHistoryContent`,
/// a CHILD — so the container is an ancestor of the query, which is required for `@Query` to
/// resolve. Attaching `.modelContainer` in the same view that declares `@Query` does not work:
/// the modifier only affects descendants, never the enclosing view's own query.
struct MeetingHistoryView: View {
    let store: TranscriptStore

    init(store: TranscriptStore) { self.store = store }

    var body: some View {
        MeetingHistoryContent(store: store)
            .modelContainer(store.modelContainer)
    }
}

/// A fixed-height, bordered two-pane browser. A `List`/`HSplitView` nested inside a grouped
/// `Form` section produces conflicting scroll containers (the symptom: the transcript scroll
/// area sits at the wrong offset). Here each pane owns exactly ONE scroll view inside a plain
/// `HStack`, and the whole thing has an explicit height — so it reads as a contained widget
/// within the section instead of fighting the form's own scrolling.
private struct MeetingHistoryContent: View {
    let store: TranscriptStore
    @Query(sort: \MeetingSession.startedAt, order: .reverse) private var sessions: [MeetingSession]
    @State private var selectedID: UUID?
    @State private var pendingDeleteID: UUID?

    private var selectedSession: MeetingSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    private var pendingDeleteTitle: String {
        guard let pendingDeleteID, let s = sessions.first(where: { $0.id == pendingDeleteID }) else { return "" }
        return s.title
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(width: 220)
            Divider()
            transcriptDetail
                .frame(maxWidth: .infinity)
        }
        .frame(height: 280)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1))
        .onChange(of: sessions.map(\.id)) { _, ids in
            // Keep a valid selection: default to newest, drop a deleted one.
            if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first }
        }
        .onAppear { if selectedID == nil { selectedID = sessions.first?.id } }
        .confirmationDialog(
            Text("Delete “\(pendingDeleteTitle)”?"),
            isPresented: Binding(get: { pendingDeleteID != nil },
                                 set: { if !$0 { pendingDeleteID = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeleteID
        ) { id in
            Button("Delete", role: .destructive) {
                store.deleteSession(id)
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
        } message: { _ in
            Text("This permanently removes this meeting and its transcript.")
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(sessions) { session in
                    sessionRow(session)
                }
            }
            .padding(6)
        }
        .overlay {
            if sessions.isEmpty {
                Text("暂无会议记录").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func sessionRow(_ session: MeetingSession) -> some View {
        let isSelected = session.id == selectedID
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title).lineLimit(1)
                    if MeetingHistoryFormatter.isInterrupted(endedAt: session.endedAt) {
                        Text("中断").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text("\(MeetingHistoryFormatter.duration(start: session.startedAt, end: session.endedAt)) · \(session.segments.count) 段")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                pendingDeleteID = session.id
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete meeting")
            .accessibilityLabel(Text("Delete meeting"))
            .opacity(isSelected ? 1 : 0.45)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = session.id }
        .contextMenu {
            Button("Delete", role: .destructive) { pendingDeleteID = session.id }
        }
    }

    @ViewBuilder
    private var transcriptDetail: some View {
        if let session = selectedSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.segments.sorted { $0.offset < $1.offset }, id: \.id) { seg in
                        HStack(alignment: .top, spacing: 8) {
                            Text(MeetingHistoryFormatter.sourceLabel(seg.source))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(seg.source == 0 ? .blue : .green)
                                .frame(width: 36, alignment: .leading)
                            Text(seg.text).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("选择一场会议查看转录稿")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
