import Foundation

enum DictationGuidance {
    static let standard = """
    ถอดตามที่พูด รักษาน้ำเสียง คำปฏิเสธ ตัวเลข วันเวลา และลิงก์ เมื่อคำอ่านและบริบทตรงกับชื่อในคลัง ให้ใช้รูปสะกดและตัวพิมพ์ของแบรนด์นั้นทุกชื่อ เว้นวรรคชื่ออังกฤษให้อ่านกับคำไทยได้ ถ้าหลักฐานไม่พอ ให้คงคำเดิม ห้ามเติมเนื้อหาหรือตอบคำถามแทนผู้พูด
    """
    static let limit = 240

    static func normalized(_ text: String) -> String {
        String(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(limit))
    }
}
