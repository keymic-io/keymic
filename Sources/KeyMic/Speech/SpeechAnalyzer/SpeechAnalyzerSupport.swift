#if KEYMIC_HAS_SPEECH_ANALYZER
import AVFoundation
import Foundation
import Speech
import os.log

private let logger = Logger(subsystem: "io.keymic.app", category: "SpeechAnalyzerSupport")

/// Runtime gate + asset manager for Apple's macOS 26 SpeechAnalyzer path.
/// Answers, synchronously, two questions the engine factory needs:
///   - is `locale` in SpeechTranscriber's supported set?
///   - is that locale's on-device asset installed (else it kicks a download)?
/// Both answers start false and flip true asynchronously; each change invokes
/// `onReadinessChanged` so AppDelegate can re-run the factory and swap engines.
/// Also caches the analyzer audio format (async to resolve) for the engine.
@available(macOS 26, *)
@MainActor
final class SpeechAnalyzerSupport {
    /// Invoked (on main) whenever supported-set / asset / download state changes.
    var onReadinessChanged: (() -> Void)?

    private var supportedLocaleIDs: Set<String> = []
    private var installedLocaleIDs: Set<String> = []
    private var downloadingLocaleIDs: Set<String> = []
    private var didLoadSupported = false
    private(set) var analyzerFormat: AVAudioFormat?

    /// Normalize to dashed BCP-47 to match SFSpeechRecognizer.supportedLocales().
    private static func normalize(_ id: String) -> String {
        id.replacingOccurrences(of: "_", with: "-")
    }

    func isSupported(_ locale: Locale) -> Bool {
        supportedLocaleIDs.contains(Self.normalize(locale.identifier))
    }
    func isAssetReady(_ locale: Locale) -> Bool {
        installedLocaleIDs.contains(Self.normalize(locale.identifier))
    }
    func isDownloading(_ locale: Locale) -> Bool {
        downloadingLocaleIDs.contains(Self.normalize(locale.identifier))
    }

    /// Fetch the supported-locale set + analyzer audio format once. Idempotent.
    func bootstrapIfNeeded() {
        guard !didLoadSupported else { return }
        didLoadSupported = true
        Task { [weak self] in
            let locales = await SpeechTranscriber.supportedLocales
            let probe = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                          preset: .progressiveTranscription)
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
            await MainActor.run {
                guard let self else { return }
                self.supportedLocaleIDs = Set(locales.map { Self.normalize($0.identifier) })
                self.analyzerFormat = format
                logger.info("SpeechAnalyzer: \(self.supportedLocaleIDs.count) locales, format \(format != nil)")
                self.onReadinessChanged?()
            }
        }
    }

    /// Ensure the asset for `locale` is installed; kicks a download if needed.
    /// No-op if unsupported, already installed, or already downloading.
    func ensureAsset(for locale: Locale) {
        let key = Self.normalize(locale.identifier)
        guard supportedLocaleIDs.contains(key) else { return }
        guard !installedLocaleIDs.contains(key), !downloadingLocaleIDs.contains(key) else { return }
        downloadingLocaleIDs.insert(key)
        onReadinessChanged?()  // surfaces "downloading" state to the status row
        Task { [weak self] in
            do {
                let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                await MainActor.run {
                    guard let self else { return }
                    self.downloadingLocaleIDs.remove(key)
                    self.installedLocaleIDs.insert(key)
                    logger.info("SpeechAnalyzer asset installed for \(key, privacy: .public)")
                    self.onReadinessChanged?()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.downloadingLocaleIDs.remove(key)
                    logger.error("SpeechAnalyzer asset install failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.onReadinessChanged?()
                }
            }
        }
    }
}
#endif
