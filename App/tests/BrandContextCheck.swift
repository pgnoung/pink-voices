import Foundation

@main struct BrandContextCheck {
    static func main() {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let book = BrandContext.load(from: url) else { fatalError("cannot load packaged brand rules") }
        precondition(BrandContext.load(from: nil) == nil)
        let taught = [BrandDictionary.Row(alias: "พิงก์คัตส์", spelling: "Pink Cuts"),
                      BrandDictionary.Row(alias: "มอโต้", spelling: "molto")]
        func actual(_ text: String, _ rows: [BrandDictionary.Row]? = nil) -> [String] {
            book.candidates(in: text, taught: rows ?? taught).map { $0.replacement }.sorted()
        }
        for text in ["ทรงบะหรี่พิ้งครับและโมโทครับ", "ส่งบรีฟพิ้งคับกับโมโทค่ะ", "โมโท หรือ พิ้งครับ"] {
            precondition(actual(text) == ["Pink Cuts", "molto"], text)
        }
        precondition(actual("ขอใช้ Pink Cuts กับโมโทวันนี้") == ["molto"])
        precondition(actual("ไฟล์โมโทครับ") == ["molto"])
        precondition(actual("ใช้แชทจีพีทีกับโคเดกซ์", []) == ["ChatGPT", "Codex"])
        precondition(actual("บริษัทนี้ใช้ google drive ครับ", []) == ["Google Drive"])
        for text in ["ขอสีพิ้งครับ", "เปิดไฟสีพิ้งครับ", "นั่นคือโมโทครับ", "ขับรถโมโทกับพิ้งครับ",
                     "ลองเปิดโมโทโรล่า", "พิ้งครับและโมโทไซค์", "ไฟล์ https://test.invalid/โมโท",
                     "พิ้งครับ เป็นสีที่ชอบมากที่สุดในงานนี้ ส่วนโมโทเขียนต่างกัน",
                     "พิ้งครับกับโมโทและโมโท", "นัด 10:30 น. วันจันทร์"] {
            precondition(actual(text).isEmpty, text)
        }
        precondition(actual("พิ้งครับกับโมโท", [.init(alias: "มอโต้", spelling: "MOTO")]).isEmpty)
        precondition(book.exactSpellings(in: "เจอกันใน Google Drive") == ["Google Drive"])
        print("Bundled glossary verified with original ASR, other contexts, Plaud terms, conflicts and negatives")
    }
}
