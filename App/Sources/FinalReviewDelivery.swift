import Foundation

/// One review owns delivery until its first terminal event. A timed-out or
/// cancelled response can never insert a second copy, even if it arrives late.
final class FinalReviewDelivery {
    private var ticket: UUID?
    private var request: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    var isWaiting: Bool { ticket != nil }

    func start(timeout: TimeInterval = TranscriptFinalizer.timeout,
               work: @escaping () async -> TranscriptFinalizerResult,
               deliver: @escaping (TranscriptFinalizerResult) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        let id = UUID()
        ticket = id
        func finish(_ value: TranscriptFinalizerResult) {
            guard ticket == id else { return }
            cancel()
            deliver(value)
        }
        request = Task { @MainActor in
            guard !Task.isCancelled else { return }
            finish(await work())
        }
        deadline = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            catch { return }
            finish(.fallback(.timeout))
        }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        ticket = nil
        request?.cancel()
        deadline?.cancel()
        request = nil
        deadline = nil
    }
}

extension TranscriptFinalizerFallback {
    var userMessage: String {
        switch self {
        case .missingKey: return "ยังไม่ได้ล็อกอิน ChatGPT หรืออ่านคีย์ไม่ได้ ตรวจที่โหมดถอดและตรวจคำ"
        case .usageStorageUnavailable: return "บันทึกค่าใช้จ่ายบน Mac ไม่สำเร็จ จึงใช้คำถอดในเครื่อง"
        case .unavailable: return "รุ่นที่เลือกยังใช้ไม่ได้"
        case .invalidInput: return "ข้อความหรือการตั้งค่าอยู่นอกขอบเขตที่ตรวจได้"
        case .offline: return "ติดต่อ OpenAI ไม่สำเร็จ"
        case .timeout: return "OpenAI ตอบไม่ทัน"
        case .unauthorized: return "ตรวจสอบคีย์และสิทธิ์เรียกรุ่นนี้"
        case .rateLimited: return "บัญชี API ถึงขีดจำกัด"
        case .http(let code): return "OpenAI ตอบกลับด้วยรหัส \(code)"
        case .invalidResponse: return "ยืนยันคำแก้จาก OpenAI ไม่ได้"
        case .cancelled: return "ยกเลิกการตรวจแล้ว"
        }
    }
}
