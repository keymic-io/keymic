import Foundation

/// Pure display helpers for the meeting history UI — unit-testable without SwiftUI/SwiftData.
enum MeetingHistoryFormatter {
    /// "—" when not ended; else "Xm" under an hour, "Xh Ym" otherwise.
    static func duration(start: Date, end: Date?) -> String {
        guard let end else { return "—" }
        let total = Int(max(0, end.timeIntervalSince(start)))
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func sourceLabel(_ source: Int) -> String {
        switch source {
        case 0: return "我"
        case 1: return "对方"
        default: return "?"
        }
    }

    static func isInterrupted(endedAt: Date?) -> Bool { endedAt == nil }

    /// Display label for a diarized remote speaker cluster (0-based index → 1-based label).
    static func remoteSpeakerLabel(_ speakerIndex: Int) -> String {
        String(format: String(localized: "对方 %lld"), speakerIndex + 1)
    }
}
