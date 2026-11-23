import Foundation

@main struct SolUsageTransportCheck {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.json")
        let ledger = SolUsageLedger(fileURL: path)
        let utterance = TranscriptFinalizerInput(text: "fixture", candidates: [])
        let model = "gpt-6.2-sol"
        var sends = 0
        let transport = TranscriptFinalizerTransport { request in
            sends += 1
            let data = Data(#"{"id":"resp_test","model":"gpt-6.2-sol","status":"incomplete","usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":10,"cache_write_tokens":0},"output_tokens":50,"output_tokens_details":{"reasoning_tokens":20},"total_tokens":150}}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let traced = transport.recordingSolUsage(model: model, session: UUID(), ledger: ledger)
        let fallback = await TranscriptFinalizer.finalize(utterance, model: model, apiKey: "test", transport: traced)
        precondition(fallback == .fallback(.invalidResponse))
        let snapshot = ledger.snapshot()
        precondition(snapshot.calls.count == 1 && snapshot.latest?.totalTokens == 150)
        precondition(snapshot.totalEstimatedTHB == Decimal(string: "0.02316081"))
        _ = await TranscriptFinalizer.finalize(utterance, model: model, apiKey: "", transport: traced)
        precondition(sends == 1 && ledger.snapshot().calls.count == 1, "Local rejection incurs no request")
        let otherModel = "gpt-6.1-terra"
        _ = await TranscriptFinalizer.finalize(utterance, model: otherModel, apiKey: "test",
            transport: transport.recordingSolUsage(model: otherModel, session: UUID(), ledger: ledger))
        precondition(sends == 2 && ledger.snapshot().calls.count == 1, "Other models are excluded from Sol totals")
        let timeout = TranscriptFinalizerTransport { _ in throw URLError(.timedOut) }
        _ = await TranscriptFinalizer.finalize(utterance, model: model, apiKey: "test",
            transport: timeout.recordingSolUsage(model: model, session: UUID(), ledger: ledger))
        precondition(ledger.snapshot().calls.count == 2 && ledger.snapshot().unpricedCount == 1)
        let another = Data(#"{"id":"resp_second","model":"gpt-6.2-sol","usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0,"cache_write_tokens":0},"output_tokens":0,"total_tokens":10}}"#.utf8)
        try ledger.record(attemptID: UUID().uuidString, data: another, httpStatus: 200)
        let reopened = SolUsageLedger(fileURL: path).snapshot()
        precondition(reopened.calls.count == 3 && reopened.unpricedCount == 1)
        precondition(reopened.totalEstimatedTHB == Decimal(string: "0.02384101"), "Sum unrounded call costs and preserve the total after restart")
        let broken = SolUsageLedger(fileURL: directory.appendingPathComponent("ledger.json/nested"))
        let storageFailure = await TranscriptFinalizer.finalize(utterance, model: model, apiKey: "test",
            transport: transport.recordingSolUsage(model: model, session: UUID(), ledger: broken))
        precondition(storageFailure == .fallback(.usageStorageUnavailable) && sends == 2)
        print("Sol transport verified for a billed incomplete result, excluded models, missing key, timeout and storage failure")
    }
}
