import Foundation

/// Pure helpers describing the layout of a piano keyboard.
///
/// Positions are expressed in "white-key units": the white key with index `i`
/// spans `i ..< i + 1` and has its centre at `i + 0.5`. A black key is centred on
/// the boundary between its two neighbouring white keys.
enum PianoKeys {
    private static let blackPitchClasses: Set<Int> = [1, 3, 6, 8, 10]
    /// Pitch class → index of the white key at (or directly below) that pitch class within an octave.
    private static let whiteOffsets = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
    private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func isBlack(_ note: Int) -> Bool {
        blackPitchClasses.contains(((note % 12) + 12) % 12)
    }

    /// Index of the white key at or below `note`, counting white keys from MIDI note 0.
    static func whiteIndex(_ note: Int) -> Int {
        let octave = Int((Double(note) / 12).rounded(.down))
        let pitchClass = note - octave * 12
        return octave * 7 + whiteOffsets[pitchClass]
    }

    /// Centre of `note` in white-key units, counted from MIDI note 0.
    static func center(of note: Int) -> Double {
        isBlack(note) ? Double(whiteIndex(note)) + 1.0 : Double(whiteIndex(note)) + 0.5
    }

    /// Scientific pitch name, e.g. 60 → "C4".
    static func name(_ note: Int) -> String {
        let octave = Int((Double(note) / 12).rounded(.down)) - 1
        let pitchClass = ((note % 12) + 12) % 12
        return "\(sharpNames[pitchClass])\(octave)"
    }

    /// Parses "C4", "F#3", "Bb2", "c" (octave defaults to 4). Returns nil when invalid.
    static func midiNumber(name raw: String) -> Int? {
        let chars = Array(raw.trimmingCharacters(in: .whitespaces))
        guard let first = chars.first, let letter = first.uppercased().first else { return nil }
        let base: Int
        switch letter {
        case "C": base = 0
        case "D": base = 2
        case "E": base = 4
        case "F": base = 5
        case "G": base = 7
        case "A": base = 9
        case "B": base = 11
        default: return nil
        }
        var index = 1
        var accidental = 0
        while index < chars.count, chars[index] == "#" || chars[index] == "b" || chars[index] == "♯" || chars[index] == "♭" {
            accidental += (chars[index] == "#" || chars[index] == "♯") ? 1 : -1
            index += 1
        }
        var octave = 4
        if index < chars.count {
            guard let parsed = Int(String(chars[index...])) else { return nil }
            octave = parsed
        }
        let value = (octave + 1) * 12 + base + accidental
        return (0...127).contains(value) ? value : nil
    }

    /// Number of white keys in the inclusive MIDI range.
    static func whiteKeyCount(from low: Int, to high: Int) -> Int {
        guard high >= low else { return 0 }
        return (low...high).filter { !isBlack($0) }.count
    }
}

/// The span of keys drawn on screen for a lesson (always starts and ends on a white key).
struct KeyboardSpan: Equatable, Sendable {
    let lowNote: Int
    let highNote: Int

    /// Whole-lesson span, padded by one white key either side and widened to at least `minimumWhiteKeys`.
    static func fitting(low: Int, high: Int, minimumWhiteKeys: Int = 8) -> KeyboardSpan {
        var lowWhite = PianoKeys.whiteIndex(low) - 1
        var highWhite = PianoKeys.whiteIndex(high) + 1
        // Never run off the bottom/top of an 88-key piano (A0 = 21 … C8 = 108).
        let minWhite = PianoKeys.whiteIndex(21)
        let maxWhite = PianoKeys.whiteIndex(108)
        lowWhite = max(lowWhite, minWhite)
        highWhite = min(highWhite, maxWhite)
        while highWhite - lowWhite + 1 < minimumWhiteKeys {
            if highWhite < maxWhite { highWhite += 1 }
            if highWhite - lowWhite + 1 < minimumWhiteKeys, lowWhite > minWhite { lowWhite -= 1 }
            if highWhite == maxWhite && lowWhite == minWhite { break }
        }
        return KeyboardSpan(lowNote: note(forWhiteIndex: lowWhite), highNote: note(forWhiteIndex: highWhite))
    }

    var firstWhiteIndex: Int { PianoKeys.whiteIndex(lowNote) }
    var whiteKeyCount: Int { PianoKeys.whiteIndex(highNote) - firstWhiteIndex + 1 }

    /// x position of `note`'s centre as a fraction of the span's width (0…1 when inside).
    func fraction(of note: Int) -> Double {
        (PianoKeys.center(of: note) - Double(firstWhiteIndex)) / Double(max(whiteKeyCount, 1))
    }

    func contains(_ note: Int) -> Bool {
        if PianoKeys.isBlack(note) {
            // A black key is drawn only when both of its neighbours are.
            return note > lowNote && note < highNote
        }
        return note >= lowNote && note <= highNote
    }

    /// All MIDI notes drawn in this span, in ascending order.
    var notes: [Int] { (lowNote...highNote).filter { contains($0) } }

    /// MIDI note of the white key with the given absolute white-key index.
    static func note(forWhiteIndex index: Int) -> Int {
        let octave = index / 7
        let offsets = [0, 2, 4, 5, 7, 9, 11]
        return octave * 12 + offsets[index % 7]
    }
}
