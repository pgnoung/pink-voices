import Foundation

struct TimingEvent: Encodable {
    let at: String; let session: String; let event: String; let detail: String?
}

final class Telemetry {
    static let shared = Telemetry()
    private let queue = DispatchQueue(label: "ThaiDictation.telemetry")
    private let url: URL
    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThaiDictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("timings.jsonl")
    }
    func record(_ session: UUID, _ event: String, _ detail: String? = nil) {
        let value = TimingEvent(at: ISO8601DateFormatter().string(from: Date()), session: session.uuidString, event: event, detail: detail)
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            let line = data + Data("\n".utf8)
            if FileManager.default.fileExists(atPath: self.url.path), let h = try? FileHandle(forWritingTo: self.url) {
                defer { try? h.close() }
                do { try h.seekToEnd(); try h.write(contentsOf: line) } catch { }
            } else { try? line.write(to: self.url, options: .atomic) }
        }
    }
}
