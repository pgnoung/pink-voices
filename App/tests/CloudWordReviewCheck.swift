import Foundation

@main struct CloudWordReviewCheck {
    static func main() async {
        let input = CloudReviewInput(term: "มอโต้", category: "brand", candidates: ["molto", "Pink Cuts"])
        var requests: [URLRequest] = []
        let transport = CloudWordReviewTransport { request in
            requests.append(request)
            let url = request.url!
            let body: Any
            if url == CloudWordReview.jevEndpoint {
                body = ["answers": ["forward": ["type": "choice", "choice": "forward"]]]
            } else {
                body = ["output_text": "{\"index\":0}"]
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let local = await CloudWordReview.suggest(input, mode: .local, lunaKey: "luna", jevKey: "jev", transport: transport)
        precondition(local == nil && requests.isEmpty)

        let direct = await CloudWordReview.suggest(input, mode: .luna, lunaKey: "luna", jevKey: "", transport: transport)
        precondition(direct == "molto" && requests.count == 1 && requests[0].url == CloudWordReview.lunaEndpoint)
        let directBody = try! JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
        precondition(directBody["model"] as? String == "gpt-6-luna" && directBody["store"] as? Bool == false)
        let format = ((directBody["text"] as? [String: Any])?["format"] as? [String: Any])?["schema"] as? [String: Any]
        let indexSchema = (format?["properties"] as? [String: Any])?["index"] as? [String: Any]
        precondition(indexSchema?["minimum"] as? Int == -1 && indexSchema?["maximum"] as? Int == 1)

        requests.removeAll()
        let gated = await CloudWordReview.suggest(input, mode: .jevLuna, lunaKey: "luna", jevKey: "jev", transport: transport)
        precondition(gated == "molto" && requests.count == 2)
        let gateText = String(data: requests[0].httpBody!, encoding: .utf8)!
        precondition(!gateText.contains(input.term) && !gateText.contains(input.candidates[0]) && gateText.contains("brand"))

        requests.removeAll()
        let privateTerm = CloudReviewInput(term: "0812345678", category: "brand", candidates: ["molto"])
        let privateResult = await CloudWordReview.suggest(privateTerm, mode: .luna, lunaKey: "luna", jevKey: "", transport: transport)
        precondition(privateResult == nil)
        let phrase = CloudReviewInput(term: "วันนี้ตอนเช้า", category: "mixed_thai_english", candidates: ["Pink Cuts"])
        let phraseResult = await CloudWordReview.suggest(phrase, mode: .luna, lunaKey: "luna", jevKey: "", transport: transport)
        precondition(phraseResult == nil)
        precondition(requests.isEmpty)

        let abstain = CloudWordReviewTransport { request in
            let body = try JSONSerialization.data(withJSONObject: ["output_text": "{\"index\":-1}"])
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let abstained = await CloudWordReview.suggest(input, mode: .luna, lunaKey: "luna", jevKey: "", transport: abstain)
        precondition(abstained == nil)

        var cancelledRequests = 0
        var operation: Task<String?, Never>?
        let cancellationTransport = CloudWordReviewTransport { request in
            cancelledRequests += 1
            if request.url == CloudWordReview.jevEndpoint {
                let data = try JSONSerialization.data(withJSONObject: ["answers": ["forward": ["type": "choice", "choice": "forward"]]])
                operation?.cancel()
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            preconditionFailure("Luna must not run after cancellation")
        }
        operation = Task {
            await CloudWordReview.suggest(input, mode: .jevLuna, lunaKey: "luna", jevKey: "jev", transport: cancellationTransport)
        }
        let cancelled = await operation!.value
        precondition(cancelled == nil && cancelledRequests == 1)

        let timeout = CloudWordReviewTransport { _ in throw URLError(.timedOut) }
        let timeoutResult = await CloudWordReview.suggest(input, mode: .luna, lunaKey: "luna", jevKey: "", transport: timeout)
        precondition(timeoutResult == nil)
        print("CloudWordReviewCheck passed")
    }
}
