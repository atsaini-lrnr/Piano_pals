import Foundation

/// Chooses which stretch of the keyboard the screen shows, and slides it by whole octaves as the music moves, so the lane, the
/// on-screen keys and the lined-up camera strip always show the same keys.
///
/// * A lesson that fits in the window never moves.
/// * A longer lesson (a scale over two octaves, a piece that climbs) follows the upcoming notes: the window jumps an octave when
///   the next notes leave its comfortable middle, then stays put (no jitter).
struct SpanFollower: Equatable, Sendable {
    /// Number of white keys on screen.
    let windowKeys: Int
    /// The real keyboard's range; the window never leaves it.
    let limit: ClosedRange<Int>
    /// White-key index (from MIDI 0; every 7th is a C) of the window's left edge.
    private(set) var startWhite: Int?

    init(windowKeys: Int = 15, limit: ClosedRange<Int> = 21...108) {
        self.windowKeys = windowKeys
        self.limit = limit
    }

    var span: KeyboardSpan? {
        startWhite.map { KeyboardSpan(lowNote: KeyboardSpan.note(forWhiteIndex: $0), highNote: KeyboardSpan.note(forWhiteIndex: $0 + windowKeys - 1)) }
    }

    /// `lessonRange` is the lowest and highest note of the whole lesson; `upcoming` are the next notes to play, soonest first.
    mutating func update(lessonRange: ClosedRange<Int>, upcoming: [Int]) -> KeyboardSpan {
        let minStart = PianoKeys.whiteIndex(limit.lowerBound)
        let maxStart = max(minStart, PianoKeys.whiteIndex(limit.upperBound) - windowKeys + 1)
        func clamp(_ start: Int) -> Int { min(max(start, minStart), maxStart) }

        let lessonLow = PianoKeys.whiteIndex(lessonRange.lowerBound), lessonHigh = PianoKeys.whiteIndex(lessonRange.upperBound)
        if lessonHigh - lessonLow + 1 <= windowKeys - 2 {
            // Fits with a key to spare either side: centre it once and leave it alone (matches the non-panning layout).
            let spare = windowKeys - (lessonHigh - lessonLow + 1)
            startWhite = clamp(lessonLow - spare / 2)
            return span!
        }

        let soon = Array(upcoming.prefix(4)).map { PianoKeys.whiteIndex($0) }
        guard let low = soon.min(), let high = soon.max() else {
            if startWhite == nil { startWhite = clamp(octaveStart(lessonLow - 2)) }
            return span!
        }
        if let current = startWhite {
            // Comfortable zone: one key in from each edge. Stay put while the next notes are inside it.
            if low >= current + 1, high <= current + windowKeys - 2 { return span! }
        }
        var start = octaveStart(low - 2)
        if high > start + windowKeys - 2 { start += 7 }
        startWhite = clamp(start)
        return span!
    }

    /// The C at or below white-key index `index`.
    private func octaveStart(_ index: Int) -> Int { Int((Double(index) / 7).rounded(.down)) * 7 }
}
