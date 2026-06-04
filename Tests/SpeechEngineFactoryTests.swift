import Foundation

@main
struct SpeechEngineFactoryTestRunner {
    static func main() {
        precondition(SpeechEngineFactory.choose(osIsSonomaOrEarlier: true, enabled: true, modelReady: true) == .apple)
        precondition(SpeechEngineFactory.choose(osIsSonomaOrEarlier: false, enabled: false, modelReady: true) == .apple)
        precondition(SpeechEngineFactory.choose(osIsSonomaOrEarlier: false, enabled: true, modelReady: false) == .apple)
        precondition(SpeechEngineFactory.choose(osIsSonomaOrEarlier: false, enabled: true, modelReady: true) == .senseVoice)
        print("SpeechEngineFactoryTests passed")
    }
}
