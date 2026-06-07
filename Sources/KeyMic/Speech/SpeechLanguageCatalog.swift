import Foundation
import Speech

/// A distinct spoken language — language code + system-localized display name. Region is
/// intentionally dropped: the picker shows "中文", not "中文(中国)".
struct SpeechLanguage: Identifiable, Hashable {
    let code: String      // BCP-47 language code, e.g. "zh", "en", "ja"
    let name: String
    var id: String { code }
}

/// Canonical, region-free language registry shared by the Language picker, the per-model
/// language-support table, and the engine factory. Keyed by language code so every surface
/// renders the SAME name (all names come from the system locale API).
enum SpeechLanguageCatalog {
    /// Distinct languages Apple can recognize, deduped by language code, sorted by localized name.
    /// `SFSpeechRecognizer.supportedLocales()` is an unordered `Set`, so the dedupe scans it and
    /// the result is sorted for a stable picker order.
    static func distinctLanguages() -> [SpeechLanguage] {
        var seen = Set<String>()
        var out: [SpeechLanguage] = []
        for locale in SFSpeechRecognizer.supportedLocales() {
            guard let code = locale.language.languageCode?.identifier, !seen.contains(code) else { continue }
            seen.insert(code)
            out.append(SpeechLanguage(code: code, name: Locale.current.localizedString(forLanguageCode: code) ?? code))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Language code of a stored locale identifier (e.g. "zh-CN" → "zh"). Empty/invalid → nil.
    static func languageCode(of localeIdentifier: String) -> String? {
        guard !localeIdentifier.isEmpty else { return nil }
        return Locale(identifier: localeIdentifier).language.languageCode?.identifier
    }

    /// A representative full locale for a language code, used to persist a region-free selection
    /// and to build the Apple recognizer (which needs a concrete locale). Prefers a locale whose
    /// region matches the current system region, else the lexicographically-first supported match
    /// (deterministic — `supportedLocales()` is unordered). Returns nil if Apple can't do `code`.
    static func representativeLocale(for code: String) -> Locale? {
        let matches = SFSpeechRecognizer.supportedLocales()
            .filter { $0.language.languageCode?.identifier == code }
            .sorted { $0.identifier < $1.identifier }
        guard !matches.isEmpty else { return nil }
        if let systemRegion = Locale.current.region?.identifier,
           let regional = matches.first(where: { $0.region?.identifier == systemRegion }) {
            return regional
        }
        return matches.first
    }
}
