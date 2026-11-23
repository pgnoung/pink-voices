import Foundation

extension TranscriptFinalizerTransport {
    func recordingSolUsage(model: String, session: UUID, ledger: SolUsageLedger = .shared) -> Self {
        guard model == "gpt-6.2-sol" else { return self }
        return Self { request in
            try Task.checkCancellation()
            let attemptID = session.uuidString
            // A quit or an interrupted connection can leave a billed request with unknown usage.
            do { _ = try ledger.record(attemptID: attemptID) }
            catch { throw TranscriptFinalizerFallback.usageStorageUnavailable }

            let reply: (Data, HTTPURLResponse)
            do { reply = try await self.send(request) }
            catch {
                let code = (error as? URLError).map { String($0.errorCode) } ?? "transport"
                do { _ = try ledger.record(attemptID: attemptID, transportErrorCode: code) }
                catch { Telemetry.shared.record(session, "sol_usage_save_failed") }
                throw error
            }
            // Capture usage even if edits are rejected, the reply was incomplete,
            // or the user changed focus while the request was in flight.
            do {
                _ = try ledger.record(attemptID: attemptID, data: reply.0, httpStatus: reply.1.statusCode)
            } catch {
                Telemetry.shared.record(session, "sol_usage_save_failed")
            }
            return reply
        }
    }
}
