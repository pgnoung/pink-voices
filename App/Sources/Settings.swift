import Foundation

enum LanguageMode: String, CaseIterable { case thaiMix = "th-mix", thai = "th-TH" }

final class Settings: ObservableObject {
    @Published var endpoint: String { didSet { save("endpoint", endpoint) } }
    @Published var language: LanguageMode { didSet { save("language", language.rawValue) } }
    @Published var hotKey: HoldKey { didSet { save("hotKey", Int(hotKey.rawValue)) } }
    @Published var dictionaryText: String { didSet { save("dictionary", dictionaryText) } }
    @Published var dictionaryEnabled: Bool { didSet { save("dictionaryEnabled", dictionaryEnabled) } }
    @Published var allowClipboardPaste: Bool { didSet { save("allowClipboardPaste", allowClipboardPaste) } }
    /// Spellings the person ticked as a brand or name: sound-alike spans are matched too.
    @Published var quickFixChord: QuickFixChord { didSet { save("quickFixChord", quickFixChord.rawValue) } }
    @Published var soundAlikeTerms: Set<String> { didSet { save("soundAlikeTerms", soundAlikeTerms.sorted()) } }
    private let defaults: UserDefaults

    init(defaults d: UserDefaults = .standard, legacyPreferences: [String: Any]? = nil) {
        defaults = d
        // Carry over the previous app's local choices. New choices belong to Pink voices.
        let legacy = legacyPreferences ?? d.persistentDomain(forName: "com.pngoung.thaidictation") ?? [:]
        func preference(_ key: String) -> Any? { d.object(forKey: key) ?? legacy[key] }
        endpoint = ProcessInfo.processInfo.environment["THAI_DICTATION_ENDPOINT"] ?? (preference("endpoint") as? String) ?? "ws://127.0.0.1:18081/v1/live"
        language = LanguageMode(rawValue: (preference("language") as? String) ?? "th-mix") ?? .thaiMix
        hotKey = (preference("hotKey") as? Int)
            .flatMap { UInt16(exactly: $0) }
            .flatMap(HoldKey.init(rawValue:)) ?? .rightOption
        var vocabulary = (preference("dictionary") as? String) ?? "ไลน์โอเอ=LINE OA\nแชทจีพีที=ChatGPT"
        if Self.ownerBuild && !d.bool(forKey: "installedMoltoVocabulary") {
            let aliases = Set(vocabulary.components(separatedBy: .newlines).compactMap {
                (try? BrandDictionary.rows($0))?.first?.alias.lowercased()
            })
            // The second spelling was observed from the local Thai speech fixture.
            for heard in ["มอโต้", "หม้อโต้"] where !aliases.contains(heard) {
                if !vocabulary.isEmpty && !vocabulary.hasSuffix("\n") { vocabulary += "\n" }
                vocabulary += heard + "=molto"
            }
            d.set(vocabulary, forKey: "dictionary")
            d.set(true, forKey: "installedMoltoVocabulary")
        }
        dictionaryText = vocabulary
        dictionaryEnabled = (preference("dictionaryEnabled") ?? preference("formatText")) as? Bool ?? true
        allowClipboardPaste = d.bool(forKey: "allowClipboardPaste")
        quickFixChord = QuickFixChord(rawValue: d.string(forKey: "quickFixChord") ?? "") ?? .controlOption
        if let marked = d.array(forKey: "soundAlikeTerms") as? [String] {
            soundAlikeTerms = Set(marked)
        } else {
            // Existing entries were taught for brands and names, so they start ticked.
            let spellings = vocabulary.components(separatedBy: .newlines).compactMap { (try? BrandDictionary.rows($0))?.first?.spelling }
            soundAlikeTerms = Set(spellings)
            d.set(Set(spellings).sorted(), forKey: "soundAlikeTerms")
        }
    }

    var dictionaryRows: [BrandDictionary.Row] {
        dictionaryText.components(separatedBy: .newlines).flatMap { (try? BrandDictionary.rows($0)) ?? [] }
    }

    var soundAlikeList: [SoundAlike.Term] {
        dictionaryEnabled ? SoundAlike.terms(rows: dictionaryRows, marked: soundAlikeTerms) : []
    }

    /// Adds or updates one heard → written pair; returns false for an invalid pair.
    @discardableResult
    func teach(heard rawHeard: String, written rawWritten: String, soundAlike: Bool) -> Bool {
        let heard = rawHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = rawWritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty, heard != written, heard.count <= 80, written.count <= 80,
              !(heard + written).contains("="), !(heard + written).contains(where: \.isNewline) else { return false }
        var lines = dictionaryText.components(separatedBy: .newlines).filter {
            (try? BrandDictionary.rows($0))?.first?.alias.lowercased() != heard.lowercased()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        lines.append("\(heard)=\(written)")
        dictionaryText = lines.joined(separator: "\n")
        dictionaryEnabled = true
        if soundAlike { soundAlikeTerms.insert(written) } else { soundAlikeTerms.remove(written) }
        return true
    }
    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
    static let ownerBuild = false
}
