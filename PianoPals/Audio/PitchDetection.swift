import Accelerate
import Foundation

struct PitchEstimate: Equatable, Sendable {
    /// nil when the frame is silent or has no clear pitch.
    var frequency: Double?
    /// 0…1: how periodic the sound is (1 − YIN's normalised difference).
    var clarity: Double
    var rms: Double
}

/// YIN fundamental-frequency estimator (de Cheveigné & Kawahara, 2002) for monophonic melodies: a hummed or played tune,
/// one note at a time. Deterministic, model-free, and fast enough to run in real time.
struct YINPitchDetector: Sendable {
    let sampleRate: Double
    let frameSize: Int
    var threshold = 0.15
    var minFrequency = 70.0
    var maxFrequency = 1_200.0
    var silenceRMS = 0.008
    var minimumClarity = 0.72

    init(sampleRate: Double = 44_100, frameSize: Int = 2_048) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
    }

    /// Analyses the first `frameSize` samples.
    func estimate(_ samples: [Float]) -> PitchEstimate {
        guard samples.count >= frameSize else { return PitchEstimate(frequency: nil, clarity: 0, rms: 0) }
        let window = frameSize / 2
        let tauMax = min(window - 1, Int(sampleRate / minFrequency))
        let tauMin = max(2, Int(sampleRate / maxFrequency))
        guard tauMax > tauMin + 2 else { return PitchEstimate(frequency: nil, clarity: 0, rms: 0) }

        return samples.withUnsafeBufferPointer { buffer -> PitchEstimate in
            let x = buffer.baseAddress!
            var energy: Float = 0
            vDSP_svesq(x, 1, &energy, vDSP_Length(frameSize))
            let rms = (Double(energy) / Double(frameSize)).squareRoot()
            guard rms >= silenceRMS else { return PitchEstimate(frequency: nil, clarity: 0, rms: rms) }

            // Step 1–2: difference function d(τ) = Σ x[j]² + Σ x[j+τ]² − 2·Σ x[j]·x[j+τ], using SIMD dot products and
            // prefix sums of x², then cumulative-mean normalisation.
            var prefix = [Double](repeating: 0, count: frameSize + 1)
            for i in 0..<frameSize { prefix[i + 1] = prefix[i] + Double(x[i]) * Double(x[i]) }
            let firstTerm = prefix[window]
            var cmnd = [Double](repeating: 1, count: tauMax + 2)
            var runningSum = 0.0
            for tau in 1...tauMax + 1 {
                var correlation: Float = 0
                vDSP_dotpr(x, 1, x + tau, 1, &correlation, vDSP_Length(window))
                let shifted = prefix[tau + window] - prefix[tau]
                let d = max(firstTerm + shifted - 2 * Double(correlation), 0)
                runningSum += d
                cmnd[tau] = runningSum > 0 ? d * Double(tau) / runningSum : 1
            }

            // Step 3: first dip below the threshold (then follow it down to its local minimum).
            var best: Int?
            var tau = tauMin
            while tau <= tauMax {
                if cmnd[tau] < threshold {
                    while tau + 1 <= tauMax, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                    best = tau
                    break
                }
                tau += 1
            }
            // No dip under the threshold: accept the global minimum only if it is still clearly periodic.
            if best == nil {
                let candidate = (tauMin...tauMax).min { cmnd[$0] < cmnd[$1] }
                if let candidate, 1 - cmnd[candidate] >= minimumClarity { best = candidate }
            }
            guard let period = best else { return PitchEstimate(frequency: nil, clarity: 0, rms: rms) }

            // Step 4: parabolic interpolation for sub-sample accuracy.
            var refined = Double(period)
            if period > 1, period < tauMax {
                let a = cmnd[period - 1], b = cmnd[period], c = cmnd[period + 1]
                let denominator = 2 * (2 * b - c - a)
                if abs(denominator) > 1e-12 { refined += (c - a) / denominator }
            }
            let clarity = 1 - cmnd[period]
            guard clarity >= minimumClarity else { return PitchEstimate(frequency: nil, clarity: clarity, rms: rms) }
            return PitchEstimate(frequency: sampleRate / refined, clarity: clarity, rms: rms)
        }
    }

    static func midiNote(forFrequency frequency: Double) -> Double { 69 + 12 * log2(frequency / 440) }
}

/// Groups a stream of pitch estimates into notes, ignoring octave glitches, vibrato and breaths.
struct NoteSegmenter: Sendable {
    var frameDuration: TimeInterval
    /// Frames a new pitch must persist before it becomes a new note.
    var stabilityFrames = 3
    var minNoteDuration: TimeInterval = 0.10
    /// Silence shorter than this doesn't end a note.
    var maxGap: TimeInterval = 0.08

    private struct Open {
        var pitch: Int
        var start: TimeInterval
        var lastSeen: TimeInterval
    }

    private var current: Open?
    private var pending: (pitch: Int, count: Int, first: TimeInterval)?
    private var notes: [RawNote] = []
    /// The note being heard right now (for the live display).
    private(set) var liveNote: Int?

    init(frameDuration: TimeInterval) { self.frameDuration = frameDuration }

    mutating func ingest(time: TimeInterval, estimate: PitchEstimate) {
        guard let frequency = estimate.frequency else {
            if let open = current, time - open.lastSeen > maxGap { close(open, at: open.lastSeen + frameDuration) }
            if current == nil { liveNote = nil }
            pending = nil
            return
        }
        let pitch = Int(YINPitchDetector.midiNote(forFrequency: frequency).rounded())
        guard (21...108).contains(pitch) else { return }
        liveNote = pitch

        guard var open = current else {
            if let waiting = pending, waiting.pitch == pitch {
                pending = (pitch, waiting.count + 1, waiting.first)
            } else {
                pending = (pitch, 1, time)
            }
            if let waiting = pending, waiting.count >= stabilityFrames {
                current = Open(pitch: pitch, start: waiting.first, lastSeen: time)
                pending = nil
            }
            return
        }

        if pitch == open.pitch {
            // Same pitch again after a break in the sound (a breath, or a repeated key): that is a new note.
            if time - open.lastSeen > frameDuration * 1.5 {
                close(open, at: open.lastSeen + frameDuration)
                current = Open(pitch: pitch, start: time, lastSeen: time)
            } else {
                open.lastSeen = time
                current = open
            }
            pending = nil
            return
        }
        // A different pitch: it must persist to count. Transient octave jumps are treated as glitches.
        let isOctaveJump = abs(pitch - open.pitch) == 12
        let needed = isOctaveJump ? stabilityFrames * 2 : stabilityFrames
        if let waiting = pending, waiting.pitch == pitch {
            pending = (pitch, waiting.count + 1, waiting.first)
        } else {
            pending = (pitch, 1, time)
        }
        if let waiting = pending, waiting.count >= needed {
            close(open, at: waiting.first)
            current = Open(pitch: pitch, start: waiting.first, lastSeen: time)
            pending = nil
        }
    }

    /// Ends the recording and returns the notes heard, merged and cleaned.
    mutating func finish(endTime: TimeInterval) -> [RawNote] {
        if let open = current { close(open, at: min(max(open.lastSeen + frameDuration, open.start + frameDuration), endTime)) }
        current = nil
        pending = nil
        liveNote = nil
        var cleaned: [RawNote] = []
        for note in notes where note.duration >= minNoteDuration {
            if let last = cleaned.last, last.pitch == note.pitch, note.start - (last.start + last.duration) < frameDuration * 1.6 {
                cleaned[cleaned.count - 1].duration = note.start + note.duration - last.start
            } else {
                cleaned.append(note)
            }
        }
        notes = []
        return cleaned
    }

    private mutating func close(_ open: Open, at end: TimeInterval) {
        notes.append(RawNote(pitch: open.pitch, start: open.start, duration: max(end - open.start, 0)))
        current = nil
    }
}

/// Turns raw heard notes into a clean, playable lesson.
enum ListenTranscriber {
    static let minimumNotes = 4
    static let maximumNotes = 64

    /// Evens out rhythm, shortens long silences, shifts whole octaves into the hand's comfortable register, and fingers it.
    static func lesson(from heard: [RawNote], hand: HandSide, title: String = "Heard tune") -> Lesson? {
        let notes = Array(heard.sorted { $0.start < $1.start }.prefix(maximumNotes))
        guard notes.count >= minimumNotes else { return nil }

        // One "beat" = the median note length, kept between 0.3 s and 0.8 s so lessons aren't too fast or slow.
        let durations = notes.map(\.duration).sorted()
        let beat = min(max(durations[durations.count / 2], 0.3), 0.8)
        func snap(_ value: TimeInterval) -> TimeInterval { max(0.25, (value / beat * 4).rounded() / 4) * beat }

        // Register: whole octaves so the median lands near middle C (right hand) or an octave below (left).
        let pitches = notes.map(\.pitch).sorted()
        let median = pitches[pitches.count / 2]
        let target = hand == .right ? 64 : 52
        var shift = 0
        while median + shift - target > 6 { shift -= 12 }
        while target - (median + shift) > 6 { shift += 12 }
        while pitches.last! + shift > 108 { shift -= 12 }
        while pitches.first! + shift < 21 { shift += 12 }

        var cursor = 0.0
        var raw: [RawNote] = []
        for (index, note) in notes.enumerated() {
            if index > 0 {
                let previous = notes[index - 1]
                let gap = note.start - (previous.start + previous.duration)
                if gap > 0.25 { cursor += min(snap(gap), beat * 2) }
            }
            let length = snap(note.duration)
            raw.append(RawNote(pitch: note.pitch + shift, start: cursor, duration: length))
            cursor += length
        }
        return LocalLessonEngine().lesson(title: title, rawNotes: raw, hand: hand, tempoBPM: 60 / beat, source: .imported,
                                          description: "Heard on this iPad and fingered locally (sound was not recorded)", emoji: "🎤")
    }
}
