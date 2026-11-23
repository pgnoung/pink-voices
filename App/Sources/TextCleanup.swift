import Foundation

struct BrandDictionary {
    struct Row {
        let alias: String
        let spelling: String
    }

    static func rows(_ text: String) throws -> [Row] {
        var entries: [Row] = []
        var seen: Set<String> = []
        for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError(line: offset + 1, reason: "ใส่ทั้งคำที่ได้ยินและชื่อที่ต้องการ โดยคั่นด้วย =")
            }
            guard seen.insert(parts[0].lowercased()).inserted else {
                throw ValidationError(line: offset + 1, reason: "คำที่ได้ยินซ้ำกับบรรทัดก่อนหน้า")
            }
            entries.append(Row(alias: parts[0], spelling: parts[1]))
        }
        return entries
    }

    /// Portable text-only pairs for vocabulary biasing or a future, separately labelled speech corpus.
    static func exportData(_ dictionaryText: String) throws -> Data {
        struct Term: Encodable { let heard: String; let written: String }
        struct Vocabulary: Encodable {
            let schema = "pinkvoices.vocabulary"
            let version = 1
            let terms: [Term]
        }
        let terms = try rows(dictionaryText).map { Term(heard: $0.alias, written: $0.spelling) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Vocabulary(terms: terms))
    }

    struct ValidationError: LocalizedError {
        let line: Int
        let reason: String
        var errorDescription: String? { "บรรทัดที่ \(line) • \(reason)" }
    }

    private static let protected = #"(?:[a-z][a-z0-9+.\-]*://|www\.)\S+|[\w.%+\-]+@[\w.\-]+\.[a-z]{2,}|[a-z0-9_.\-]+(?:[./][a-z0-9_./\-]+)+|[@#][\p{L}\p{M}\p{N}_]+"#
    private static let latinWord = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
    private static let thai = CharacterSet(charactersIn: "\u{0E01}"..."\u{0E4E}")

    static func apply(_ entries: [Row], to text: String) -> String {
        guard !entries.isEmpty else { return text }
        var replacements: [String: String] = [:]
        // One pass on the original string prevents one replacement feeding another.
        for entry in entries { replacements[entry.alias.lowercased()] = entry.spelling }
        let choices = entries.sorted { $0.alias.utf16.count > $1.alias.utf16.count }.map { entry -> String in
            let key = entry.alias
            let left = key.unicodeScalars.first.map(latinWord.contains) == true ? "(?<![A-Za-z0-9_])" : ""
            let right = key.unicodeScalars.last.map(latinWord.contains) == true ? "(?![A-Za-z0-9_])" : ""
            return left + NSRegularExpression.escapedPattern(for: key) + right
        }
        guard let regex = try? NSRegularExpression(pattern: "(?:\(protected))|(\(choices.joined(separator: "|")))", options: [.caseInsensitive]) else { return text }
        let original = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)) {
            let range = match.range(at: 1)
            guard range.location != NSNotFound,
                  let spelling = replacements[original.substring(with: range).lowercased()] else { continue }
            let gap = original.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += gap
            if let before = out.unicodeScalars.last, thai.contains(before),
               let first = spelling.unicodeScalars.first, latinWord.contains(first) { out += " " }
            out += spelling
            cursor = NSMaxRange(range)
            if cursor < original.length, let last = spelling.unicodeScalars.last, latinWord.contains(last),
               let next = UnicodeScalar(original.character(at: cursor)), thai.contains(next) { out += " " }
        }
        return out + original.substring(from: cursor)
    }
}

struct TextCleanup {
    static func finalText(_ raw: String, settings: Settings) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.dictionaryEnabled else { return text }
        // Older preferences can contain malformed lines. Preserve their valid entries.
        let entries = settings.dictionaryText.components(separatedBy: .newlines).flatMap {
            (try? BrandDictionary.rows($0)) ?? []
        }
        let taught = BrandDictionary.apply(entries, to: text)
        // Names that sound the same as a taught brand are fixed on the Mac too.
        let near = SoundAlike.matches(in: taught, terms: settings.soundAlikeList).filter(\.isExact)
        guard !near.isEmpty else { return taught }
        var seen = Set<String>()
        let rows = near.compactMap { match -> BrandDictionary.Row? in
            seen.insert(match.source.lowercased()).inserted ? BrandDictionary.Row(alias: match.source, spelling: match.spelling) : nil
        }
        return BrandDictionary.apply(rows, to: taught)
    }
}
