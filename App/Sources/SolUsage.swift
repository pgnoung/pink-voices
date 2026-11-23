import Foundation

/// A local, privacy-preserving receipt for one Responses API attempt. It never
/// stores prompts, output text, authorization headers, or API keys.
public struct SolUsageCall: Codable, Equatable {
    public var timestamp: Date
    public var attemptID: String
    public var responseID: String?
    public var model: String?
    public var serviceTier: String?
    public var status: String
    public var httpStatus: Int?
    public var transportErrorCode: String?
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var cacheWriteTokens: Int?
    public var cacheWrite30mTokens: Int?
    public var cacheWrite12hTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var totalTokens: Int?
    public var estimate: SolUsageEstimate?
}

public typealias SolUsageRecord = SolUsageCall

public struct SolUsageEstimate: Codable, Equatable {
    public let usd: Decimal
    public let thb: Decimal
    public let exchangeRateTHBPerUSD: Decimal
    public let inputUSDPerMillion: Decimal?
    public let cachedInputUSDPerMillion: Decimal?
    public let cacheWrite30mUSDPerMillion: Decimal?
    public let cacheWrite12hUSDPerMillion: Decimal?
    public let outputUSDPerMillion: Decimal?
    public let pricingSource: String
    public let isComplete: Bool
}

public struct SolUsageAggregate: Equatable {
    public let totalUSD: Decimal
    public let totalTHB: Decimal
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let recordCount: Int
    public let unpricedCount: Int
    public let missingTokenCount: Int
}

public struct SolUsageSnapshot: Equatable {
    public let calls: [SolUsageCall]
    public let latest: SolUsageCall?
    public let lastEstimate: SolUsageEstimate?
    public let totalEstimatedTHB: Decimal
    public let unpricedCount: Int
    public let missingTokenCount: Int
    public let lastError: String?
    public let aggregate: SolUsageAggregate
    public var entries: [SolUsageCall] { calls }
}

public extension Notification.Name {
    static let solUsageLedgerDidChange = Notification.Name("SolUsageLedgerDidChange")
    static let solUsageLedgerPersistenceFailed = Notification.Name("SolUsageLedgerPersistenceFailed")
}

public final class SolUsageLedger {
    public static let shared = SolUsageLedger()

    private static let exchangeRate = Decimal(string: "34.01")!
    private let queue = DispatchQueue(label: "PinkVoices.sol-usage-ledger")
    private let fileURL: URL
    private var calls: [SolUsageCall] = []
    private var persistenceError: String?
    private var loadFailed = false

    public init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL }
        else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ThaiDictation", isDirectory: true)
            self.fileURL = base.appendingPathComponent("sol-usage-ledger.json")
        }
        load()
    }

    /// Call before a live request, then call again with its response or error.
    /// The same attempt is enriched in place, so retry bookkeeping never doubles a cost.
    @discardableResult
    public func record(attemptID: String, responseID: String? = nil, data: Data? = nil,
                       httpStatus: Int? = nil, transportErrorCode: String? = nil,
                       serviceTier: String? = "default") throws -> SolUsageCall {
        do {
            let result = try queue.sync { () throws -> SolUsageCall in
                guard !loadFailed else { throw LedgerError.unreadableExistingLedger }
                let decoded = decode(data)
                let resolvedResponseID = responseID ?? decoded.responseID
                let incoming = makeCall(attemptID: attemptID, responseID: resolvedResponseID, decoded: decoded,
                                        httpStatus: httpStatus, transportErrorCode: transportErrorCode,
                                        serviceTier: decoded.serviceTier ?? serviceTier)
                let index: Int?
                if let resolvedResponseID, let responseIndex = calls.firstIndex(where: { $0.responseID == resolvedResponseID }) {
                    if let pendingIndex = calls.firstIndex(where: { $0.attemptID == attemptID && $0.responseID == nil }), pendingIndex != responseIndex {
                        calls.remove(at: pendingIndex)
                        index = pendingIndex < responseIndex ? responseIndex - 1 : responseIndex
                    } else { index = responseIndex }
                } else { index = matchingIndex(attemptID: attemptID, responseID: resolvedResponseID) }
                if let index { calls[index] = merge(old: calls[index], incoming: incoming) }
                else { calls.append(incoming) }
                calls.sort { $0.timestamp > $1.timestamp }
                do {
                    try persist()
                    persistenceError = nil
                } catch {
                    persistenceError = error.localizedDescription
                    throw error
                }
                return calls.first { $0.responseID == resolvedResponseID && $0.attemptID == attemptID }
                    ?? calls.first { $0.responseID == resolvedResponseID } ?? incoming
            }
            post(.solUsageLedgerDidChange)
            return result
        } catch {
            post(.solUsageLedgerPersistenceFailed)
            throw error
        }
    }

    public func snapshot() -> SolUsageSnapshot {
        queue.sync {
            let missing = calls.reduce(0) { $0 + missingTokens(in: $1) }
            let priced = calls.compactMap(\.estimate)
            let aggregate = SolUsageAggregate(
                totalUSD: priced.reduce(Decimal.zero) { $0 + $1.usd },
                totalTHB: priced.reduce(Decimal.zero) { $0 + $1.thb },
                inputTokens: calls.compactMap(\.inputTokens).reduce(0, +),
                cachedInputTokens: calls.compactMap(\.cachedInputTokens).reduce(0, +),
                cacheWriteTokens: calls.reduce(0) { total, call in
                    total + (call.cacheWriteTokens ?? (call.cacheWrite30mTokens ?? 0) + (call.cacheWrite12hTokens ?? 0))
                },
                outputTokens: calls.compactMap(\.outputTokens).reduce(0, +),
                reasoningTokens: calls.compactMap(\.reasoningTokens).reduce(0, +),
                recordCount: calls.count,
                unpricedCount: calls.filter { $0.estimate == nil }.count,
                missingTokenCount: missing)
            return SolUsageSnapshot(calls: calls, latest: calls.first, lastEstimate: calls.first?.estimate,
                                    totalEstimatedTHB: aggregate.totalTHB, unpricedCount: aggregate.unpricedCount,
                                    missingTokenCount: missing, lastError: persistenceError, aggregate: aggregate)
        }
    }

    private func matchingIndex(attemptID: String, responseID: String?) -> Int? {
        if let responseID, let exact = calls.firstIndex(where: { $0.responseID == responseID }) { return exact }
        return calls.firstIndex(where: { $0.attemptID == attemptID && $0.responseID == nil })
    }

    private func makeCall(attemptID: String, responseID: String?, decoded: DecodedUsage,
                          httpStatus: Int?, transportErrorCode: String?, serviceTier: String?) -> SolUsageCall {
        let status: String
        if transportErrorCode != nil { status = "transport_error" }
        else if let httpStatus, !(200...299).contains(httpStatus) { status = "http_error" }
        else if decoded.received { status = "response_received" }
        else { status = "pending" }
        let call = SolUsageCall(timestamp: Date(), attemptID: attemptID, responseID: responseID,
                                model: decoded.model ?? "gpt-6.2-sol", serviceTier: serviceTier, status: status,
                                httpStatus: httpStatus, transportErrorCode: transportErrorCode,
                                inputTokens: decoded.input, cachedInputTokens: decoded.cached,
                                cacheWriteTokens: decoded.cacheWrite, cacheWrite30mTokens: decoded.cacheWrite30m,
                                cacheWrite12hTokens: decoded.cacheWrite12h, outputTokens: decoded.output,
                                reasoningTokens: decoded.reasoning, totalTokens: decoded.total, estimate: nil)
        var priced = call
        priced.estimate = estimate(for: call)
        return priced
    }

    private func merge(old: SolUsageCall, incoming: SolUsageCall) -> SolUsageCall {
        var merged = old
        merged.timestamp = incoming.timestamp
        if let value = incoming.responseID { merged.responseID = value }
        if let value = incoming.model { merged.model = value }
        if let value = incoming.serviceTier { merged.serviceTier = value }
        if let value = incoming.httpStatus { merged.httpStatus = value }
        if let value = incoming.transportErrorCode { merged.transportErrorCode = value }
        merged.status = incoming.status == "pending" ? old.status : incoming.status
        if let value = incoming.inputTokens { merged.inputTokens = value }
        if let value = incoming.cachedInputTokens { merged.cachedInputTokens = value }
        if let value = incoming.cacheWriteTokens { merged.cacheWriteTokens = value }
        if let value = incoming.cacheWrite30mTokens { merged.cacheWrite30mTokens = value }
        if let value = incoming.cacheWrite12hTokens { merged.cacheWrite12hTokens = value }
        if let value = incoming.outputTokens { merged.outputTokens = value }
        if let value = incoming.reasoningTokens { merged.reasoningTokens = value }
        if let value = incoming.totalTokens { merged.totalTokens = value }
        merged.estimate = estimate(for: merged)
        return merged
    }

    private func estimate(for call: SolUsageCall) -> SolUsageEstimate? {
        guard isSolModel(call.model), standardTier(call.serviceTier),
              let input = call.inputTokens, let output = call.outputTokens, input >= 0, output >= 0 else { return nil }
        let cached = call.cachedInputTokens ?? 0
        let writes30m = call.cacheWrite30mTokens ?? call.cacheWriteTokens ?? 0
        let writes12h = call.cacheWrite12hTokens ?? 0
        let detailedWrites = writes30m + writes12h
        guard cached >= 0, writes30m >= 0, writes12h >= 0, cached + detailedWrites <= input,
              call.cacheWriteTokens.map({ $0 == detailedWrites || (call.cacheWrite30mTokens == nil && call.cacheWrite12hTokens == nil) }) ?? true,
              call.totalTokens.map({ $0 == input + output }) ?? true else { return nil }
        let ordinary = input - cached - writes30m - writes12h
        let usd = (Decimal(ordinary) * 2 + Decimal(cached) * Decimal(string: "0.10")! +
                   Decimal(writes30m) * Decimal(string: "2.50")! + Decimal(writes12h) * 5 + Decimal(output) * 10) / 1_000_000
        let complete = call.cachedInputTokens != nil && (call.cacheWriteTokens != nil || call.cacheWrite30mTokens != nil || call.cacheWrite12hTokens != nil)
        return SolUsageEstimate(usd: usd, thb: usd * Self.exchangeRate, exchangeRateTHBPerUSD: Self.exchangeRate,
                                inputUSDPerMillion: 2, cachedInputUSDPerMillion: Decimal(string: "0.10")!,
                                cacheWrite30mUSDPerMillion: Decimal(string: "2.50")!, cacheWrite12hUSDPerMillion: 5,
                                outputUSDPerMillion: 10,
                                pricingSource: "GPT-6.2 Sol Standard, 2026-11-20 FX 34.01 THB/USD", isComplete: complete)
    }

    private func standardTier(_ tier: String?) -> Bool {
        guard let tier = tier?.lowercased() else { return true }
        return tier == "default" || tier == "standard"
    }

    private func isSolModel(_ model: String?) -> Bool {
        guard let model else { return false }
        return model == "gpt-6.2-sol" || model.range(of: #"^gpt-6\.2-sol-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private func missingTokens(in call: SolUsageCall) -> Int {
        (call.inputTokens == nil || call.outputTokens == nil) ? 1 : 0
    }

    private func load() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            guard let data = try? Data(contentsOf: fileURL) else {
                loadFailed = true; persistenceError = "Could not read saved Sol usage receipts."; return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do { calls = try decoder.decode([SolUsageCall].self, from: data) }
            catch { loadFailed = true; persistenceError = "Could not read saved Sol usage receipts." }
        }
    }

    private func persist() throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(calls).write(to: fileURL, options: .atomic)
    }

    private func post(_ name: Notification.Name) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: name, object: self) }
    }

    private struct DecodedUsage {
        var received = false; var responseID: String?; var model: String?; var serviceTier: String?
        var input: Int?; var cached: Int?; var cacheWrite: Int?; var cacheWrite30m: Int?; var cacheWrite12h: Int?
        var output: Int?; var reasoning: Int?; var total: Int?
    }

    private enum LedgerError: LocalizedError { case unreadableExistingLedger
        var errorDescription: String? { "Saved Sol usage receipts could not be read; they were left unchanged." }
    }

    private func decode(_ data: Data?) -> DecodedUsage {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return DecodedUsage() }
        var result = DecodedUsage(); result.received = true
        result.responseID = root["id"] as? String; result.model = root["model"] as? String; result.serviceTier = root["service_tier"] as? String
        guard let usage = root["usage"] as? [String: Any] else { return result }
        func integer(_ value: Any?) -> Int? {
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            let integer = value.int64Value
            guard integer >= 0, integer <= 1_000_000_000, Double(integer) == value.doubleValue else { return nil }
            return Int(integer)
        }
        result.input = integer(usage["input_tokens"]); result.output = integer(usage["output_tokens"]); result.total = integer(usage["total_tokens"])
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        result.cached = integer(inputDetails?["cached_tokens"])
        result.cacheWrite = integer(inputDetails?["cache_write_tokens"])
        let writeDetails = inputDetails?["cache_write_tokens_details"] as? [String: Any]
        result.cacheWrite30m = integer(writeDetails?["ttl_30m_tokens"]); result.cacheWrite12h = integer(writeDetails?["ttl_12h_tokens"])
        let outputDetails = usage["output_tokens_details"] as? [String: Any]
        result.reasoning = integer(outputDetails?["reasoning_tokens"])
        return result
    }
}
