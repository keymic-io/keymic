import Foundation

@main
struct SpeakerAssignmentTests {
    static func main() {
        let ivs = [
            DiarizationInterval(start: 0, end: 10, speaker: 0),
            DiarizationInterval(start: 10, end: 20, speaker: 1),
            DiarizationInterval(start: 25, end: 30, speaker: 0),
        ]
        let segs: [(id: UUID, offset: Double)] = [
            (UUID(), 3),    // inside [0,10) → 0
            (UUID(), 10),   // inside [10,20) → 1 (start inclusive)
            (UUID(), 19.9), // inside [10,20) → 1
            (UUID(), 22),   // gap [20,25): nearer to [10,20) end(20, d=2) than [25,30) start(25, d=3) → 1
            (UUID(), 27),   // inside [25,30) → 0
            (UUID(), 100),  // past everything → nearest is [25,30) → 0
        ]
        let out = SpeakerAssignment.assign(segmentOffsets: segs, intervals: ivs)
        assert(out[segs[0].id] == 0, "3 → speaker 0")
        assert(out[segs[1].id] == 1, "10 → speaker 1 (start inclusive)")
        assert(out[segs[2].id] == 1, "19.9 → speaker 1")
        assert(out[segs[3].id] == 1, "22 → nearer to interval ending at 20")
        assert(out[segs[4].id] == 0, "27 → speaker 0")
        assert(out[segs[5].id] == 0, "100 → nearest interval [25,30] → 0")

        // No intervals → no assignments.
        let none = SpeakerAssignment.assign(segmentOffsets: segs, intervals: [])
        assert(none.isEmpty, "no intervals → empty map")

        print("SpeakerAssignmentTests passed")
    }
}
