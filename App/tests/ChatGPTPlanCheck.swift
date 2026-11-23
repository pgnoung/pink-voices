import Foundation

@main
struct ChatGPTPlanCheck {
    static func main() async {
        // Streamed Responses request on the ChatGPT plan route.
        let input = TranscriptFinalizerInput(text: "ส่ง Pink Cutz ให้ทีม", candidates: [.init(source: "Pink Cutz", replacement: "Pink Cuts")])
        let completed = #"{"id":"resp_1","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"indices\":[0],\"edits\":[]}"}]}]}"#
        let stream = """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"{\\"indices\\""}

        event: response.completed
        data: {"type":"response.completed","response":\(completed)}

        """
        let plan = TranscriptFinalizerTransport { request in
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer plan-token", "plan token header")
            expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream", "asks for a stream")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            expect(body["stream"] as? Bool == true && body["store"] as? Bool == false, "stream true, store false")
            expect(body["service_tier"] == nil && body["tools"] == nil, "no API-only fields on the plan route")
            return (Data(stream.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(input, model: "gpt-6.2-sol", apiKey: "plan-token", chatGPTPlan: true, transport: plan)
               == .success("ส่ง Pink Cuts ให้ทีม"), "applies the correction from response.completed")

        let longToken = String(repeating: "a", count: 2_000)
        let limit = TranscriptFinalizerTransport { request in
            let failed = #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#
            return (Data(failed.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(input, model: "gpt-6.2-sol", apiKey: longToken, chatGPTPlan: true, transport: limit)
               == .fallback(.rateLimited), "plan usage limit falls back to Local AI")
        expect(await TranscriptFinalizer.finalize(input, model: "gpt-6.2-sol", apiKey: longToken, transport: limit)
               == .fallback(.missingKey), "API keys keep their short length bound")
        let cut = TranscriptFinalizerTransport { request in
            (Data(#"data: {"type":"response.output_text.delta","delta":"x"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(input, model: "gpt-6.2-sol", apiKey: "plan-token", chatGPTPlan: true, transport: cut)
               == .fallback(.invalidResponse), "a stream without response.completed is not trusted")

        // Sound-alike names go to the AI as their own kind and are applied when chosen.
        let named = TranscriptFinalizerInput(text: "ขอบคุณพี่ฮงมากครับ", candidates: [], soundAlikes: [.init(source: "พี่ฮง", replacement: "พี่ง้วง")])
        let pick = TranscriptFinalizerTransport { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let payload = try JSONSerialization.jsonObject(with: Data((body["input"] as! String).utf8)) as! [String: Any]
            let kinds = (payload["candidates"] as! [[String: Any]]).compactMap { $0["kind"] as? String }
            expect(kinds == ["sounds_like_taught_name"], "sound-alike kind sent")
            expect((body["instructions"] as? String)?.contains("sounds_like_taught_name") == true, "AI told how to judge it")
            let data = Data(#"{"output_text":"{\"indices\":[0],\"edits\":[]}"}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        expect(await TranscriptFinalizer.finalize(named, model: "gpt-6.2-sol", apiKey: "test-key", transport: pick)
               == .success("ขอบคุณพี่ง้วงมากครับ"), "chosen sound-alike applied")

        // ID token claims.
        func token(_ claims: [String: Any]) -> String {
            let body = try! JSONSerialization.data(withJSONObject: claims)
            return "e30." + ChatGPTAccount.base64URL(body) + ".sig"
        }
        let future = Date().timeIntervalSince1970 + 600
        let good: [String: Any] = ["iss": "https://auth.openai.com", "aud": "app_123", "sub": "user-1", "nonce": "n1", "exp": future, "email": "a@example.com"]
        expect(ChatGPTAccount.verifiedIdentity(token(good), clientId: "app_123", nonce: "n1")?.email == "a@example.com", "valid claims accepted")
        var wrongNonce = good; wrongNonce["nonce"] = "n2"
        expect(ChatGPTAccount.verifiedIdentity(token(wrongNonce), clientId: "app_123", nonce: "n1") == nil, "nonce mismatch rejected")
        var wrongIssuer = good; wrongIssuer["iss"] = "https://example.com"
        expect(ChatGPTAccount.verifiedIdentity(token(wrongIssuer), clientId: "app_123", nonce: "n1") == nil, "foreign issuer rejected")
        var wrongAudience = good; wrongAudience["aud"] = ["app_123", "other"]
        expect(ChatGPTAccount.verifiedIdentity(token(wrongAudience), clientId: "app_123", nonce: "n1") == nil, "multi-audience needs matching azp")
        var expired = good; expired["exp"] = Date().timeIntervalSince1970 - 60
        expect(ChatGPTAccount.verifiedIdentity(token(expired), clientId: "app_123", nonce: "n1") == nil, "expired sign-in token rejected")

        // Loopback callback on 127.0.0.1.
        do {
            let listener = try await LoopbackListener.start(preferredPort: 0, state: "state-ok")
            defer { listener.stop() }
            let base = "http://127.0.0.1:\(listener.port)/auth/callback"
            let session = URLSession(configuration: .ephemeral)
            let (_, bad) = try await session.data(from: URL(string: base + "?state=wrong&code=x")!)
            expect((bad as? HTTPURLResponse)?.statusCode == 400, "wrong state refused")
            let (_, ok) = try await session.data(from: URL(string: base + "?state=state-ok&code=code-1&client_id=app_123")!)
            expect((ok as? HTTPURLResponse)?.statusCode == 200, "matching callback accepted")
            let callback = try await listener.waitForCallback(timeout: 2)
            expect(callback.code == "code-1" && callback.clientId == "app_123" && callback.error == nil, "code and client id delivered")
        } catch {
            expect(false, "loopback listener: \(error)")
        }
        print("ChatGPT plan: streamed request, completed-event parsing, usage limit, claims checks and loopback callback verified")
    }

    static func expect(_ value: Bool, _ message: String) {
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
