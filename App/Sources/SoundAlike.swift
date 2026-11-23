import Foundation

/// Rough Thai sound keys, so a taught name also catches spellings that sound alike
/// (พี่ง่วง ≈ พี่ง้วง, โทรวูแมน ≈ โทรวูเม่น) without listing every variant.
enum ThaiSound {
    private static let consonants: [Character: Character] = {
        var map = [Character: Character]()
        func set(_ letters: String, _ sound: Character) { for letter in letters { map[letter] = sound } }
        set("ก", "k"); set("ขฃคฅฆ", "K"); set("ง", "G"); set("จ", "j"); set("ฉชฌ", "C")
        set("ซศษส", "S"); set("ญย", "Y"); set("ฎด", "D"); set("ฏต", "T"); set("ฐฑฒถทธ", "H")
        set("ณน", "N"); set("บ", "B"); set("ป", "p"); set("ผพภ", "P"); set("ฝฟ", "F")
        set("ม", "M"); set("รลฬฤฦ", "L"); set("ว", "W"); set("หฮ", "h")
        return map
    }()
    private static let vowels: [Character: String] = [
        "ะ": "a", "ั": "a", "า": "a", "ๅ": "a", "ำ": "aM", "ิ": "i", "ี": "i", "ึ": "U", "ื": "U",
        "ุ": "u", "ู": "u", "เ": "e", "แ": "E", "โ": "o", "ใ": "I", "ไ": "I"
    ]
    private static let silent: Set<Character> = ["่", "้", "๊", "๋", "็", "ํ", "ๆ", "ฯ", "อ", " "]
    private static let sonorants: Set<Character> = ["ง", "ญ", "น", "ม", "ย", "ร", "ล", "ว"]

    static func key(_ text: String) -> [Character] {
        let letters = Array(text.lowercased().precomposedStringWithCanonicalMapping.unicodeScalars.map(Character.init))
        var out = [Character]()
        for (index, letter) in letters.enumerated() {
            if letter == "์" { if !out.isEmpty { out.removeLast() }; continue } // silent letter mark
            if silent.contains(letter) { continue }
            // ห before a sonorant only changes the tone (หมา, หนู, หวาน).
            if letter == "ห", index + 1 < letters.count, sonorants.contains(letters[index + 1]) { continue }
            if let sound = consonants[letter] { out.append(sound); continue }
            if let sound = vowels[letter] { out.append(contentsOf: sound); continue }
            if letter.isLetter || letter.isNumber { out.append(letter) }
        }
        return out
    }

    /// 1 means the keys are identical; 0 means nothing in common.
    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

/// Finds spans in a transcript that sound like a taught brand or name.
enum SoundAlike {
    struct Term: Equatable {
        let spelling: String
        let heard: [String]
    }

    struct Match: Equatable {
        let range: NSRange
        let source: String
        let spelling: String
        let score: Double
        /// Same sound, or one sound off in a long name: applied on the Mac without asking the AI.
        let isExact: Bool
    }

    static let looseThreshold = 0.6
    static let minimumKey = 3
    static let minimumExactKey = 4
    static let nearKey = 6
    static let nearThreshold = 0.85
    static let shortKey = 3
    static let shortThreshold = 0.75

    /// Brand/name entries the person ticked, grouped with every way they were heard.
    static func terms(rows: [BrandDictionary.Row], marked: Set<String>) -> [Term] {
        var grouped = [String: [String]]()
        var order = [String]()
        for row in rows where marked.contains(row.spelling) {
            if grouped[row.spelling] == nil { order.append(row.spelling); grouped[row.spelling] = [] }
            grouped[row.spelling]?.append(row.alias)
        }
        for spelling in marked where grouped[spelling] == nil && spelling.unicodeScalars.contains(where: isThai) {
            order.append(spelling)
            grouped[spelling] = []
        }
        return order.map { spelling in
            var heard = grouped[spelling] ?? []
            if spelling.unicodeScalars.contains(where: isThai) { heard.append(spelling) }
            return Term(spelling: spelling, heard: heard)
        }
    }

    static func matches(in text: String, terms: [Term], protected: [NSRange] = []) -> [Match] {
        let source = text as NSString
        guard !terms.isEmpty, source.length > 0, source.length <= 8000 else { return [] }
        let tokens = wordRanges(text)
        var found = [Match]()
        for start in tokens.indices {
            for length in 1...4 where start + length <= tokens.count {
                let first = tokens[start], last = tokens[start + length - 1]
                let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                let span = source.substring(with: range)
                guard span.trimmingCharacters(in: .whitespaces) == span, !span.contains("\n"),
                      span.unicodeScalars.contains(where: isThai),
                      !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                let spanKey = ThaiSound.key(span)
                guard spanKey.count >= minimumKey else { continue }
                var best: Match?
                for term in terms where span != term.spelling && !span.contains(term.spelling) {
                    for heard in term.heard {
                        let heardKey = ThaiSound.key(heard)
                        guard heardKey.count >= minimumKey, heardKey.first == spanKey.first,
                              abs(heardKey.count - spanKey.count) * 10 <= max(heardKey.count, spanKey.count) * 4 else { continue }
                        let score = ThaiSound.similarity(spanKey, heardKey)
                        let floor = spanKey.count <= shortKey ? shortThreshold : looseThreshold
                        guard score >= floor else { continue }
                        let exact = (score >= 1 && spanKey.count >= minimumExactKey)
                            || (score >= nearThreshold && min(spanKey.count, heardKey.count) >= nearKey)
                        if score > (best?.score ?? 0) {
                            best = Match(range: range, source: span, spelling: term.spelling, score: score, isExact: exact)
                        }
                    }
                }
                if let best { found.append(best) }
            }
        }
        // Prefer the closest sound, then the longer span, without overlaps.
        var chosen = [Match]()
        for match in found.sorted(by: { ($0.score, $0.range.length) > ($1.score, $1.range.length) })
        where chosen.allSatisfy({ NSIntersectionRange($0.range, match.range).length == 0 }) {
            chosen.append(match)
        }
        return chosen.sorted { $0.range.location < $1.range.location }
    }

    private static func isThai(_ scalar: Unicode.Scalar) -> Bool { (0x0E01...0x0E4E).contains(scalar.value) }

    /// Dictionary-based Thai word boundaries from Core Foundation.
    static func wordRanges(_ text: String) -> [NSRange] {
        let string = text as CFString
        let full = CFRange(location: 0, length: CFStringGetLength(string))
        guard let tokenizer = CFStringTokenizerCreate(nil, string, full, kCFStringTokenizerUnitWordBoundary,
                                                      CFLocaleCreate(nil, CFLocaleIdentifier("th" as CFString))) else { return [] }
        var ranges = [NSRange]()
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (text as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            ranges.append(NSRange(location: range.location, length: range.length))
        }
        return ranges
    }
}
