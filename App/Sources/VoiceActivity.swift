import CoreGraphics
import Foundation

/// Tracks whether a hold contained any voice. When nothing was heard, the app stops
/// waiting for the recognizer a few seconds after release instead of the full timeout.
struct VoiceActivity {
    /// Seconds after release before an utterance with no detected voice is dropped.
    static let silenceCutoff: TimeInterval = 3
    /// Meter level (0…1, see AudioStreamer.publishMeter) that counts as speech.
    static let speechLevel: CGFloat = 0.18
    /// Consecutive loud meter updates (~45 ms each) needed, so one click or bump is not speech.
    static let requiredLoudSamples = 3

    private(set) var heardVoice = false
    private var loudRun = 0

    mutating func record(level: CGFloat) {
        guard !heardVoice else { return }
        loudRun = level >= Self.speechLevel ? loudRun + 1 : 0
        if loudRun >= Self.requiredLoudSamples { heardVoice = true }
    }

    mutating func record(text: String) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { heardVoice = true }
    }
}
