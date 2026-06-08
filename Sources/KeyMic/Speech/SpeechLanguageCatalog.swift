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
    /// Chinese dialects that macOS exposes as their own language codes, pulled to sit right after
    /// 普通话(zh) in the picker. Order here is the display order within the cluster.
    private static let chineseDialectCodes = ["yue", "wuu"]

    /// Distinct languages Apple can recognize, deduped by language code, sorted by localized name.
    /// `SFSpeechRecognizer.supportedLocales()` is an unordered `Set`, so the dedupe scans it and
    /// the result is sorted for a stable picker order. The macro-language "zh" is shown as 普通话
    /// (Mandarin) — the system name is the generic "中文" — and the Chinese dialects are clustered
    /// immediately after it.
    static func distinctLanguages() -> [SpeechLanguage] {
        var seen = Set<String>()
        var out: [SpeechLanguage] = []
        for locale in SFSpeechRecognizer.supportedLocales() {
            guard let code = locale.language.languageCode?.identifier, !seen.contains(code) else { continue }
            seen.insert(code)
            let name = (code == "zh")
                ? String(localized: "Mandarin Chinese")
                : (Locale.current.localizedString(forLanguageCode: code) ?? code)
            out.append(SpeechLanguage(code: code, name: name))
        }
        out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return clusterChineseFamily(out)
    }

    /// Keep 普通话(zh) at its sorted position, then pull the Chinese dialects to immediately
    /// follow it (in `chineseDialectCodes` order). No-op when zh / the dialects are absent.
    private static func clusterChineseFamily(_ langs: [SpeechLanguage]) -> [SpeechLanguage] {
        let dialects = chineseDialectCodes.compactMap { code in langs.first { $0.code == code } }
        guard !dialects.isEmpty else { return langs }
        var rest = langs.filter { !chineseDialectCodes.contains($0.code) }
        guard let zhIdx = rest.firstIndex(where: { $0.code == "zh" }) else { return langs }
        rest.insert(contentsOf: dialects, at: zhIdx + 1)
        return rest
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
