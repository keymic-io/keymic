import Foundation

/// One diarization span: speaker `speaker` held the floor from `start` to `end` (seconds from
/// the audio's beginning, which equals the meeting's start). Produced by the sherpa diarizer.
struct DiarizationInterval {
    let start: Double
    let end: Double
    let speaker: Int
}

/// Pure mapping of transcript segments (each known only by its start `offset`) onto diarization
/// speakers. No CoreAudio / sherpa / SwiftData dependency, so it is unit-testable over fixtures.
enum SpeakerAssignment {
    /// Assign each segment the speaker of the interval covering its `offset`; if no interval
    /// covers it, the nearest interval by edge distance (ties → earlier interval). Returns no
    /// entry for a segment only when `intervals` is empty.
    static func assign(segmentOffsets: [(id: UUID, offset: Double)],
                       intervals: [DiarizationInterval]) -> [UUID: Int] {
        guard !intervals.isEmpty else { return [:] }
        var result: [UUID: Int] = [:]
        for seg in segmentOffsets {
            if let covering = intervals.first(where: { seg.offset >= $0.start && seg.offset < $0.end }) {
                result[seg.id] = covering.speaker
                continue
            }
            // Nearest by distance to the interval (0 if inside, else gap to the closer edge).
            var best = intervals[0]
            var bestDist = Double.greatestFiniteMagnitude
            for iv in intervals {
                let dist: Double
                if seg.offset < iv.start { dist = iv.start - seg.offset }
                else if seg.offset >= iv.end { dist = seg.offset - iv.end }
                else { dist = 0 }
                if dist < bestDist { bestDist = dist; best = iv }
            }
            result[seg.id] = best.speaker
        }
        return result
    }
}
