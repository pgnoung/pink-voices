import AppKit

/// A short-lived, click-through indicator. It never becomes key, so the destination editor retains focus.
final class PinkVoiceHUD {
    enum State: Equatable, CaseIterable {
        case recording, finishing, waiting, checking, localFallback, inserted, checkField, savedForCopy, cancelled, failed, noSpeech, timedOut, learned

        var message: String {
            switch self {
            case .recording: return "กำลังฟัง"
            case .finishing: return "กำลังเรียบเรียง"
            case .waiting: return "กำลังถอดเสียงต่อ"
            case .checking: return "AI กำลังตรวจคำ"
            case .localFallback: return "ใส่ผลจาก Local AI แล้ว"
            case .inserted: return "ใส่ข้อความแล้ว"
            case .checkField: return "ตรวจช่องพิมพ์อีกครั้ง"
            case .savedForCopy: return "คัดลอกข้อความได้"
            case .cancelled: return "ยกเลิกแล้ว"
            case .failed: return "ถอดเสียงไม่สำเร็จ"
            case .noSpeech: return "ไม่พบคำพูด"
            case .timedOut: return "ถอดเสียงไม่ทัน"
            case .learned: return "จำคำนี้แล้ว"
            }
        }

        var symbol: String {
            switch self {
            case .recording: return "mic.fill"
            case .finishing: return "sparkles"
            case .waiting: return "hourglass"
            case .checking: return "text.magnifyingglass"
            case .localFallback: return "checkmark.circle"
            case .inserted: return "checkmark"
            case .checkField: return "text.cursor"
            case .savedForCopy: return "doc.on.doc"
            case .cancelled: return "xmark"
            case .failed: return "exclamationmark"
            case .noSpeech: return "mic.slash"
            case .timedOut: return "clock"
            case .learned: return "checkmark.seal.fill"
            }
        }
    }

    private let panel: NSPanel
    private let view = PinkVoiceHUDView(frame: NSRect(origin: .zero, size: PinkVoiceHUDView.canvasSize))
    private var activeSession: UUID?
    private var hideWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: PinkVoiceHUDView.canvasSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = view
    }

    func show(_ state: State, session: UUID, level: CGFloat = 0) {
        activeSession = session
        hideWorkItem?.cancel()
        let entering = !panel.isVisible || panel.alphaValue < 1
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if entering { view.beginAppearance() }
        view.present(state, level: level)
        panel.alphaValue = 1
        positionPanel()
        panel.orderFrontRegardless()
    }

    func setLevel(_ level: CGFloat, session: UUID) {
        guard activeSession == session, panel.isVisible, view.state == .recording else { return }
        view.push(level: level)
    }

    func transition(to state: State, session: UUID) {
        guard activeSession == session else { return }
        view.present(state, level: 0)
    }

    func showDemoMeter(session: UUID) {
        guard activeSession == session, view.state == .recording else { return }
        for (index, sample) in Self.demoSamples.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.06) { [weak self] in
                self?.setLevel(sample, session: session)
            }
        }
    }

    func finish(_ state: State, session: UUID, hideAfter: TimeInterval = 1.25) {
        guard activeSession == session else { return }
        view.present(state, level: 0)
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.activeSession == session else { return }
            self.activeSession = nil
            // A short fade for normal dismissals; quick cancellations leave at once.
            guard hideAfter >= 0.5, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { self.dismissNow(); return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.activeSession == nil else { return }
                self.dismissNow()
            })
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: work)
    }

    private func dismissNow() {
        view.stopAnimation()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    func cancel(session: UUID) { finish(.cancelled, session: session, hideAfter: 0.7) }

    private func positionPanel() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 30 - PinkVoiceHUDView.pillBottom))
    }

    /// A non-interactive rendering route for visual QA. It initializes neither microphone capture nor a keyboard event tap.
    static func renderPreviews(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in State.allCases {
            let preview = PinkVoiceHUDView(frame: NSRect(origin: .zero, size: PinkVoiceHUDView.canvasSize))
            preview.reduceMotion = false
            preview.beginAppearance()
            preview.present(state, level: 0)
            if state == .recording {
                for sample in demoSamples + demoSamples.reversed() + demoSamples { preview.push(level: sample); preview.step(1.0 / 60.0) }
                preview.settle(for: 0.2)
            } else {
                preview.settle(for: state == .inserted || state == .localFallback ? 0.28 : 0.6)
            }
            preview.stopAnimation()
            guard let data = preview.snapshot()?.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: directory.appendingPathComponent("pink-voices-\(state.fileName).png"))
        }
    }

    /// Renders the Studio demo loop as numbered PNG frames for a review movie.
    static func renderMovieFrames(to directory: URL, fps: Int = 30) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preview = PinkVoiceHUDView(frame: NSRect(origin: .zero, size: PinkVoiceHUDView.canvasSize))
        preview.reduceMotion = false
        preview.showcase = true
        preview.stopAnimation()
        let frames = Int(PinkVoiceHUDView.DemoScript.duration * Double(fps) * 2)
        for frame in 0..<frames {
            preview.step(1.0 / Double(fps))
            preview.stopAnimation()
            guard let output = preview.snapshot() else { continue }
            guard let data = output.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: directory.appendingPathComponent(String(format: "frame-%04d.png", frame)))
        }
    }

    private static let demoSamples: [CGFloat] = [0.03, 0.10, 0.40, 0.18, 0.74, 0.28, 0.54, 0.16, 0.88, 0.37, 0.62, 0.12, 0.45, 0.22]
}

private extension PinkVoiceHUD.State {
    var fileName: String {
        switch self {
        case .recording: return "recording"
        case .finishing: return "finishing"
        case .waiting: return "waiting"
        case .checking: return "checking"
        case .localFallback: return "local-fallback"
        case .inserted: return "inserted"
        case .checkField: return "check-field"
        case .savedForCopy: return "copy"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        case .noSpeech: return "no-speech"
        case .timedOut: return "timed-out"
        case .learned: return "learned"
        }
    }
}
