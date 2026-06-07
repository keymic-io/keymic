import Foundation

@main
struct SpeechEngineStatusTestRunner {
    static func main() {
        precondition(SpeechEngineStatus.displayLabel(for: .speechAnalyzer).contains("SpeechAnalyzer"))
        precondition(SpeechEngineStatus.displayLabel(for: .sfSpeechRecognizer).contains("SFSpeechRecognizer"))
        precondition(!SpeechEngineStatus.displayLabel(for: .sfSpeechRecognizer).contains("下载中"))
        precondition(SpeechEngineStatus.displayLabel(for: .sfSpeechRecognizerDownloadingAnalyzerAsset).contains("下载中"))
        precondition(SpeechEngineStatus.displayLabel(for: .sfSpeechRecognizerDownloadingAnalyzerAsset).contains("SFSpeechRecognizer"))
        precondition(SpeechEngineStatus.displayLabel(for: .senseVoice).contains("SenseVoice"))
        print("SpeechEngineStatusTests passed")
    }
}
