import AppKit
import CryptoKit

/// First-run setup of Local AI on a Mac that does not have it yet: a pinned `uv`,
/// the speech engine packages and the OpenThai model from Hugging Face, all inside
/// ~/Library/Application Support/<app>/LocalAI. Nothing is installed system-wide.
enum LocalAIInstaller {
    static let uvVersion = "0.13.1"
    static let uvURL = URL(string: "https://github.com/astral-sh/uv/releases/download/0.13.1/uv-aarch64-apple-darwin.tar.gz")!
    static let uvSHA256 = "cfe454573412ff7380d15fc7dae5997ab53ffce72fce0a78e91ddbc84001acd2"
    static let modelBytes: Double = 2_560_000_000
    static let neededFreeBytes: Int64 = 7_000_000_000

    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(Brand.name)/LocalAI")
    }
    static var runtime: URL { home.appendingPathComponent("runtime") }
    static var log: URL { home.appendingPathComponent("install.log") }
    static var bundledRuntime: URL? { Bundle.main.url(forResource: "LocalAI", withExtension: nil) }

    enum Stage: Int, CaseIterable {
        case tools, engine, model, verify, done
        var title: String {
            switch self {
            case .tools: return "เตรียมเครื่องมือ"
            case .engine: return "ติดตั้งเครื่องยนต์เสียง"
            case .model: return "ดาวน์โหลดโมเดลเสียงไทย"
            case .verify: return "ตรวจไฟล์และเปิด Local AI"
            case .done: return "พร้อมใช้งาน"
            }
        }
    }

    static var freeBytes: Int64 {
        let values = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// Runs the install steps and reports stage, progress and failures on the main queue.
final class LocalAIInstallJob {
    var onStage: ((LocalAIInstaller.Stage) -> Void)?
    var onProgress: ((Double?) -> Void)?
    var onFinish: ((String?) -> Void)?
    private var process: Process?
    private var sizeTimer: Timer?
    private var cancelled = false

    func start() {
        cancelled = false
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
                await MainActor.run { self.onFinish?(nil) }
            } catch {
                let message = (error as? InstallError)?.message ?? error.localizedDescription
                await MainActor.run { self.onFinish?(self.cancelled ? "ยกเลิกการติดตั้งแล้ว" : message) }
            }
        }
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    struct InstallError: Error { let message: String }

    private func stage(_ value: LocalAIInstaller.Stage, progress: Double? = nil) async {
        await MainActor.run { self.onStage?(value); self.onProgress?(progress) }
    }

    private func run() async throws {
        let manager = FileManager.default
        guard LocalAIInstaller.freeBytes >= LocalAIInstaller.neededFreeBytes else {
            throw InstallError(message: "พื้นที่ว่างในเครื่องไม่พอ ต้องมีอย่างน้อย 7 GB")
        }
        guard let bundled = LocalAIInstaller.bundledRuntime else { throw InstallError(message: "ไม่พบไฟล์ติดตั้งในแอป") }
        await stage(.tools)
        let home = LocalAIInstaller.home, runtime = LocalAIInstaller.runtime
        try manager.createDirectory(at: runtime, withIntermediateDirectories: true)
        // Refresh the scripts every time; the downloaded engine and model stay.
        for item in try manager.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil) {
            let target = runtime.appendingPathComponent(item.lastPathComponent)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: item, to: target)
        }
        let uv = try await installUV(into: home.appendingPathComponent("bin"))
        guard !cancelled else { throw InstallError(message: "ยกเลิก") }

        await stage(.engine)
        try await runSetup(uv: uv, runtime: runtime, home: home)
        await stage(.verify)
        await LocalAIService.ensureRunning()
        guard LocalAIService.state == .ready else { throw InstallError(message: "ติดตั้งเสร็จแต่เปิด Local AI ไม่สำเร็จ ดูบันทึกการติดตั้ง") }
        _ = try? await shell(uv, ["cache", "clean"], env: environment(uv: uv, home: home), directory: runtime)
        await stage(.done, progress: 1)
    }

    private func installUV(into bin: URL) async throws -> URL {
        let manager = FileManager.default
        let uv = bin.appendingPathComponent("uv")
        if manager.isExecutableFile(atPath: uv.path) { return uv }
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let (file, response) = try await URLSession.shared.download(from: LocalAIInstaller.uvURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError(message: "ดาวน์โหลดเครื่องมือไม่สำเร็จ ตรวจอินเทอร์เน็ตแล้วลองใหม่") }
        let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard digest == LocalAIInstaller.uvSHA256 else { throw InstallError(message: "ไฟล์เครื่องมือที่ดาวน์โหลดไม่ตรงกับที่ตรวจไว้") }
        let unpack = bin.appendingPathComponent("unpack")
        try? manager.removeItem(at: unpack)
        try manager.createDirectory(at: unpack, withIntermediateDirectories: true)
        _ = try await shell(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", file.path, "-C", unpack.path], env: [:], directory: unpack)
        try manager.moveItem(at: unpack.appendingPathComponent("uv-aarch64-apple-darwin/uv"), to: uv)
        try? manager.removeItem(at: unpack)
        return uv
    }

    private func environment(uv: URL, home: URL) -> [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "UV": uv.path,
            "UV_CACHE_DIR": home.appendingPathComponent("cache").path,
            "UV_PYTHON_INSTALL_DIR": home.appendingPathComponent("python").path,
            "HF_HOME": home.appendingPathComponent("hf").path,
            "HF_HUB_DISABLE_TELEMETRY": "1"
        ]
    }

    private func runSetup(uv: URL, runtime: URL, home: URL) async throws {
        let model = runtime.appendingPathComponent("model")
        await MainActor.run {
            self.sizeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                let bytes = Double(Self.folderSize(model))
                guard bytes > 50_000_000 else { return }
                self?.onStage?(.model)
                self?.onProgress?(min(0.99, bytes / LocalAIInstaller.modelBytes))
            }
        }
        defer { DispatchQueue.main.async { self.sizeTimer?.invalidate() } }
        let status = try await shell(URL(fileURLWithPath: "/bin/bash"), [runtime.appendingPathComponent("setup.sh").path],
                                     env: environment(uv: uv, home: home), directory: runtime, logTo: LocalAIInstaller.log)
        guard status == 0 else { throw InstallError(message: "ติดตั้งไม่สำเร็จ ลองใหม่อีกครั้ง หรือส่งไฟล์บันทึกการติดตั้งให้ทีมงาน") }
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    @discardableResult
    private func shell(_ executable: URL, _ arguments: [String], env: [String: String], directory: URL, logTo: URL? = nil) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = executable
            task.arguments = arguments
            if !env.isEmpty { task.environment = env }
            task.currentDirectoryURL = directory
            task.standardInput = FileHandle.nullDevice
            if let logTo {
                FileManager.default.createFile(atPath: logTo.path, contents: nil)
                let handle = try? FileHandle(forWritingTo: logTo)
                task.standardOutput = handle
                task.standardError = handle
            } else {
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
            }
            task.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try task.run(); self.process = task } catch { continuation.resume(throwing: error) }
        }
    }
}

/// The friendly window that explains and runs the first-time Local AI setup.
final class LocalAIInstallWindow: NSObject, NSWindowDelegate {
    private static var current: LocalAIInstallWindow?
    private let window: NSWindow
    private let job = LocalAIInstallJob()
    private let status = StudioText.label("", PinkTheme.rounded(15, .bold))
    private let detail = StudioText.wrapping("", PinkTheme.rounded(12, .medium), PinkTheme.textSecondary, width: 480)
    private let bar = NSProgressIndicator()
    private var stageLabels = [LocalAIInstaller.Stage: NSTextField]()
    private lazy var startButton = PinkButton("เริ่มติดตั้ง Local AI", style: .primary, symbol: "arrow.down.circle") { [weak self] in self?.begin() }
    private lazy var laterButton = PinkButton("ไว้ทีหลัง") { [weak self] in self?.closeOrCancel() }
    var onReady: (() -> Void)?

    static func show(onReady: (() -> Void)? = nil) {
        if let current { current.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let sheet = LocalAIInstallWindow()
        sheet.onReady = onReady
        current = sheet
        NSApp.activate(ignoringOtherApps: true)
        sheet.window.center()
        sheet.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "ติดตั้ง Local AI"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        PinkTheme.style(window)
        build()
        job.onStage = { [weak self] stage in self?.show(stage) }
        job.onProgress = { [weak self] value in self?.progress(value) }
        job.onFinish = { [weak self] error in self?.finished(error) }
    }

    private func build() {
        let backdrop = StudioBackdrop()
        window.contentView = backdrop
        let title = StudioText.label("ติดตั้ง Local AI ครั้งเดียว", PinkTheme.rounded(26, .heavy))
        let intro = StudioText.wrapping("\(Brand.name) ถอดเสียงบน Mac เครื่องนี้ เสียงพูดไม่ออกจากเครื่อง ครั้งแรกต้องดาวน์โหลดโมเดลเสียงไทยและเครื่องยนต์ประมาณ 4 GB ใช้เวลาราว 5–20 นาทีตามความเร็วอินเทอร์เน็ต",
                                        PinkTheme.rounded(13.5, .medium), PinkTheme.textSecondary, width: 480)
        var rows: [NSView] = []
        for stage in LocalAIInstaller.Stage.allCases where stage != .done {
            let label = StudioText.label("○  " + stage.title, PinkTheme.rounded(13, .semibold), PinkTheme.textMuted)
            stageLabels[stage] = label
            rows.append(label)
        }
        let steps = NSStackView(views: rows)
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 6
        bar.style = .bar
        bar.isIndeterminate = true
        bar.isHidden = true
        bar.widthAnchor.constraint(equalToConstant: 480).isActive = true
        let license = StudioText.wrapping("โมเดล OpenThai 2.0 ASR โดย iApp ใช้สัญญาอนุญาต OpenMDW-1.1 ดาวน์โหลดตรงจาก Hugging Face",
                                          PinkTheme.rounded(11, .medium), PinkTheme.textMuted, width: 480)
        detail.stringValue = "ต้องมีพื้นที่ว่างอย่างน้อย 7 GB · ใช้ได้กับ Mac ชิป Apple"
        let buttons = NSStackView(views: [NSView(), laterButton, startButton])
        buttons.spacing = 10
        let stack = NSStackView(views: [StudioText.eyebrow("Local AI"), title, intro, steps, status, bar, detail, license, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: stack.arrangedSubviews[0])
        stack.setCustomSpacing(18, after: intro)
        stack.setCustomSpacing(18, after: steps)
        stack.setCustomSpacing(20, after: license)
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func begin() {
        startButton.isEnabled = false
        startButton.title = "กำลังติดตั้ง…"
        laterButton.title = "ยกเลิก"
        bar.isHidden = false
        bar.startAnimation(nil)
        job.start()
    }

    private func show(_ stage: LocalAIInstaller.Stage) {
        status.stringValue = stage.title
        for (other, label) in stageLabels {
            let done = other.rawValue < stage.rawValue
            let active = other == stage
            label.stringValue = (done ? "●  " : active ? "◉  " : "○  ") + other.title
            label.textColor = done ? PinkTheme.mint : active ? .white : PinkTheme.textMuted
        }
    }

    private func progress(_ value: Double?) {
        guard let value else { bar.isIndeterminate = true; bar.startAnimation(nil); return }
        bar.isIndeterminate = false
        bar.doubleValue = value * 100
        detail.stringValue = String(format: "ดาวน์โหลดโมเดลแล้ว %.0f%%", value * 100)
    }

    private func finished(_ error: String?) {
        bar.stopAnimation(nil)
        if let error {
            status.stringValue = "ยังติดตั้งไม่เสร็จ"
            status.textColor = PinkTheme.coral
            detail.stringValue = error + "\nบันทึกอยู่ที่ " + LocalAIInstaller.log.path
            startButton.isEnabled = true
            startButton.title = "ลองอีกครั้ง"
            laterButton.title = "ปิด"
            return
        }
        show(.done)
        status.textColor = PinkTheme.mint
        detail.stringValue = "พร้อมแล้ว กดปุ่มลัดค้างแล้วพูดได้เลย"
        bar.isHidden = true
        startButton.isEnabled = true
        startButton.title = TutorialWindow.isAvailable ? "ดูวิธีใช้ แล้วเริ่มเลย" : "เริ่มใช้งาน"
        startButton.handler = { [weak self] in
            self?.window.close()
            TutorialWindow.show()
        }
        laterButton.isHidden = true
        onReady?()
    }

    private func closeOrCancel() {
        if !startButton.isEnabled { job.cancel() } else { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        job.cancel()
        if LocalAIInstallWindow.current === self { LocalAIInstallWindow.current = nil }
    }

    /// Visual QA without installing anything.
    static func render(to url: URL) throws {
        let sheet = LocalAIInstallWindow()
        sheet.show(.engine)
        sheet.bar.isHidden = false
        sheet.status.stringValue = LocalAIInstaller.Stage.engine.title
        guard let content = sheet.window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
