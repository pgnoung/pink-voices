import Foundation

enum CloudReviewMode: String {
    case local
    case luna
    case jevLuna
}

struct CloudReviewInput {
    let term: String
    let category: String
    let candidates: [String]
}

struct CloudWordReviewTransport {
    let send: (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let live = CloudWordReviewTransport { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Optional, suggestion-only cloud review for one already isolated uncertain term.
/// Callers own consent, key access, and quotas. This type does not persist inputs,
/// retries, errors, or model output.
enum CloudWordReview {
    static let jevEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let lunaEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let allowedCategories: Set<String> = ["brand", "mixed_thai_english"]

    static func suggest(
        _ input: CloudReviewInput,
        mode: CloudReviewMode,
        lunaKey: String,
        jevKey: String
    ) async -> String? {
        await suggest(input, mode: mode, lunaKey: lunaKey, jevKey: jevKey, transport: .live)
    }

    static func isEligible(_ input: CloudReviewInput) -> Bool {
        isSafe(input)
    }

    static func suggest(
        _ input: CloudReviewInput,
        mode: CloudReviewMode,
        lunaKey: String,
        jevKey: String,
        transport: CloudWordReviewTransport
    ) async -> String? {
        guard mode != .local, isSafe(input), !Task.isCancelled else { return nil }
        switch mode {
        case .local:
            return nil
        case .luna:
            return await askLuna(input, key: lunaKey, transport: transport)
        case .jevLuna:
            guard await jevAllows(input, key: jevKey, transport: transport), !Task.isCancelled else { return nil }
            return await askLuna(input, key: lunaKey, transport: transport)
        }
    }

    private static func isSafe(_ input: CloudReviewInput) -> Bool {
        guard allowedCategories.contains(input.category),
              !input.term.isEmpty,
              input.candidates.count >= 1,
              input.candidates.count <= 3,
              isSafeTerm(input.term),
              input.candidates.allSatisfy(isSafeCandidate) else { return false }
        if input.category == "mixed_thai_english", !input.term.unicodeScalars.contains(where: isLatin) {
            return false
        }
        return Set(input.candidates.map { $0.folding(options: .caseInsensitive, locale: .current) }).count == input.candidates.count
    }

    private static func isSafeTerm(_ value: String) -> Bool {
        guard value.count <= 30, !value.contains(where: { $0.isWhitespace }) else { return false }
        let allowed = CharacterSet.letters.union(.nonBaseCharacters)
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeCandidate(_ value: String) -> Bool {
        if isSafeTerm(value) { return true }
        guard value.count <= 30 else { return false }
        let words = value.split(separator: " ", omittingEmptySubsequences: false)
        guard (2...3).contains(words.count), !words.contains(where: { $0.isEmpty }) else { return false }
        return words.allSatisfy { word in
            word.unicodeScalars.allSatisfy { scalar in
                (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            }
        }
    }

    private static func isLatin(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func jevAllows(
        _ input: CloudReviewInput,
        key: String,
        transport: CloudWordReviewTransport
    ) async -> Bool {
        guard isSafeKey(key) else { return false }
        let body: [String: Any] = [
            "model": "jev-latest",
            "state": [
                "category": input.category,
                "candidate_count": input.candidates.count
            ],
            "questions": [
                "forward": [
                    "type": "choice",
                    "instructions": "Gate this isolated word category. Return forward only when a bounded spelling suggestion is appropriate.",
                    "criteria": ["forward": NSNull(), "local": NSNull()]
                ]
            ]
        ]
        guard let response = await post(body, to: jevEndpoint, bearer: key, transport: transport),
              let answers = response["answers"] as? [String: Any],
              let forward = answers["forward"] as? [String: Any],
              forward["type"] as? String == "choice",
              forward["choice"] as? String == "forward" else { return false }
        return true
    }

    private static func askLuna(
        _ input: CloudReviewInput,
        key: String,
        transport: CloudWordReviewTransport
    ) async -> String? {
        guard isSafeKey(key) else { return nil }
        let choices = input.candidates.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["index"],
            "properties": ["index": ["type": "integer", "minimum": -1, "maximum": input.candidates.count - 1]]
        ]
        let body: [String: Any] = [
            "model": "gpt-6-luna",
            "store": false,
            "instructions": "Choose one candidate spelling for one isolated uncertain word, or index -1 to keep the original. Do not rewrite, add text, infer dates or times, or return explanation.",
            "input": [[
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "Category: \(input.category)\nTerm: \(input.term)\nCandidates:\n\(choices)"
                ]]
            ]],
            "text": ["format": ["type": "json_schema", "name": "word_choice", "schema": schema, "strict": true]],
            "max_output_tokens": 128,
            "reasoning": ["effort": "low"]
        ]
        guard let response = await post(body, to: lunaEndpoint, bearer: key, transport: transport),
              let text = outputText(response),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let index = object["index"] as? Int else { return nil }
        guard index == -1 || input.candidates.indices.contains(index) else { return nil }
        guard index >= 0 else { return nil }
        return input.candidates[index]
    }

    private static func post(
        _ object: [String: Any],
        to url: URL,
        bearer: String,
        transport: CloudWordReviewTransport
    ) async -> [String: Any]? {
        guard !Task.isCancelled, let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false
        guard let result = try? await transport.send(request),
              !Task.isCancelled,
              (200..<300).contains(result.1.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: result.0) as? [String: Any]
    }

    private static func outputText(_ response: [String: Any]) -> String? {
        if let direct = response["output_text"] as? String { return direct }
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        for message in output where message["type"] as? String == "message" {
            guard let content = message["content"] as? [[String: Any]] else { continue }
            if let text = content.first(where: { $0["type"] as? String == "output_text" })?["text"] as? String {
                return text
            }
        }
        return nil
    }

    private static func isSafeKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
}
