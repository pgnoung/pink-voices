import Foundation

@main struct DictationAssessmentCheck {
    static func main() {
        let wire: [String: Any] = [
            "version": 1, "decision": "review", "heuristic_score": 68,
            "uncertain_spans": [["text":"Notionn", "category":"brand", "reason":"near_known_spelling", "candidates":["Notion"]]]
        ]
        let selected = DictationAssessment.read(wire)
        precondition(selected != nil)
        precondition(DictationAssessment.read(["heuristic_score": 100]) == nil)
        let summary = DictationSummary([selected, selected], taught: [])
        precondition(summary.spans.count == 1 && summary.needsReview && summary.score == 68 && !summary.incomplete)
        let corrected = DictationSummary([selected], taught: [.init(alias: "Notionn", spelling: "Notion")])
        precondition(!corrected.needsReview && corrected.spans.isEmpty)
        let interrupted = DictationSummary([nil, selected], taught: [])
        precondition(interrupted.incomplete && interrupted.needsReview)
        let unavailable = DictationSummary([nil], taught: [])
        precondition(unavailable.incomplete && unavailable.score == nil)
        let basic = DictationAssessment.basic(raw: "วันนี้", partial: "วัน")
        let legacy = DictationSummary([basic], taught: [])
        precondition(legacy.score != nil && legacy.incomplete && legacy.needsReview && legacy.spans.isEmpty)
        precondition(DictationAssessment.basic(raw: "วันนี้", partial: "วันนี้").decision == "pass")

        let taught = [BrandDictionary.Row(alias: "มอโต้", spelling: "molto")]
        let toneVariant = DictationSummary([DictationAssessment.basic(raw: "วันนี้เราจะคุยเรื่องม่อโต้ครับ", partial: "วันนี้เราจะคุยเรื่องม่อโต้ครับ")],
                                           taught: taught,
                                           heard: "วันนี้เราจะคุยเรื่องม่อโต้ครับ")
        precondition(toneVariant.needsReview && toneVariant.score == 60)
        precondition(toneVariant.spans.contains { $0.text == "ม่อโต้" && $0.candidates == ["molto"] })

        let exact = DictationSummary([selected], taught: taught, heard: "วันนี้เราจะคุยเรื่องมอโต้ครับ")
        precondition(!exact.spans.contains { $0.reason == "tone_mark_variant_of_taught_brand" })
        let unrelated = DictationSummary([selected], taught: taught, heard: "วันนี้เราคุยเรื่องมอเตอร์ครับ")
        precondition(!unrelated.spans.contains { $0.reason == "tone_mark_variant_of_taught_brand" })
        let protected = DictationSummary([selected], taught: taught, heard: "https://example.com/ม่อโต้ @ม่อโต้")
        precondition(!protected.spans.contains { $0.reason == "tone_mark_variant_of_taught_brand" })
        let short = DictationSummary([selected], taught: [.init(alias: "กา", spelling: "ka")], heard: "ก่าครับ")
        precondition(!short.spans.contains { $0.reason == "tone_mark_variant_of_taught_brand" })
        let conflicting = DictationSummary([selected], taught: [
            .init(alias: "มอโต้", spelling: "molto"),
            .init(alias: "ม่อโต้", spelling: "moltto")
        ], heard: "วันนี้พูดม๊อโต้ครับ")
        let conflictCandidates = conflicting.spans.first(where: { $0.reason == "tone_mark_variant_of_taught_brand" })?.candidates
        precondition(conflictCandidates == ["molto", "moltto"])
        print("DictationAssessmentCheck passed")
    }
}
