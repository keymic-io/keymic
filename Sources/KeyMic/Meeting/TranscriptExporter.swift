import Foundation

/// Output format for a meeting transcript export.
enum ExportFormat: CaseIterable {
    case markdown, plainText, srt

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .srt: return "srt"
        }
    }

    var displayName: String {
        switch self {
        case .markdown: return String(localized: "Markdown")
        case .plainText: return String(localized: "Plain Text")
        case .srt: return String(localized: "SRT")
        }
    }
}

/// One transcript line ready for export. `label` is already resolved (speakerLabel ?? 我/对方).
struct ExportSegment {
    let offset: TimeInterval
    let text: String
    let label: String
}

/// Everything the exporter needs, with date/duration PRE-FORMATTED by the caller (locale-aware),
/// so the exporter itself is pure and deterministic. `segments` must be offset-ascending.
struct MeetingExportData {
    let title: String
    let dateText: String
    let durationText: String
    let segments: [ExportSegment]
}

/// Pure transcript formatter — no SwiftData/AppKit, fully unit-testable over fixtures.
enum TranscriptExporter {
    /// SRT/last-segment cue length cap (seconds); also the max gap shown before the next cue.
    private static let maxCueSeconds: TimeInterval = 7
    /// SRT minimum cue duration to avoid zero-length cues.
    private static let minCueSeconds: TimeInterval = 0.5

    static func export(_ data: MeetingExportData, as format: ExportFormat) -> String {
        switch format {
        case .markdown: return markdown(data)
        case .plainText: return plainText(data)
        case .srt: return srt(data)
        }
    }

    // MARK: Formats

    private static func markdown(_ d: MeetingExportData) -> String {
        var lines = ["# \(d.title)", "", "\(d.dateText) · \(d.durationText)"]
        if !d.segments.isEmpty {
            lines.append("")
            for s in d.segments {
                lines.append("**[\(clock(s.offset))] \(s.label)**：\(s.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func plainText(_ d: MeetingExportData) -> String {
        var lines = [d.title, "\(d.dateText) · \(d.durationText)"]
        if !d.segments.isEmpty {
            lines.append("")
            for s in d.segments {
                lines.append("[\(clock(s.offset))] \(s.label): \(s.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func srt(_ d: MeetingExportData) -> String {
        guard !d.segments.isEmpty else { return "" }
        var blocks: [String] = []
        for (i, s) in d.segments.enumerated() {
            let start = s.offset
            let rawEnd: TimeInterval
            if i + 1 < d.segments.count {
                rawEnd = min(d.segments[i + 1].offset, start + maxCueSeconds)
            } else {
                rawEnd = start + maxCueSeconds
            }
            let end = max(start + minCueSeconds, rawEnd)
            blocks.append([
                "\(i + 1)",
                "\(srtTime(start)) --> \(srtTime(end))",
                "\(s.label): \(s.text)",
            ].joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    // MARK: Time helpers

    /// `m:ss` — minutes not padded to hours (a 62-minute meeting shows `62:05`).
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `HH:MM:SS,mmm` with a comma decimal separator, per the SRT spec.
    static func srtTime(_ seconds: TimeInterval) -> String {
        let ms = Int((seconds * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let milli = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, milli)
    }
}
