import Foundation

@main struct FinalReviewIntegrityCheck {
    static func review(_ text: String, _ edits: [[String: String]] = [], indices: [Int] = [],
                       hints: [TranscriptFinalizerCandidate] = [], locked: [String] = [],
                       status: String = "completed") async -> TranscriptFinalizerResult {
        let transport = TranscriptFinalizerTransport { request in
            let json = try JSONSerialization.data(withJSONObject: ["indices": indices, "edits": edits])
            let payload: [String: Any] = ["status": status, "output": [
                ["type": "reasoning"], ["type": "message", "role": "assistant", "content": [
                    ["type": "output_text", "text": String(decoding: json, as: UTF8.self)]
                ]]
            ]]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let input = TranscriptFinalizerInput(text: text, candidates: hints, protectedSpellings: locked)
        return await TranscriptFinalizer.finalize(input, model: "gpt-6.1-terra", apiKey: "test", transport: transport)
    }

    static func main() async {
        let rejected = TranscriptFinalizerResult.fallback(.invalidResponse)
        let cases: [(String, String, String)] = [
            ("ใช้ molto ครับ", "olto", "olto "), ("เจอกันสามโมง", "สาม", "ส้าม"),
            ("พรุ่งนี้วันจันทร์", "จันทร์", "จันทร"), ("ยังไม่ได้รับ", "ได้", "ได้ "),
            ("ราคา 123 บาท", "123", "124"), ("เปิด https://a.test/a", "ด https", "ด http"),
            ("ส่งบิลแล้ว", "ส่งบิล", "ส่งบิน")
        ]
        for (text, old, new) in cases {
            let value = await review(text, [["source": old, "replacement": new]], locked: ["molto"])
            precondition(value == rejected, old)
        }
        let overlap = await review("abcdef", indices: [0,1], hints: [.init(source:"abc", replacement:"one"), .init(source:"cde", replacement:"two")])
        precondition(overlap == rejected)
        let cascade = await review("foo bar", indices: [0,1], hints: [.init(source:"foo", replacement:"bar"), .init(source:"bar", replacement:"baz")])
        precondition(cascade == .success("bar baz"))
        let incomplete = await review("เดิม", status: "incomplete")
        precondition(incomplete == rejected)
        let refusal = await review("Pink Cutz", indices: [0], hints: [.init(source: "Pink Cutz", replacement: "Pink Cuts")], locked: ["Pink Cutz"])
        precondition(refusal == rejected)
        print("Integrity verified: exact ranges, overlaps, no cascade, Thai dates and negation, names, identifiers, incomplete responses")
    }
}
