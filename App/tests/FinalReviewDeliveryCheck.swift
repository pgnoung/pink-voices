import Foundation

@main struct FinalReviewDeliveryCheck {
    @MainActor static func main() async {
        let gate = FinalReviewDelivery()
        var received: [TranscriptFinalizerResult] = []
        var continuation: CheckedContinuation<TranscriptFinalizerResult, Never>?
        let slow: () async -> TranscriptFinalizerResult = {
            await withCheckedContinuation { continuation = $0 }
        }
        gate.start(timeout: 0.045, work: slow) { received.append($0) }
        try? await Task.sleep(nanoseconds: 90_000_000)
        precondition(received == [.fallback(.timeout)] && !gate.isWaiting)
        continuation?.resume(returning: .success("too late"))
        await Task.yield()
        precondition(received == [.fallback(.timeout)])
        gate.start(work: slow) { received.append($0) }
        await Task.yield()
        gate.cancel()
        gate.start(work: { .success("new dictation") }) { received.append($0) }
        continuation?.resume(returning: .success("cancelled dictation"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(received == [.fallback(.timeout), .success("new dictation")] && !gate.isWaiting)
        print("Delivery verified: timeout fallback once, late reply discarded, cancellation and replacement isolated")
    }
}
