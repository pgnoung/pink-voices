import Foundation
import ServiceManagement

/// Starts the on-Mac speech service (Local AI) when the app opens, so Pink voices works
/// like a normal Mac app without a separate launcher script. The service keeps running
/// after the app quits, which keeps the next start fast.
enum LocalAIService {
    enum State: Equatable { case unknown, ready, starting, missingRuntime, failed }

    static let healthURL = URL(string: "http://127.0.0.1:18081/v1/health")!
    static let expectedModel = "openthai2.0-asr-streaming-v1.0"
    private(set) static var state: State = .unknown { didSet { if state != oldValue { NotificationCenter.default.post(name: didChange, object: nil) } } }
    static let didChange = Notification.Name("PinkVoicesLocalAIStateChanged")
    private static var process: Process?

    /// Where the speech runtime lives. The installer links it here; a source checkout is the fallback.
    static var runtimeCandidates: [URL] {
        return [LocalAIInstaller.runtime]
    }

    static var runtime: URL? {
        runtimeCandidates.first { root in
            let manager = FileManager.default
            return manager.isExecutableFile(atPath: root.appendingPathComponent(".venv/bin/python").path)
                && manager.fileExists(atPath: root.appendingPathComponent("start.sh").path)
                && manager.fileExists(atPath: root.appendingPathComponent("model/openthai2.0-asr-streaming_raw.nemo").path)
        }
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ThaiDictation/asr.log")
    }

    static func isReady() async -> Bool {
        var request = URLRequest(url: healthURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["model"] as? String == expectedModel && json["loaded"] as? Bool == true
    }

    /// Checks the service and starts it once if needed, then waits up to two minutes for warm-up.
    @MainActor static func ensureRunning() async {
        if await isReady() { state = .ready; return }
        guard state != .starting else { return }
        guard let root = runtime else { state = .missingRuntime; return }
        state = .starting
        if process?.isRunning != true {
            do { process = try launch(root) } catch { state = .failed; return }
        }
        for _ in 0..<120 {
            if await isReady() { state = .ready; return }
            if process?.isRunning == false, !(await isReady()) { state = .failed; return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        state = await isReady() ? .ready : .failed
    }

    private static func launch(_ root: URL) throws -> Process {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        log.seekToEndOfFile()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [root.appendingPathComponent("start.sh").path]
        task.currentDirectoryURL = root
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = log
        task.standardError = log
        try task.run()
        return task
    }
}

/// "Open at login" through the system's Login Items list. The person switches it on.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}
