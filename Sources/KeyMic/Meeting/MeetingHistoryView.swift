import SwiftData
import SwiftUI

/// History section for the Settings "Meeting" tab (embedded by MeetingSettingsView in M5).
/// Lists meetings newest-first; selecting one shows its transcript (offset-sorted, source-labeled).
struct MeetingHistoryView: View {
    let store: TranscriptStore
    @Query(sort: \MeetingSession.startedAt, order: .reverse) private var sessions: [MeetingSession]
    @State private var selectedID: UUID?

    init(store: TranscriptStore) { self.store = store }

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 200, idealWidth: 240)
            transcriptDetail
                .frame(minWidth: 280)
        }
        .modelContainer(store.modelContainer)
    }

    private var sessionList: some View {
        List(sessions, selection: $selectedID) { session in
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
            .tag(session.id)
            .contextMenu {
                Button("删除", role: .destructive) { store.deleteSession(session.id) }
            }
        }
        .overlay {
            if sessions.isEmpty {
                Text("暂无会议记录").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var transcriptDetail: some View {
        if let id = selectedID, let session = sessions.first(where: { $0.id == id }) {
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
            Text("选择一场会议查看转录稿").foregroundStyle(.secondary)
        }
    }
}
