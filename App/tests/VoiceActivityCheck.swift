import Foundation

@main struct VoiceActivityCheck {
    static func main() {
        var silent = VoiceActivity()
        for level in [0, 0.02, 0.05, 0.01, 0.08, 0.0] as [CGFloat] { silent.record(level: level) }
        silent.record(text: "  \n")
        precondition(!silent.heardVoice, "room noise and blank partials are not speech")

        var click = VoiceActivity()
        for level in [0.0, 0.9, 0.0, 0.7, 0.02, 0.6, 0.0] as [CGFloat] { click.record(level: level) }
        precondition(!click.heardVoice, "isolated loud samples are not speech")

        var speech = VoiceActivity()
        for level in [0.02, 0.3, 0.42, 0.25, 0.05] as [CGFloat] { speech.record(level: level) }
        precondition(speech.heardVoice, "a sustained loud run counts as speech")

        var quietSpeech = VoiceActivity()
        quietSpeech.record(level: 0.05)
        quietSpeech.record(text: "สวัสดี")
        precondition(quietSpeech.heardVoice, "recognized text counts as speech even when the meter is quiet")

        precondition(VoiceActivity.silenceCutoff == 3)
        print("VoiceActivity: silence, clicks, sustained speech and recognized text classified; cutoff 3 s")
    }
}
