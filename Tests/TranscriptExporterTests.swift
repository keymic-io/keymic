import Foundation

@main
struct TranscriptExporterTests {
    static func main() {
        // Time formatters
        assert(TranscriptExporter.clock(2) == "0:02", "clock 2s")
        assert(TranscriptExporter.clock(65) == "1:05", "clock 65s")
        assert(TranscriptExporter.clock(3725) == "62:05", "clock 62m05s (minutes not padded to hours)")
        assert(TranscriptExporter.srtTime(2) == "00:00:02,000", "srt 2s")
        assert(TranscriptExporter.srtTime(3725) == "01:02:05,000", "srt 1h02m05s")

        let data = MeetingExportData(
            title: "团队周会",
            dateText: "2026-06-26 14:30",
            durationText: "12m",
            segments: [
                ExportSegment(offset: 2, text: "大家好", label: "我"),        // next at 5 → end 5 (gap<7)
                ExportSegment(offset: 5, text: "hi", label: "对方 2"),         // next at 20 → end 12 (gap>7 → +7)
                ExportSegment(offset: 20, text: "ok", label: "我"),            // last → end 27
            ])

        let md = TranscriptExporter.export(data, as: .markdown)
        let expectedMd = [
            "# 团队周会",
            "",
            "2026-06-26 14:30 · 12m",
            "",
            "**[0:02] 我**：大家好",
            "**[0:05] 对方 2**：hi",
            "**[0:20] 我**：ok",
        ].joined(separator: "\n")
        assert(md == expectedMd, "markdown mismatch:\n\(md)")

        let txt = TranscriptExporter.export(data, as: .plainText)
        let expectedTxt = [
            "团队周会",
            "2026-06-26 14:30 · 12m",
            "",
            "[0:02] 我: 大家好",
            "[0:05] 对方 2: hi",
            "[0:20] 我: ok",
        ].joined(separator: "\n")
        assert(txt == expectedTxt, "plainText mismatch:\n\(txt)")

        let srt = TranscriptExporter.export(data, as: .srt)
        let expectedSrt = [
            "1", "00:00:02,000 --> 00:00:05,000", "我: 大家好", "",
            "2", "00:00:05,000 --> 00:00:12,000", "对方 2: hi", "",
            "3", "00:00:20,000 --> 00:00:27,000", "我: ok",
        ].joined(separator: "\n")
        assert(srt == expectedSrt, "srt mismatch:\n\(srt)")

        // Empty transcript
        let empty = MeetingExportData(title: "空会议", dateText: "2026-06-26 09:00", durationText: "—", segments: [])
        assert(TranscriptExporter.export(empty, as: .markdown) == "# 空会议\n\n2026-06-26 09:00 · —", "empty md = header only")
        assert(TranscriptExporter.export(empty, as: .plainText) == "空会议\n2026-06-26 09:00 · —", "empty txt = header only")
        assert(TranscriptExporter.export(empty, as: .srt) == "", "empty srt = empty string")

        assert(ExportFormat.markdown.fileExtension == "md" && ExportFormat.plainText.fileExtension == "txt" && ExportFormat.srt.fileExtension == "srt", "file extensions")

        print("TranscriptExporterTests passed")
    }
}
