import AVFoundation
import Foundation

/// Reads short, friendly instructions aloud for children who can't read yet.
@MainActor
final class Narrator: NSObject, AVSpeechSynthesizerDelegate {
    var isEnabled = true
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice(language: "en-US")
    private var lastSpoken = Date.distantPast
    private var finished: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

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

    /// Speaks `text` and returns when it has finished (or was cut off). Returns at once when narration is off.
    func sayAndWait(_ text: String) async {
        guard isEnabled else { return }
        await withCheckedContinuation { continuation in
            finished.append(continuation)
            say(text)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor in self.resumeWaiters() } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { Task { @MainActor in self.resumeWaiters() } }

    private func resumeWaiters() {
        let waiting = finished
        finished = []
        waiting.forEach { $0.resume() }
    }
}
