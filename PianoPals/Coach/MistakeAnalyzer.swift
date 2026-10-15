import Foundation

/// Which way the right key lies from the key that was pressed.
enum KeyNearness: Equatable, Hashable, Sendable {
    /// Within two semitones; the associated value says where the *expected* key is.
    case adjacent(expectedIs: Direction)
    /// Same note name in another octave.
    case otherOctave
    case far

    enum Direction: Equatable, Hashable, Sendable {
        case left
        case right
    }

    static func between(played: Int, expected: Int) -> KeyNearness {
        let difference = expected - played
        if difference != 0, abs(difference) <= 2 { return .adjacent(expectedIs: difference > 0 ? .right : .left) }
        if difference != 0, difference % 12 == 0 { return .otherOctave }
        return .far
    }
}

enum MistakeKind: Equatable, Hashable, Sendable {
    case wrongKey(played: Int, expected: Int, nearness: KeyNearness)
    case wrongFinger(expected: Finger, played: Finger)
    case wrongHand(expected: HandSide, played: HandSide)
    /// The child hasn't played for a while after a note appeared.
    case hesitation
    /// "Play along" only: a note went by.
    case skippedNote
}

struct Mistake: Equatable, Sendable {
    let time: TimeInterval
    let kind: MistakeKind
}

struct FingerStats: Codable, Equatable, Sendable {
    /// Correct keys played with this finger as the suggested one.
    var attempts = 0
    /// Of those, how many the camera saw with a different finger / hand.
    var errors = 0
    var errorRate: Double { attempts == 0 ? 0 : Double(errors) / Double(attempts) }
}

/// Running counters for one lesson attempt.
struct SessionStats: Equatable, Sendable {
    var keyAttempts = 0
    var hits = 0
    var firstTryHits = 0
    var wrongKeys = 0
    var wrongFingers = 0
    var wrongHands = 0
    var hesitations = 0
    var skipped = 0
    /// Hits where the camera could judge the finger, and how many of those were right.
    var fingerVerified = 0
    var fingerCorrect = 0
    var perFinger: [Int: FingerStats] = [:]
    /// Last ten key attempts: true = a wrong key or a skipped note.
    var recent: [Bool] = []
    var consecutiveWrongKeys = 0

    /// Share of notes played correctly on the first press (0…1).
    var firstTryAccuracy: Double { hits == 0 ? 0 : Double(firstTryHits) / Double(hits) }
    /// Share of camera-verified notes played with the suggested finger; nil when the camera never judged one.
    var fingerAccuracy: Double? { fingerVerified == 0 ? nil : Double(fingerCorrect) / Double(fingerVerified) }
    var recentErrorCount: Int { recent.filter { $0 }.count }

    /// The finger most often confused, if there's enough evidence (≥ 3 tries, ≥ 2 mix-ups, ≥ 34 %).
    var weakestFinger: Finger? {
        perFinger
            .filter { $0.value.attempts >= 3 && $0.value.errors >= 2 && $0.value.errorRate >= 0.34 }
            .max { $0.value.errorRate < $1.value.errorRate }
            .flatMap { Finger(rawValue: $0.key) }
    }

    mutating func pushRecent(_ error: Bool) {
        recent.append(error)
        if recent.count > 10 { recent.removeFirst() }
    }
}

/// Turns the lesson engine's events into classified mistakes and statistics. Pure and deterministic: time is always
/// passed in, so it is trivial to test.
struct MistakeAnalyzer: Sendable {
    /// Seconds without a key press, with a note waiting, before we call it hesitation.
    static let hesitationSeconds: TimeInterval = 7

    private(set) var stats = SessionStats()
    private var waitingSince: TimeInterval?
    private var hesitationFlagged = false
    private var wrongForCurrentTarget = false

    mutating func reset() {
        self = MistakeAnalyzer()
    }

    /// Call when play resumes after a pause so resting time isn't counted as hesitation.
    mutating func resumed(at now: TimeInterval) {
        waitingSince = now
        hesitationFlagged = false
    }

    mutating func ingest(_ event: SessionEvent, lessonHand: HandSide, now: TimeInterval) -> [Mistake] {
        var mistakes: [Mistake] = []
        switch event {
        case .started:
            reset()
            waitingSince = now

        case .gentleMiss(let played, let expected):
            let target = expected.min { abs($0 - played) < abs($1 - played) } ?? played
            stats.keyAttempts += 1
            stats.wrongKeys += 1
            stats.consecutiveWrongKeys += 1
            stats.pushRecent(true)
            wrongForCurrentTarget = true
            mistakes.append(Mistake(time: now, kind: .wrongKey(played: played, expected: target,
                                                               nearness: .between(played: played, expected: target))))

        case .noteHit(_, let note, let quality):
            stats.keyAttempts += 1
            stats.hits += 1
            if !wrongForCurrentTarget { stats.firstTryHits += 1 }
            stats.consecutiveWrongKeys = 0
            stats.pushRecent(false)
            var finger = stats.perFinger[note.assignedFinger] ?? FingerStats()
            finger.attempts += 1
            switch quality {
            case .perfect:
                stats.fingerVerified += 1
                stats.fingerCorrect += 1
            case .fingerUnverified:
                break
            case .fingerOff(let played):
                stats.fingerVerified += 1
                stats.wrongFingers += 1
                finger.errors += 1
                mistakes.append(Mistake(time: now, kind: .wrongFinger(expected: note.finger, played: played)))
            case .wrongHand(let played):
                stats.fingerVerified += 1
                stats.wrongHands += 1
                finger.errors += 1
                mistakes.append(Mistake(time: now, kind: .wrongHand(expected: note.hand ?? lessonHand, played: played)))
            }
            stats.perFinger[note.assignedFinger] = finger
            wrongForCurrentTarget = false
            waitingSince = now
            hesitationFlagged = false

        case .noteMissed:
            stats.skipped += 1
            stats.pushRecent(true)
            mistakes.append(Mistake(time: now, kind: .skippedNote))

        case .finished, .freePlay, .rewound:
            break
        }
        return mistakes
    }

    /// Call about once a second while a lesson is playing.
    mutating func tick(now: TimeInterval, hasTargets: Bool) -> [Mistake] {
        guard hasTargets, !hesitationFlagged, let since = waitingSince,
              now - since >= MistakeAnalyzer.hesitationSeconds else { return [] }
        hesitationFlagged = true
        stats.hesitations += 1
        return [Mistake(time: now, kind: .hesitation)]
    }
}
