import AVFoundation
import Foundation

/// Reads short, friendly instructions aloud for children who can't read yet.
@MainActor
final class Narrator {
    var isEnabled = true
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice(language: "en-US")
    private var lastSpoken = Date.distantPast

    func say(_ text: String, interrupt: Bool = true, minimumGap: TimeInterval = 0) {
        guard isEnabled else { return }
        if Date().timeIntervalSince(lastSpoken) < minimumGap { return }
        lastSpoken = Date()
        if interrupt, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = 0.44
        utterance.pitchMultiplier = 1.25
        utterance.volume = 0.9
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}
