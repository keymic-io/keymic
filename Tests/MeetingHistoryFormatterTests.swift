import Foundation

@main
struct MeetingHistoryFormatterTests {
    static func main() {
        // duration: ended − started, formatted "Xm" / "Xh Ym"
        let start = Date(timeIntervalSince1970: 0)
        assert(MeetingHistoryFormatter.duration(start: start, end: Date(timeIntervalSince1970: 42 * 60)) == "42m")
        assert(MeetingHistoryFormatter.duration(start: start, end: Date(timeIntervalSince1970: 3 * 3600 + 5 * 60)) == "3h 5m")
        // in-progress / interrupted → nil end → em-dash duration
        assert(MeetingHistoryFormatter.duration(start: start, end: nil) == "—")

        // source label
        assert(MeetingHistoryFormatter.sourceLabel(0) == "我")
        assert(MeetingHistoryFormatter.sourceLabel(1) == "对方")
        assert(MeetingHistoryFormatter.sourceLabel(7) == "?")

        // interrupted flag = endedAt nil
        assert(MeetingHistoryFormatter.isInterrupted(endedAt: nil) == true)
        assert(MeetingHistoryFormatter.isInterrupted(endedAt: Date()) == false)

        // remoteSpeakerLabel: diarized speaker index → "对方 N"
        assert(MeetingHistoryFormatter.remoteSpeakerLabel(0) == "对方 1", "index 0 → 对方 1")
        assert(MeetingHistoryFormatter.remoteSpeakerLabel(2) == "对方 3", "index 2 → 对方 3")

        print("MeetingHistoryFormatterTests passed")
    }
}
