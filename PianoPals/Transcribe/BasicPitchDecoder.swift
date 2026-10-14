import Foundation

/// Pure maths for turning Basic Pitch activations into notes. No Core ML in here, so it is fully testable.
///
/// The model takes 43 844 samples (≈ 2 s at 22.05 kHz) and returns 172 frames × 88 piano keys (A0…C8). Frame `f` of a window
/// starting at sample `s` sits at time `(s + 256 f) / 22 050` s. Windows overlap by 30 frames; only each window's middle 142
/// frames are kept, so frames line up exactly with no drift.
enum BasicPitch {
    static let sampleRate = 22_050.0
    static let windowSamples = 43_844
    static let framesPerWindow = 172
    static let frameHop = 256
    static let keyCount = 88
    static let lowestNote = 21
    /// Frames trimmed from each side of a window (half of the 30-frame overlap).
    static let trim = 15
    static let keptFrames = framesPerWindow - 2 * trim   // 142
    static let hopSamples = keptFrames * frameHop         // 36 352

    static func seconds(forFrame frame: Int) -> TimeInterval { Double(frame * frameHop) / sampleRate }

    /// Start sample of every window needed to cover `sampleCount` samples. The first starts `trim` frames *before* the audio
    /// (the model sees zeros there), so frame 0 of the audio is the first kept frame.
    static func windowStarts(sampleCount: Int) -> [Int] {
        guard sampleCount > 0 else { return [] }
        let totalFrames = Int((Double(sampleCount) / Double(frameHop)).rounded(.up))
        let windows = Int((Double(totalFrames) / Double(keptFrames)).rounded(.up))
        return (0..<max(windows, 1)).map { $0 * hopSamples - trim * frameHop }
    }

    /// The model input for one window: the audio from `start`, zero-filled outside the recording.
    static func window(of samples: [Float], start: Int) -> [Float] {
        var result = [Float](repeating: 0, count: windowSamples)
        let from = max(start, 0), to = min(start + windowSamples, samples.count)
        guard from < to else { return result }
        result.replaceSubrange((from - start)..<(to - start), with: samples[from..<to])
        return result
    }

    /// Joins per-window outputs (each `framesPerWindow × keyCount`, row-major) into one `frames × keyCount` grid.
    static func stitch(_ windows: [[Float]], sampleCount: Int) -> (grid: [Float], frames: Int) {
        let totalFrames = Int((Double(sampleCount) / Double(frameHop)).rounded(.up))
        var grid: [Float] = []
        grid.reserveCapacity(totalFrames * keyCount)
        for output in windows {
            let from = trim * keyCount, to = (trim + keptFrames) * keyCount
            grid.append(contentsOf: output[from..<to])
        }
        grid = Array(grid.prefix(totalFrames * keyCount))
        return (grid, grid.count / keyCount)
    }
}

struct DecodedNote: Equatable, Sendable {
    var pitch: Int
    var start: TimeInterval
    var end: TimeInterval
    var strength: Float

    var raw: RawNote { RawNote(pitch: pitch, start: start, duration: end - start) }
}

struct BasicPitchDecoder: Sendable {
    var onsetThreshold: Float = 0.5
    var frameThreshold: Float = 0.3
    /// Shortest note kept (frames). 11 frames ≈ 0.13 s.
    var minimumFrames = 11
    /// How many quiet frames inside a note are forgiven before it ends.
    var energyTolerance = 11

    /// `note` and `onset` are `frames × 88`, row-major. A note starts at an onset peak and lasts while its key stays active.
    func decode(note: [Float], onset: [Float], frames: Int) -> [DecodedNote] {
        let keys = BasicPitch.keyCount
        guard frames > 0, note.count >= frames * keys, onset.count >= frames * keys else { return [] }
        var energy = Array(note.prefix(frames * keys))
        func at(_ frame: Int, _ key: Int) -> Float { energy[frame * keys + key] }

        // Onset peaks: a local maximum over the threshold. Later onsets claim their frames first so repeated notes split.
        var peaks: [(frame: Int, key: Int)] = []
        for key in 0..<keys {
            for frame in 0..<frames {
                let value = onset[frame * keys + key]
                guard value >= onsetThreshold else { continue }
                let before = frame > 0 ? onset[(frame - 1) * keys + key] : 0
                let after = frame + 1 < frames ? onset[(frame + 1) * keys + key] : 0
                if value > before && value >= after { peaks.append((frame, key)) }
            }
        }
        peaks.sort { $0.frame != $1.frame ? $0.frame > $1.frame : $0.key < $1.key }

        var notes: [DecodedNote] = []
        for peak in peaks {
            var quiet = 0
            var frame = peak.frame
            var last = peak.frame
            while frame < frames {
                if at(frame, peak.key) > frameThreshold { quiet = 0; last = frame } else {
                    quiet += 1
                    if quiet > energyTolerance { break }
                }
                frame += 1
            }
            let length = last - peak.frame + 1
            guard length >= minimumFrames else { continue }
            var total: Float = 0
            for f in peak.frame...last { total += at(f, peak.key) }
            for f in peak.frame...last { energy[f * keys + peak.key] = 0 }
            notes.append(DecodedNote(pitch: BasicPitch.lowestNote + peak.key,
                                     start: BasicPitch.seconds(forFrame: peak.frame), end: BasicPitch.seconds(forFrame: last + 1),
                                     strength: total / Float(length)))
        }
        return notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
    }

    /// A struck string also rings at 2×, 3× and 4× its pitch (an octave, an octave and a fifth, two octaves above), and the model
    /// reports those as weaker "ghost" notes starting together with the real one. Drop a note when a note 12, 19 or 24 semitones
    /// below it starts at the same moment and is clearly stronger. Two notes played an octave apart sound equally strong and stay.
    static func suppressingHarmonics(_ notes: [DecodedNote], within window: TimeInterval = 0.06, ratio: Float = 0.75) -> [DecodedNote] {
        notes.filter { ghost in
            !notes.contains { base in
                [12, 19, 24].contains(ghost.pitch - base.pitch) && abs(base.start - ghost.start) <= window
                    && ghost.strength < ratio * base.strength
            }
        }
    }
}
