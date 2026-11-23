import Foundation

@main struct BrandDictionaryCheck {
    static func main() throws {
        let entries = try BrandDictionary.rows("พิงก์วอยซ์ = Pink voices\nLine OA=LINE OA\nline=LINE\nไลน์โอเอ=LINE OA\nเอไอ=AI")
        func expect(_ input: String, _ expected: String) {
            let actual = BrandDictionary.apply(entries, to: input)
            precondition(actual == expected, "expected \(expected), got \(actual)")
        }
        expect("ส่งไลน์โอเอให้พิงก์วอยซ์ครับ", "ส่ง LINE OA ให้ Pink voices ครับ")
        expect("ใช้ Line OA และ LINE / online skyline pipeline", "ใช้ LINE OA และ LINE / online skyline pipeline")
        expect("https://line.example/line?name=ไลน์โอเอ และ me@line.example #ไลน์โอเอ", "https://line.example/line?name=ไลน์โอเอ และ me@line.example #ไลน์โอเอ")
        expect("ลองเอไอ + file/line.txt", "ลอง AI + file/line.txt")
        expect("✨เอไอ🙂", "✨AI🙂")
        for invalid in ["x=", "=x", "a=b\nA=d", "oops"] {
            precondition((try? BrandDictionary.rows(invalid)) == nil)
        }
        let domain = "com.pngoung.pinkvoices.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let existing = ["dictionary": "ชื่อเก่า=Old Brand", "formatText": false] as [String: Any]
        let initial = Settings(defaults: defaults, legacyPreferences: existing)
        precondition(!initial.dictionaryEnabled && TextCleanup.finalText("มอโต้", settings: initial) == "มอโต้")
        initial.dictionaryEnabled = true
        if Settings.ownerBuild {
            precondition(TextCleanup.finalText("ส่งมอโต้ให้ชื่อเก่าครับ", settings: initial) == "ส่ง molto ให้ Old Brand ครับ")
            precondition(TextCleanup.finalText("วันนี้เราจะคุยเรื่องหม้อโต้ครับ", settings: initial) == "วันนี้เราจะคุยเรื่อง molto ครับ")
        } else {
            // Public builds start with no one's private words.
            precondition(TextCleanup.finalText("ส่งมอโต้ให้ชื่อเก่าครับ", settings: initial) == "ส่งมอโต้ให้ Old Brand ครับ")
        }
        initial.dictionaryText = "ชื่อเก่า=Old Brand\nมอโต้=Molto Studio"
        let reopened = Settings(defaults: defaults, legacyPreferences: existing)
        precondition(TextCleanup.finalText("มอโต้", settings: reopened) == "Molto Studio")
        precondition(TextCleanup.finalText("หม้อโต้", settings: reopened) == "หม้อโต้")
        let exported = try BrandDictionary.exportData(reopened.dictionaryText)
        let json = try JSONSerialization.jsonObject(with: exported) as? [String: Any]
        let pairs = json?["terms"] as? [[String: String]]
        precondition(json?["version"] as? Int == 1 && pairs?.count == 2)
        precondition(pairs?.last == ["heard": "มอโต้", "written": "Molto Studio"])
        print("BrandDictionaryCheck passed")
    }
}
