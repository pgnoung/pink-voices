import Foundation

@main struct SoundAlikeCheck {
    static func main() {
        expect(ThaiSound.key("พี่ง่วง") == ThaiSound.key("พี่ง้วง"), "tone marks do not change the sound key")
        expect(ThaiSound.key("พิงก์คัตส์") == ThaiSound.key("พิ้งคัต"), "silent letters are dropped")

        let rows = [BrandDictionary.Row(alias: "โทรวูเม่น", spelling: "Gentlewoman"),
                    BrandDictionary.Row(alias: "โคเด็กซ์", spelling: "Codex"),
                    BrandDictionary.Row(alias: "มอโต้", spelling: "molto")]
        let terms = SoundAlike.terms(rows: rows, marked: ["Gentlewoman", "Codex", "molto", "พี่ง้วง"])
        func found(_ text: String) -> [SoundAlike.Match] { SoundAlike.matches(in: text, terms: terms) }

        let near = found("สำหรับ brand โทรวูแมนพี่เชื่อว่าสำเร็จแน่นอนครับ")
        expect(near.count == 1 && near[0].source == "โทรวูแมน" && near[0].spelling == "Gentlewoman" && near[0].isExact, "long near-identical brand is fixed on the Mac")
        expect(found("พี่ง่วงครับ วันนี้ว่างไหม").first.map { $0.spelling == "พี่ง้วง" && $0.isExact } == true, "same-sound name is fixed on the Mac")
        let loose = found("ขอบคุณพี่ฮงมากครับ")
        expect(loose.first.map { $0.source == "พี่ฮง" && !$0.isExact } == true, "looser sound-alike is sent to the AI, not applied")
        expect(found("เขียนโค้ดด้วยโคเด็กครับ").map(\.source) == ["โคเด็ก"], "short ordinary word is not a candidate")
        expect(found("ผมง่วงนอนมากเลย").isEmpty && found("โทรหาแม่หน่อย").isEmpty, "unrelated sentences stay untouched")
        expect(SoundAlike.matches(in: "ใช้ Codex กับ Gentlewoman", terms: terms).isEmpty, "correct spellings are left alone")

        let domain = "com.pngoung.pinkvoices.soundalike-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("ไลน์โอเอ=LINE OA", forKey: "dictionary")
        defaults.set(true, forKey: "installedMoltoVocabulary")
        let settings = Settings(defaults: defaults, legacyPreferences: [:])
        expect(settings.soundAlikeTerms == ["LINE OA"], "existing taught names start ticked")
        expect(settings.teach(heard: "โทรวูเม่น", written: "Gentlewoman", soundAlike: true), "teach a brand")
        expect(!settings.teach(heard: "a=b", written: "x", soundAlike: false) && !settings.teach(heard: "same", written: "same", soundAlike: false), "invalid pairs refused")
        expect(settings.teach(heard: "โทรวูเม่น", written: "Gentlewoman", soundAlike: true), "teaching twice updates in place")
        expect(settings.dictionaryText.components(separatedBy: "\n").filter { $0.hasPrefix("โทรวูเม่น=") }.count == 1, "no duplicate rows")
        expect(TextCleanup.finalText("สำหรับ brand โทรวูแมนพี่เชื่อว่า", settings: settings) == "สำหรับ brand Gentlewoman พี่เชื่อว่า", "sound-alike fixed with Thai/Latin spacing")
        let reopened = Settings(defaults: defaults, legacyPreferences: [:])
        expect(reopened.soundAlikeTerms.contains("Gentlewoman"), "tick persists")
        print("SoundAlike: tone and silent letters, near brands, loose names to AI, ordinary words kept, teach and persist")
    }

    static func expect(_ value: Bool, _ message: String) {
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
