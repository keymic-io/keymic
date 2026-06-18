import Foundation

/// Which audio the meeting captures. Raw values are the persisted contract.
enum MeetingAudioSource: String, CaseIterable {
    case mic       // 仅麦克风(本人)
    case system    // 仅系统音频(对方)
    case both      // 两者(默认)
}

/// UserDefaults-backed meeting settings. Injectable `defaults` keeps it unit-testable.
enum MeetingPreferences {
    static let audioSourceKey = "meetingAudioSource"
    static let captionRemembersPositionKey = "meetingCaptionRemembersPosition"

    static func audioSource(_ defaults: UserDefaults = .standard) -> MeetingAudioSource {
        guard let raw = defaults.string(forKey: audioSourceKey),
              let value = MeetingAudioSource(rawValue: raw) else { return .both }
        return value
    }

    static func setAudioSource(_ value: MeetingAudioSource, _ defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: audioSourceKey)
    }

    /// true → caption window remembers its last drag position; false → default corner each time.
    static func captionRemembersPosition(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: captionRemembersPositionKey) as? Bool ?? true
    }

    static func setCaptionRemembersPosition(_ value: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: captionRemembersPositionKey)
    }
}
