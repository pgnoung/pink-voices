import Foundation

/// Contains aggregate spelling evidence. Only matched source/spelling pairs leave this layer.
struct BrandContext: Decodable {
    private struct Evidence: Decodable {
        let companyTerminology: Bool?
        let plaudExactDocuments: Int?
        let pinkCuts: String?
        let personalDictionary: Bool?
        let qaExpectedSpelling: Bool?
        /// Public glossary: a widely used product name, not tied to anyone's private data.
        let commonTerm: Bool?
    }
    private struct Rule: Decodable {
        let requiresContext: Bool?
        let coMentions: [String]?
        let actionWords: [String]?
    }
    private struct Term: Decodable {
        let canonical: String
        let aliases: [String]
        let observedAsrVariants: [String]?
        let evidence: Evidence
        let match: Rule?
    }
    private let schema: String
    private let version: Int
    private let terms: [Term]

    static let bundled = load(from: Bundle.main.url(forResource: "brand-context", withExtension: "json"))

    static func load(from url: URL?) -> Self? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let url, let data = try? Data(contentsOf: url), let book = try? decoder.decode(Self.self, from: data),
              book.schema == "pinkvoices.brand-context", book.version == 1, !book.terms.isEmpty,
              book.terms.allSatisfy({ !$0.canonical.isEmpty && $0.canonical.utf16.count <= 80 }),
              Set(book.terms.map { $0.canonical.lowercased() }).count == book.terms.count else { return nil }
        return book
    }

    func exactSpellings(in text: String) -> [String] {
        terms.map(\.canonical).filter { text.range(of: $0, options: .literal) != nil }
    }

    private struct Hit {
        let term: Term
        let source: String
        let range: NSRange
        let isObserved: Bool
    }

    func candidates(in text: String, taught: [BrandDictionary.Row]) -> [TranscriptFinalizerCandidate] {
        let raw = text as NSString
        guard raw.length > 0, raw.length <= 8000 else { return [] }
        let protected = Self.protected.matches(in: text, range: NSRange(location: 0, length: raw.length)).map(\.range)
        var hits = [Hit]()
        for term in terms where isEligible(term, taught: taught) {
            var seen = Set<NSRange>()
            for alias in term.aliases + [term.canonical] + (term.observedAsrVariants ?? []) where !alias.isEmpty {
                let escaped = alias.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ \\t]+")
                let pattern = latinEdge(alias.first) + escaped + latinEdge(alias.last, right: true)
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: raw.length))
                guard matches.count == 1, let range = matches.first?.range,
                      protected.allSatisfy({ NSIntersectionRange($0, range).length == 0 }),
                      seen.insert(range).inserted else { continue }
                let source = raw.substring(with: range)
                let observed = term.observedAsrVariants?.contains(alias) == true
                if observed && !ordinaryBrandSlot(range, in: raw) { continue }
                hits.append(Hit(term: term, source: source, range: range, isObserved: observed))
            }
        }

        var output = [TranscriptFinalizerCandidate]()
        for hit in hits where hit.source != hit.term.canonical {
            if taught.contains(where: { $0.alias.caseInsensitiveCompare(hit.source) == .orderedSame && $0.spelling != hit.term.canonical }) { continue }
            if hit.isObserved && !hasContext(hit, hits: hits, in: raw) { continue }
            let pair = TranscriptFinalizerCandidate(source: hit.source, replacement: hit.term.canonical)
            if !output.contains(pair) { output.append(pair) }
        }
        return Array(output.prefix(12))
    }

    private func isEligible(_ term: Term, taught: [BrandDictionary.Row]) -> Bool {
        let evidence = term.evidence
        if evidence.personalDictionary == true {
            let owners = taught.filter { row in term.aliases.contains { $0.caseInsensitiveCompare(row.alias) == .orderedSame } }
            return !owners.isEmpty && owners.allSatisfy { $0.spelling == term.canonical }
                && (evidence.pinkCuts != nil || evidence.qaExpectedSpelling == true)
        }
        if evidence.commonTerm == true { return true }
        return evidence.companyTerminology == true && (evidence.plaudExactDocuments ?? 0) >= 2
    }

    // Candidate spans in addresses, tags, paths and mixed identifiers cannot corroborate another hit.
    private static let protected = try! NSRegularExpression(pattern:
        #"(?:[a-z][a-z0-9+.\-]*://|www\.)\S+|[\w.%+\-]+@[\w.\-]+\.[a-z]{2,}|[a-z0-9_.\-]+(?:[./][a-z0-9_./\-]+)+|[@#][\p{L}\p{M}\p{N}_]+|[A-Za-z0-9]+_[\p{L}\p{M}\p{N}_]+"#, options: .caseInsensitive)

    private func latinEdge(_ c: Character?, right: Bool = false) -> String {
        guard let c, c.isASCII && (c.isLetter || c.isNumber) else { return "" }
        return right ? "(?![A-Za-z0-9_])" : "(?<![A-Za-z0-9_])"
    }

    private func ordinaryBrandSlot(_ range: NSRange, in raw: NSString) -> Bool {
        let left = raw.substring(to: range.location).suffix(28).trimmingCharacters(in: .whitespaces)
        let right = raw.substring(from: NSMaxRange(range))
        if ["สี", "โทนสี", "รถ", "รถรุ่น", "ยี่ห้อรถ", "@", "#", "/", "_"].contains(where: left.hasSuffix) { return false }
        if ["โรล", "ไซ", "รไซ", "รเวย์", "ราด"].contains(where: right.hasPrefix) { return false }
        guard let next = right.unicodeScalars.first, (0x0E01...0x0E4E).contains(next.value) else {
            return !(right.first.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } ?? false)
        }
        return ["ครับ","ค่ะ","คะ","นะ","และ","กับ","หรือ","ให้","ใน","ที่","ของ","ด้วย","แล้ว","วันนี้","พรุ่งนี้","ผ่าน","เข้","ไป","มา"].contains(where: right.hasPrefix)
    }

    private func hasContext(_ hit: Hit, hits: [Hit], in raw: NSString) -> Bool {
        guard let rule = hit.term.match, rule.requiresContext == true else { return false }
        let left = raw.substring(to: hit.range.location).suffix(32).trimmingCharacters(in: .whitespaces)
        if (rule.actionWords ?? []).contains(where: left.hasSuffix) { return true }
        let partners = rule.coMentions ?? []
        return hits.contains { other in
            guard partners.contains(other.term.canonical),
                  NSIntersectionRange(hit.range, other.range).length == 0 else { return false }
            let start = min(NSMaxRange(hit.range), NSMaxRange(other.range))
            let end = max(hit.range.location, other.range.location)
            guard end >= start, end - start <= 16 else { return false }
            let between = raw.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
            return ["และ", "กับ", "หรือ", "&", "+", ",", "และก็"].contains(between)
        }
    }
}
