import AVFoundation
import Foundation

protocol LiveASRDelegate: AnyObject {
    func asrReady(_ source: AudioStreamer)
    func asrPartial(_ text: String, source: AudioStreamer)
    func asrFinal(_ text: String, assessment: DictationAssessment?, source: AudioStreamer)
    func asrDone(_ source: AudioStreamer)
    func asrError(_ message: String, source: AudioStreamer)
    /// Normalized microphone energy for the local visual indicator only.
    func asrAudioLevel(_ level: CGFloat, source: AudioStreamer)
}

/// Aggregate capture state for local diagnostics. It never contains audio or transcript text.
struct AudioCaptureMetric {
    enum Event: String { case started, stopped, endSent, done }
    let event: Event
    let samples: Int
    let rms: Double
    let peak: Double
}

final class AudioStreamer: NSObject {
    weak var delegate: LiveASRDelegate?
    private let sessionID: UUID?
    private let engine = AVAudioEngine(); private var converter: AVAudioConverter?; private var task: URLSessionWebSocketTask?
    private let callbackQueue = DispatchQueue(label: "ThaiDictation.audio")
    private let admission = NSLock()
    private var acceptingAudio = false
    private var admissionClosed = false
    private var scoreProtocol = 0
    private var latestPartial: (utterance: Int, text: String)?
    private var pcm = Data(); private var ended = false; private var endRequested = false; private var endSent = false; private var serverReady = false; private var tapInstalled = false
    private var sending = false
    private var finalCount = 0
    private var lastMeterUpdate = Date.distantPast
    private var expectedLanguage: LanguageMode = .thaiMix
    private let latencyMs = 560
    private var captureStarted = false
    private var capturedSamples = 0
    private var capturedSquareSum = 0.0
    private var capturedPeak = 0.0

    init(sessionID: UUID? = nil) {
        self.sessionID = sessionID
        super.init()
    }

    func begin(endpoint: String, language: LanguageMode) throws {
        guard let url = URL(string: endpoint), url.host == "127.0.0.1" || url.host == "localhost" else { throw NSError(domain: "ThaiDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local loopback WebSocket URL required"]) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startWhenAdmitted(url: url, language: language)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                guard allowed else { if let self { self.delegate?.asrError("Microphone permission was not granted.", source: self) }; return }
                self?.startWhenAdmitted(url: url, language: language)
            }
        default:
            delegate?.asrError("Microphone permission was not granted.", source: self)
        }
    }
    private func startWhenAdmitted(url: URL, language: LanguageMode) {
        callbackQueue.async { [weak self] in
            guard let self, !self.ended, !self.endRequested, self.captureMayStart() else { return }
            self.startAfterPermission(url: url, language: language)
        }
    }
    private func captureMayStart() -> Bool {
        admission.withLock { !admissionClosed }
    }
    private func startAfterPermission(url: URL, language: LanguageMode) {
        expectedLanguage = language
        task = URLSession(configuration: .default).webSocketTask(with: url); task?.resume(); receive()
        let hello = "{\"mode\":\"standard\",\"lang\":\"\(language.rawValue)\",\"latency_ms\":\(latencyMs)}"
        send(.string(hello))
        let input = engine.inputNode; let source = input.inputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let c = AVAudioConverter(from: source, to: target) else { fail("Cannot create 16 kHz mono converter."); return }
        converter = c
        admission.withLock { acceptingAudio = !admissionClosed }
        guard captureMayStart() else { return }
        input.installTap(onBus: 0, bufferSize: 1_600, format: source) { [weak self] buffer, _ in self?.admit(buffer, target: target) }; tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
            captureStarted = true
            reportMetric(.started)
        } catch {
            fail(error.localizedDescription)
        }
    }
    /// AVAudioEngine owns a tap buffer only for the duration of its callback.
    /// Copy its bytes before returning so queued conversion cannot observe reused mic memory.
    private func admit(_ input: AVAudioPCMBuffer, target: AVAudioFormat) {
        admission.lock()
        guard acceptingAudio, !admissionClosed else { admission.unlock(); return }
        guard let owned = ownedBuffer(from: input) else { admission.unlock(); return }
        callbackQueue.async { [weak self] in
            self?.convert(owned, target: target)
        }
        // Queue this owned snapshot before releasing admission. finish() uses the
        // same lock to place its drain barrier after every accepted buffer.
        admission.unlock()
    }
    private func ownedBuffer(from input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
        copy.frameLength = input.frameLength
        let originals = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let copies = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard originals.count == copies.count else { return nil }
        for index in originals.indices {
            guard let source = originals[index].mData, let destination = copies[index].mData else { return nil }
            let byteCount = Int(originals[index].mDataByteSize)
            guard byteCount <= Int(copies[index].mDataByteSize) else { return nil }
            destination.copyMemory(from: source, byteCount: byteCount)
            copies[index].mDataByteSize = originals[index].mDataByteSize
        }
        return copy
    }
    private func convert(_ input: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard !ended else { return }
        let samples = ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples) + 16) else { return }
        var err: NSError?; var supplied = false
        converter?.convert(to: out, error: &err) { _, status in if supplied { status.pointee = .noDataNow; return nil }; supplied = true; status.pointee = .haveData; return input }
        if let err { fail(err.localizedDescription); return }
        let bytes = Int(out.frameLength) * 2
        if bytes > 0, let pointer = out.int16ChannelData?.pointee {
            recordCapture(pointer, count: Int(out.frameLength))
            publishMeter(pointer, count: Int(out.frameLength))
            pcm.append(Data(bytes: pointer, count: bytes))
            guard pcm.count <= 64_000 else { fail("Local ASR audio queue filled."); return }
            drain()
        }
    }
    private func recordCapture(_ samples: UnsafePointer<Int16>, count: Int) {
        capturedSamples += count
        for index in 0..<count {
            let value = Double(samples[index]) / Double(Int16.max)
            capturedSquareSum += value * value
            capturedPeak = max(capturedPeak, abs(value))
        }
    }
    private func reportMetric(_ event: AudioCaptureMetric.Event) {
        let rms = capturedSamples == 0 ? 0 : sqrt(capturedSquareSum / Double(capturedSamples))
        let metric = AudioCaptureMetric(event: event, samples: capturedSamples, rms: rms, peak: capturedPeak)
        if let sessionID {
            let detail = String(format: "samples=%d rms=%.4f peak=%.4f", metric.samples, metric.rms, metric.peak)
            Telemetry.shared.record(sessionID, "audio_\(event.rawValue)", detail)
        }
    }
    private func publishMeter(_ samples: UnsafePointer<Int16>, count: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastMeterUpdate) >= 0.045, count > 0 else { return }
        lastMeterUpdate = now
        var sum: Double = 0
        for index in 0..<count {
            let value = Double(samples[index]) / Double(Int16.max)
            sum += value * value
        }
        // Root mean square is stable enough for a speaking meter.  The curve
        // enlarges quiet Thai speech without representing it as a transcript.
        let rms = sqrt(sum / Double(count))
        let normalized = min(1, max(0, (rms - 0.008) * 7.5))
        delegate?.asrAudioLevel(CGFloat(normalized), source: self)
    }
    func finish() {
        admission.lock()
        defer { admission.unlock() }
        admissionClosed = true
        acceptingAudio = false
        // Audio already admitted is queued in front of this drain barrier.
        callbackQueue.async { [weak self] in
            guard let self, !self.ended, !self.endRequested else { return }
            self.endRequested = true
            // Every admitted tap snapshot is already ahead of this barrier. Start
            // draining it before stopping Core Audio, whose teardown can briefly
            // block this serial queue under system load.
            guard self.task != nil else {
                self.close()
                self.delegate?.asrDone(self)
                return
            }
            self.drain()
            self.stopCapture()
        }
    }
    func cancel() { callbackQueue.async { [self] in close() } }
    private func stopCapture() {
        admission.withLock { acceptingAudio = false; admissionClosed = true }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if engine.isRunning { engine.stop() }
        if captureStarted {
            captureStarted = false
            reportMetric(.stopped)
        }
    }
    private func close() {
        ended = true
        stopCapture()
        pcm.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
    private func fail(_ message: String) {
        close()
        delegate?.asrError(message, source: self)
    }
    private func receive() {
        task?.receive { [weak self] result in
            self?.callbackQueue.async { [weak self] in
                guard let self, !self.ended else { return }
                switch result {
                case .failure(let error): self.fail(error.localizedDescription)
                case .success(let message):
                    self.handle(message)
                    if !self.ended { self.receive() }
                }
            }
        }
    }
    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let string) = message,
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any],
              let kind = object["type"] as? String else { fail("Invalid local ASR message."); return }
        if kind == "error" { fail("Local ASR failed (\(object["code"] as? Int ?? 0))."); return }
        if !serverReady {
            guard kind == "ready", object["lang"] as? String == expectedLanguage.rawValue,
                  object["latency_ms"] as? Int == latencyMs else { fail("Local ASR was not ready for this configuration."); return }
            scoreProtocol = object["pink_voices_score_protocol"] as? Int ?? 0
            serverReady = true
            delegate?.asrReady(self)
            drain()
            return
        }
        switch kind {
        case "partial":
            if let text = object["text"] as? String {
                latestPartial = (object["utterance"] as? Int ?? -1, text)
                delegate?.asrPartial(text, source: self)
            }
        case "final":
            guard let text = object["display_text"] as? String else { fail("Local ASR final text is missing."); return }
            finalCount += 1
            let partial = latestPartial.flatMap { $0.utterance == (object["utterance"] as? Int) ? $0.text : nil }
            let report = scoreProtocol == 1 ? DictationAssessment.read(object["pink_voices_score"]) : nil
            let assessment = report ?? .basic(raw: object["text"] as? String ?? text, partial: partial)
            latestPartial = nil
            delegate?.asrFinal(text, assessment: assessment, source: self)
        case "done":
            guard endSent, object["utterances"] as? Int == finalCount else {
                fail("Local ASR reported an incomplete session."); return
            }
            close()
            reportMetric(.done)
            delegate?.asrDone(self)
        default:
            break
        }
    }
    private func send(_ message: URLSessionWebSocketTask.Message) {
        sending = true
        task?.send(message) { [weak self] error in
            self?.callbackQueue.async { [weak self] in
                guard let self, !self.ended else { return }
                self.sending = false
                if let error { self.fail(error.localizedDescription); return }
                self.drain()
            }
        }
    }
    private func drain() {
        guard serverReady, !ended, !sending, !endSent else { return }
        if pcm.count >= 3_200 || (endRequested && !pcm.isEmpty) {
            let length = min(pcm.count, 3_200)
            let chunk = Data(pcm.prefix(length))
            pcm.removeFirst(length)
            send(.data(chunk))
        } else if endRequested {
            endSent = true
            reportMetric(.endSent)
            send(.string("end"))
        }
    }
}
