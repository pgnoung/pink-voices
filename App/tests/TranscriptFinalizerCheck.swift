import Foundation

@main
struct TranscriptFinalizerCheck {
    static func main() async {
        let input = TranscriptFinalizerInput(text: "ส่ง Pink Cutz ให้ LINE OA เวลา 10:30", candidates: [.init(source: "Pink Cutz", replacement: "Pink Cuts")])
        var requests = 0
        let ok = TranscriptFinalizerTransport { request in
            requests += 1
            expect(request.url == TranscriptFinalizer.endpoint, "fixed endpoint")
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "key header")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            expect((body["store"] as? Bool) == false, "store false")
            expect((body["model"] as? String) == "gpt-6.2-sol", "one caller-selected model")
            expect(body["service_tier"] as? String == "default", "Sol uses the standard pricing tier")
            let data = Data(#"{"output_text":"{\"indices\":[0],\"edits\":[]}"}"#.utf8)
            return (data, HTTPURLResponse(url: TranscriptFinalizer.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(input, model: "gpt-6.2-sol", apiKey: "test-key", transport: ok) == .success("ส่ง Pink Cuts ให้ LINE OA เวลา 10:30"), "applies exact selected correction")
        expect(requests == 1, "one request only")
        let generic = TranscriptFinalizerTransport { _ in
            let data = Data(#"{"output_text":"{\"indices\":[],\"edits\":[{\"source\":\"teh\",\"replacement\":\"the\"}]}"}"#.utf8)
            return (data, HTTPURLResponse(url: TranscriptFinalizer.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(.init(text: "ส่ง teh วันนี้", candidates: []), model: "gpt-6.1-terra", apiKey: "test-key", transport: generic) == .success("ส่ง the วันนี้"), "one valid request supports bounded local edit without hint")

        let brandInput = TranscriptFinalizerInput(text: "ส่งพิ้งคับและโมโทวันนี้", candidates: [], contextualBrands: [
            .init(source: "พิ้งคับ", replacement: "Pink Cuts"), .init(source: "โมโท", replacement: "molto")
        ], writingNote: "  คงคำลงท้าย  ")
        let brandTransport = TranscriptFinalizerTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let payload = try JSONSerialization.jsonObject(with: Data((body["input"] as! String).utf8)) as! [String: Any]
            expect(Set(payload.keys) == ["transcript", "candidates", "writing_note"], "only utterance, matched terms and writing note")
            expect(payload["writing_note"] as? String == "คงคำลงท้าย", "bounded preference")
            expect((body["instructions"] as? String)?.contains(DictationGuidance.standard) == true, "visible guide matches the API")
            let terms = payload["candidates"] as! [[String: Any]]
            expect(terms.count == 2 && terms.allSatisfy { $0["kind"] as? String == "context_supported_brand" }, "context identified")
            let data = Data(#"{"output_text":"{\"indices\":[1,0],\"edits\":[{\"source\":\"วันนี้\",\"replacement\":\"พรุ่งนี้\"}]}"}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(brandInput, model: "gpt-6.2-sol", apiKey: "test-key", transport: brandTransport) ==
               .success("ส่ง Pink Cuts และ molto วันนี้"), "apply both brands with Thai spacing, retain protected time")

        var rejectedRequests = 0
        let never = TranscriptFinalizerTransport { _ in
            rejectedRequests += 1
            let data = Data(#"{"output_text":"{\"indices\":[],\"edits\":[]}"}"#.utf8)
            return (data, HTTPURLResponse(url: TranscriptFinalizer.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(.init(text: "   ", candidates: input.candidates), model: "gpt-6.2-sol", apiKey: "test-key", transport: never) == .fallback(.invalidInput), "blank has no request")
        expect(await TranscriptFinalizer.finalize(.init(text: "Pink Cutz Pink Cutz", candidates: input.candidates), model: "gpt-6.2-sol", apiKey: "test-key", transport: never) == .success("Pink Cutz Pink Cutz"), "ambiguous hint omitted, text reviewed")
        let urlCandidate = TranscriptFinalizerCandidate(source: "morto", replacement: "molto")
        expect(await TranscriptFinalizer.finalize(.init(text: "https://example.com/morto", candidates: [urlCandidate]), model: "gpt-6.2-sol", apiKey: "test-key", transport: never) == .success("https://example.com/morto"), "protected URL unchanged")
        expect(await TranscriptFinalizer.finalize(.init(text: "ไม่มีคำตรง", candidates: input.candidates), model: "gpt-6.2-sol", apiKey: "test-key", transport: never) == .success("ไม่มีคำตรง"), "absent hint omitted")
        expect(rejectedRequests == 3, "one request per valid utterance")

        let invalid = TranscriptFinalizerTransport { _ in
            let data = Data(#"{"output_text":"{\"indices\":[99],\"edits\":[]}"}"#.utf8)
            return (data, HTTPURLResponse(url: TranscriptFinalizer.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(input, model: "gpt-6.1-terra", apiKey: "test-key", transport: invalid) == .fallback(.invalidResponse), "invalid index rejected")
        let timeout = TranscriptFinalizerTransport { _ in throw URLError(.timedOut) }
        expect(await TranscriptFinalizer.finalize(input, model: "gpt-6.1-terra", apiKey: "test-key", transport: timeout) == .fallback(.timeout), "timeout falls back")
        print("TranscriptFinalizer checks passed")
    }
    static func expect(_ value: Bool, _ message: String) { if !value { fputs("FAIL: " + message + "\n", stderr); exit(1) } }
}
