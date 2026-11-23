import Foundation

@main struct SolUsageCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sol-usage-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("receipts.json")
        let ledger = SolUsageLedger(fileURL: path)
        try ledger.record(attemptID: "a")
        let payload = """
        {"id":"resp_1","model":"gpt-6.2-sol-2026-11-20","service_tier":"default","usage":{"input_tokens":1000000,"output_tokens":1000000,"total_tokens":2000000,"input_tokens_details":{"cached_tokens":100000,"cache_write_tokens":300000,"cache_write_tokens_details":{"ttl_30m_tokens":200000,"ttl_12h_tokens":100000}},"output_tokens_details":{"reasoning_tokens":20}}}
        """
        try ledger.record(attemptID: "a", data: Data(payload.utf8), httpStatus: 200)
        let one = ledger.snapshot()
        expect(one.calls.count == 1, "upsert prevents double counting")
        guard let estimate = one.calls[0].estimate else { fatalError("missing priced estimate") }
        expect(estimate.usd == Decimal(string: "12.21"), "cached and both cache-write rates price correctly")
        expect(estimate.thb == Decimal(string: "415.2621"), "row snapshots fixed FX")
        expect(one.calls[0].reasoningTokens == 20, "reasoning tokens retained")
        expect(one.missingTokenCount == 0, "missing count is calls, not missing fields")
        let reopened = SolUsageLedger(fileURL: path)
        expect(reopened.snapshot().calls.count == 1, "receipt survives relaunch")
        try reopened.record(attemptID: "different-attempt", data: Data(payload.utf8), httpStatus: 200)
        expect(reopened.snapshot().calls.count == 1, "response ID deduplicates across attempts")

        let reconciled = SolUsageLedger(fileURL: root.appendingPathComponent("reconciled.json"))
        try reconciled.record(attemptID: "pending-attempt")
        try reconciled.record(attemptID: "received-first", data: Data(payload.utf8), httpStatus: 200)
        try reconciled.record(attemptID: "pending-attempt", data: Data(payload.utf8), httpStatus: 200)
        expect(reconciled.snapshot().calls.count == 1, "response ID reconciles an earlier pending placeholder")
        try reconciled.record(attemptID: "timeout", transportErrorCode: String(URLError.timedOut.rawValue))
        guard let timeout = reconciled.snapshot().calls.first(where: { $0.attemptID == "timeout" }) else { fatalError("missing timeout receipt") }
        expect(timeout.model == "gpt-6.2-sol" && timeout.status == "transport_error" && timeout.estimate == nil, "timeout persists an unknown Sol receipt")

        let other = SolUsageLedger(fileURL: root.appendingPathComponent("other.json"))
        let flex = "{\"id\":\"resp_2\",\"model\":\"gpt-6.2-sol\",\"service_tier\":\"flex\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}"
        try other.record(attemptID: "b", data: Data(flex.utf8), httpStatus: 200)
        expect(other.snapshot().unpricedCount == 1, "nonstandard tier is explicitly unpriced")
        let unusable = "{\"id\":\"resp_3\",\"model\":\"gpt-6.2-sol\",\"usage\":{\"input_tokens\":0}}"
        try other.record(attemptID: "c", data: Data(unusable.utf8), httpStatus: 200)
        expect(other.snapshot().calls.count == 2 && other.snapshot().unpricedCount == 2, "valid response receipt remains when output is unusable")

        let corrupt = root.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to: corrupt)
        let unreadable = SolUsageLedger(fileURL: corrupt)
        expect(unreadable.snapshot().lastError != nil, "corrupt receipt reports a storage error")
        do { try unreadable.record(attemptID: "must-not-overwrite") ; fatalError("corrupt ledger was overwritten") }
        catch { expect((try? Data(contentsOf: corrupt)) == Data("not json".utf8), "corrupt receipt remains untouched") }

        let legacy = root.appendingPathComponent("legacy.json")
        let oldReceipt = """
        [{"timestamp":"2026-11-22T10:00:00Z","attemptID":"old","status":"response_received","model":"gpt-6.2-sol","serviceTier":"default","estimate":{"usd":1.25,"thb":42.5125,"exchangeRateTHBPerUSD":34.01,"pricingSource":"old","isComplete":true}}]
        """
        try Data(oldReceipt.utf8).write(to: legacy)
        expect(SolUsageLedger(fileURL: legacy).snapshot().calls.count == 1, "previous receipts without rate fields remain readable")
        print("SolUsageCheck passed")
    }

    static func expect(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
