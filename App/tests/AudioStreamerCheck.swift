import AVFoundation
import Foundation

@main struct AudioStreamerCheck {
    static func main() {
        let delegate = Recorder()
        let streamer = AudioStreamer()
        streamer.delegate = delegate
        streamer.finish()

        precondition(delegate.done.wait(timeout: .now() + 1) == .success, "finish without a session did not complete")
        precondition(delegate.doneCount == 1)
        precondition(delegate.errors.isEmpty)
        print("AudioStreamerCheck passed")
    }
}

private final class Recorder: LiveASRDelegate {
    let done = DispatchSemaphore(value: 0)
    var doneCount = 0
    var errors = [String]()

    func asrReady(_ source: AudioStreamer) {}
    func asrPartial(_ text: String, source: AudioStreamer) {}
    func asrFinal(_ text: String, assessment: DictationAssessment?, source: AudioStreamer) {}
    func asrAudioLevel(_ level: CGFloat, source: AudioStreamer) {}
    func asrDone(_ source: AudioStreamer) { doneCount += 1; done.signal() }
    func asrError(_ message: String, source: AudioStreamer) { errors.append(message) }
}
