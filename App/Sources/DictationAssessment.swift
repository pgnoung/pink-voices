import Foundation

struct ReviewSpan: Decodable, Equatable {
    let text: String
    let category: String
    let reason: String
    let candidates: [String]?

    // Only spans isolated by the local lexical matcher are eligible for online review.
    var mayRequestSpelling: Bool {
        category == "brand" && reason == "mixed_term_near_known_brand"
    }

    var explanation: String {
        switch reason {
        case "mixed_term_near_known_brand": return "สะกดใกล้เคียงชื่อที่มีในคลัง"
        case "unknown_latin_token_in_thai_context": return "คำอังกฤษในประโยคไทยที่ยังไม่พบในคลัง"
        case "calendar_or_time_shape_needs_confirmation": return "รูปแบบวันหรือเวลาผิดปกติ"
        case "partial_final_material_disagreement": return "ผลระหว่างพูดต่างจากผลสุดท้าย"
        case "thai_name_after_explicit_brand_cue": return "ชื่อไทยตามคำบอกชื่อแบรนด์ ควรยืนยันอีกครั้ง"
        case "line_textile_homonym": return "คำพ้องเสียงกับ LINE หรือคำผ้า ควรยืนยันตามบริบท"
        case "tone_mark_variant_of_taught_brand": return "วรรณยุกต์ใกล้คำที่สอนไว้ ควรเลือกคำที่ถูกก่อนใช้"
        default: return "ควรตรวจคำนี้อีกครั้ง"
        }
    }

    var categoryTitle: String {
        switch category {
        case "brand": return "ชื่อแบรนด์"
        case "mixed_thai_english": return "ไทยปนอังกฤษ"
        case "date_time": return "วันเวลา"
        default: return "คำพูด"
        }
    }
}

struct DictationAssessment: Decodable {
    let version: Int
    let decision: String
    let heuristic_score: Int
    let uncertain_spans: [ReviewSpan]
    let confidence_kind: String?

    // A legacy endpoint can dictate even when it provides no word-quality report.
    // Agreement with its own streaming hypothesis is the only available signal here.
    static func basic(raw: String, partial: String?) -> Self {
        let final = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prior = partial?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agrees = !prior.isEmpty && prior == final
        return Self(version: 1, decision: agrees ? "pass" : "review",
                    heuristic_score: agrees ? 70 : 40, uncertain_spans: [],
                    confidence_kind: "limited_stream_agreement")
    }

    static func read(_ raw: Any?) -> Self? {
        guard let object = raw as? [String: Any], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let entry = try? JSONDecoder().decode(Self.self, from: data),
              entry.version == 1, ["pass","review"].contains(entry.decision),
              (0...100).contains(entry.heuristic_score) else { return nil }
        return entry
    }
}

struct DictationSummary {
    let score: Int?
    let spans: [ReviewSpan]
    let incomplete: Bool
    let needsReview: Bool

    init(_ reports: [DictationAssessment?], taught: [BrandDictionary.Row], heard: String = "") {
        let valid = reports.compactMap { $0 }
        incomplete = reports.isEmpty || reports.count != valid.count || valid.contains { $0.confidence_kind == "limited_stream_agreement" }
        let aliases = Set(taught.map { $0.alias.lowercased() })
        var seen = Set<String>()
        var flagged = [ReviewSpan]()
        var hasLocalToneVariant = false
        var unresolved = false
        for report in valid where report.decision == "review" {
            if report.uncertain_spans.isEmpty { unresolved = true }
            for span in report.uncertain_spans where !span.text.isEmpty {
                guard !aliases.contains(span.text.lowercased()) else { continue }
                if seen.insert(span.category + "\n" + span.text).inserted { flagged.append(span) }
            }
        }
        for span in TaughtBrandToneReview.spans(in: heard, taught: taught) {
            guard seen.insert(span.category + "\n" + span.text).inserted else { continue }
            flagged.append(span)
            hasLocalToneVariant = true
        }
        spans = flagged
        needsReview = unresolved || !flagged.isEmpty
        let reportedScore = valid.map(\.heuristic_score).min()
        score = hasLocalToneVariant ? min(reportedScore ?? 60, 60) : reportedScore
    }

    var title: String {
        guard let score else { return "ยังไม่มีคะแนนจาก Local AI" }
        let result = needsReview ? "ควรตรวจ" : (incomplete ? "ตรวจได้บางช่วง" : "ผ่านในเครื่อง")
        return "\(result) · \(score)/100"
    }
}

/// Local-only check for a tone-mark variation of a taught Thai pronunciation.
/// It never changes the dictated text and leaves conflicting spellings for the
/// person using Pink voices to resolve.
private enum TaughtBrandToneReview {
    private static let toneMarks = CharacterSet(charactersIn: "\u{0E48}\u{0E49}\u{0E4A}\u{0E4B}")
    private static let thaiConsonants = CharacterSet(charactersIn: "\u{0E01}"..."\u{0E2E}")
    private static let latin = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    private static let protectedPattern = #"(?:[a-z][a-z0-9+.\-]*://|www\.)\S+|[\w.%+\-]+@[\w.\-]+\.[a-z]{2,}|[a-z0-9_.\-]+(?:[./][a-z0-9_./\-]+)+|[@#][\p{L}\p{M}\p{N}_]+"#

    static func spans(in heard: String, taught: [BrandDictionary.Row]) -> [ReviewSpan] {
        guard !heard.isEmpty else { return [] }
        let protectedRanges = ranges(of: protectedPattern, in: heard)
        let groups = Dictionary(grouping: taught.filter(isEligibleBrand), by: { withoutToneMarks($0.alias) })
        var result = [ReviewSpan]()
        for (normalizedAlias, rows) in groups where isMultiSyllableThaiAlias(normalizedAlias) {
            let pattern = rows.first.map { toneFlexiblePattern(for: withoutToneMarks($0.alias)) } ?? ""
            guard !pattern.isEmpty else { continue }
            for range in ranges(of: pattern, in: heard) where !protectedRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                let observed = (heard as NSString).substring(with: range)
                guard observed != rows[0].alias, withoutToneMarks(observed) == normalizedAlias else { continue }
                let candidates = Array(Set(rows.map(\.spelling))).sorted()
                result.append(ReviewSpan(
                    text: observed,
                    category: "brand",
                    reason: "tone_mark_variant_of_taught_brand",
                    candidates: candidates
                ))
            }
        }
        return result
    }

    private static func isEligibleBrand(_ row: BrandDictionary.Row) -> Bool {
        guard isMultiSyllableThaiAlias(withoutToneMarks(row.alias)), !row.spelling.isEmpty else { return false }
        return row.spelling.unicodeScalars.allSatisfy { latin.contains($0) || $0.properties.isWhitespace }
            && row.spelling.unicodeScalars.contains(where: latin.contains)
    }

    private static func isMultiSyllableThaiAlias(_ alias: String) -> Bool {
        alias.unicodeScalars.filter(thaiConsonants.contains).count >= 3
    }

    private static func withoutToneMarks(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !toneMarks.contains($0) }))
    }

    private static func toneFlexiblePattern(for normalized: String) -> String {
        normalized.unicodeScalars.map {
            NSRegularExpression.escapedPattern(for: String($0)) + "[\u{0E48}-\u{0E4B}]*"
        }.joined()
    }

    private static func ranges(of pattern: String, in text: String) -> [NSRange] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
}
