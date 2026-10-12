import Foundation

/// On-device fingering assignment.
///
/// A Viterbi search over the five fingers for every note. Transition costs reward the natural
/// "one finger per key" movement inside a hand position (ascending lines map to ascending finger
/// numbers for the right hand, the reverse for the left), and penalise stretches, wrong-way finger
/// movement, hand shifts, and thumbs on black keys. Where several fingerings cost the same, the
/// thumb is preferred on the lowest note (right hand) or highest note (left hand) of a short phrase.
enum FingeringEngine {
    /// Largest semitone span that two fingers `n` apart can comfortably reach.
    private static let comfortableSpan: [Int: Int] = [1: 3, 2: 5, 3: 7, 4: 9]

    /// Assigns a finger to every note. Simultaneous onsets are reduced to a single melody line
    /// (the highest pitch for the right hand, the lowest for the left).
    static func assign(_ rawNotes: [RawNote], hand: HandSide) -> [Note] {
        let line = melodyLine(from: rawNotes, hand: hand)
        guard !line.isEmpty else { return [] }
        let fingers = bestFingers(for: line.map(\.pitch), hand: hand)
        return zip(line, fingers).map { raw, finger in
            Note(timestamp: raw.start, duration: raw.duration, noteNumber: raw.pitch, assignedFinger: finger)
        }
    }

    /// Collapses chords into a single line and sorts by onset.
    static func melodyLine(from rawNotes: [RawNote], hand: HandSide, onsetTolerance: TimeInterval = 0.02) -> [RawNote] {
        let sorted = rawNotes
            .filter { $0.duration > 0 && (0...127).contains($0.pitch) }
            .sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        var result: [RawNote] = []
        for note in sorted {
            if let last = result.last, abs(last.start - note.start) <= onsetTolerance {
                let keepNew = hand == .right ? note.pitch > last.pitch : note.pitch < last.pitch
                if keepNew { result[result.count - 1] = note }
            } else {
                result.append(note)
            }
        }
        return result
    }

    /// Viterbi search returning one finger (1…5) per pitch.
    static func bestFingers(for pitches: [Int], hand: HandSide) -> [Int] {
        guard !pitches.isEmpty else { return [] }
        let count = pitches.count
        let unary = unaryCosts(for: pitches, hand: hand)

        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: 6), count: count)
        var back = [[Int]](repeating: [Int](repeating: 0, count: 6), count: count)
        for finger in 1...5 { cost[0][finger] = unary[0][finger] }

        if count > 1 {
            for i in 1..<count {
                for next in 1...5 {
                    var bestCost = Double.infinity
                    var bestPrevious = 1
                    for previous in 1...5 {
                        let total = cost[i - 1][previous]
                            + transitionCost(from: previous, to: next, previousPitch: pitches[i - 1], pitch: pitches[i], hand: hand)
                        if total < bestCost - 1e-9 {
                            bestCost = total
                            bestPrevious = previous
                        }
                    }
                    cost[i][next] = bestCost + unary[i][next]
                    back[i][next] = bestPrevious
                }
            }
        }

        var finger = 1
        var best = Double.infinity
        for candidate in 1...5 where cost[count - 1][candidate] < best - 1e-9 {
            best = cost[count - 1][candidate]
            finger = candidate
        }
        var result = [Int](repeating: 1, count: count)
        var i = count - 1
        while i >= 0 {
            result[i] = finger
            if i > 0 { finger = back[i][finger] }
            i -= 1
        }
        return result
    }

    // MARK: - Costs

    /// Cost of the hand being in a given position when playing each note with each finger.
    private static func unaryCosts(for pitches: [Int], hand: HandSide) -> [[Double]] {
        let whites = pitches.map { PianoKeys.whiteIndex($0) }
        let lowest = whites.min() ?? 0
        let highest = whites.max() ?? 0
        let fitsOnePosition = highest - lowest <= 4

        return pitches.indices.map { i in
            var row = [Double](repeating: 0, count: 6)
            for finger in 1...5 {
                var value = 0.0
                if fitsOnePosition {
                    // Position of the thumb implied by playing this note with this finger.
                    let thumb = hand == .right ? whites[i] - (finger - 1) : whites[i] + (finger - 1)
                    let ideal = hand == .right ? lowest : highest
                    value += 0.1 * Double(abs(thumb - ideal))
                } else {
                    value += 0.02 * Double(abs(finger - 3))
                }
                if PianoKeys.isBlack(pitches[i]) {
                    if finger == 1 { value += 2.0 }
                    if finger == 5 { value += 0.5 }
                }
                row[finger] = value
            }
            return row
        }
    }

    private static func transitionCost(from previous: Int, to next: Int, previousPitch: Int, pitch: Int, hand: HandSide) -> Double {
        let semitones = pitch - previousPitch
        // Beginners repeat a note with the same finger; changing is allowed only if everything else is far worse.
        if semitones == 0 { return previous == next ? 0 : 8.0 }

        let whiteSteps = max(1, Int((abs(PianoKeys.center(of: pitch) - PianoKeys.center(of: previousPitch))).rounded()))
        let handSign = hand == .right ? 1 : -1
        let direction = semitones > 0 ? 1 : -1
        // Positive when the finger number moves the same way the pitch moves (for this hand).
        let moved = (next - previous) * handSign * direction

        if whiteSteps > 4 {
            // A leap: the hand has to relocate, so any landing finger costs the same.
            return 2.0 + 0.1 * Double(whiteSteps)
        }
        if moved > 0 {
            var cost = Double(abs(moved - whiteSteps))
            if let limit = comfortableSpan[moved], abs(semitones) > limit { cost += 1.5 }
            return cost
        }
        if moved == 0 { return 4.0 }
        return 5.0
    }
}
