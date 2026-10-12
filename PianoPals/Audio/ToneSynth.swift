import AVFoundation
import Foundation

/// A tiny piano-ish synthesizer so on-screen keys make a sound without needing a sample bank.
/// Notes are rendered once (additive synthesis with a natural decay) and cached.
final class ToneSynth {
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var cache: [Int: AVAudioPCMBuffer] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private(set) var isAvailable = false

    private static let voiceCount = 12

    func start() {
        guard !isAvailable else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        for _ in 0..<ToneSynth.voiceCount {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        engine.mainMixerNode.outputVolume = 0.9
        do {
            try engine.start()
            isAvailable = true
        } catch {
            isAvailable = false
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            try? self.engine.start()
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.engine.start()
        })
    }

    func play(note: Int, velocity: Int = 90) {
        guard isAvailable, (21...108).contains(note) else { return }
        if !engine.isRunning { try? engine.start() }
        let buffer = cache[note] ?? render(note: note)
        cache[note] = buffer
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = Float(min(max(velocity, 20), 127)) / 127 * 0.9
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// A short, sparkly rising arpeggio for celebrations (never used for mistakes).
    func playChime() {
        guard isAvailable else { return }
        for (index, note) in [84, 88, 91, 96].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.11) { [weak self] in
                self?.play(note: note, velocity: 70)
            }
        }
    }

    private func render(note: Int) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let seconds = 2.2
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]

        let frequency = 440 * pow(2, Double(note - 69) / 12)
        let partials: [(ratio: Double, amplitude: Double)] = [(1, 1), (2, 0.5), (3, 0.28), (4, 0.18), (5, 0.1), (6, 0.06)]
        let baseDecay = min(max(2.4 - Double(note - 40) * 0.03, 0.5), 2.4)
        var peak = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            var value = 0.0
            for (index, partial) in partials.enumerated() {
                let decay = baseDecay / (1 + Double(index) * 0.55)
                value += partial.amplitude * exp(-t / decay) * sin(2 * .pi * frequency * partial.ratio * t)
            }
            let attack = min(t / 0.004, 1)
            let release = min((seconds - t) / 0.08, 1)
            value *= attack * release
            samples[i] = Float(value)
            peak = max(peak, abs(value))
        }
        let gain = peak > 0 ? Float(0.6 / peak) : 1
        for i in 0..<Int(frames) { samples[i] *= gain }
        return buffer
    }
}
