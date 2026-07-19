import Foundation

@main
struct MeetingPreferencesTests {
    static func main() {
        let suite = "MeetingPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // default is .both when unset
        assert(MeetingPreferences.audioSource(defaults) == .both, "default audio source must be .both")

        // round-trips through UserDefaults
        MeetingPreferences.setAudioSource(.mic, defaults)
        assert(MeetingPreferences.audioSource(defaults) == .mic, "audioSource must persist .mic")
        MeetingPreferences.setAudioSource(.system, defaults)
        assert(MeetingPreferences.audioSource(defaults) == .system, "audioSource must persist .system")

        // unknown raw value falls back to .both
        defaults.set("garbage", forKey: "meetingAudioSource")
        assert(MeetingPreferences.audioSource(defaults) == .both, "invalid raw must fall back to .both")

        // enum raw values are the stable contract
        assert(MeetingAudioSource.mic.rawValue == "mic")
        assert(MeetingAudioSource.system.rawValue == "system")
        assert(MeetingAudioSource.both.rawValue == "both")

        print("MeetingPreferencesTests passed")
    }
}
