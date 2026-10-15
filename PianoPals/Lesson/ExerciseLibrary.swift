import Foundation

enum ExerciseCategory: String, CaseIterable, Identifiable, Sendable {
    case bothHands
    case warmUp
    case fingerDrills
    case scales
    case arpeggios

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bothHands: return "Both hands"
        case .warmUp: return "Warm-ups"
        case .fingerDrills: return "Finger drills"
        case .scales: return "Scales"
        case .arpeggios: return "Chord climbs"
        }
    }
    var emoji: String {
        switch self {
        case .bothHands: return "🙌"
        case .warmUp: return "🔥"
        case .fingerDrills: return "💪"
        case .scales: return "🪜"
        case .arpeggios: return "🌈"
        }
    }
    var blurb: String {
        switch self {
        case .bothHands: return "Left and right play together"
        case .warmUp: return "Wake up your fingers"
        case .fingerDrills: return "Make every finger strong"
        case .scales: return "Climb up and down the keys"
        case .arpeggios: return "Jump to every other key"
        }
    }
}

struct ExerciseNote: Equatable, Sendable {
    var pitch: Int
    var finger: Int
    var beats: Double
    /// Both-hands exercises: which hand plays this note.
    var hand: HandSide? = nil
    /// Both-hands exercises: the beat the note starts on, so the hands can overlap. nil: right after the previous note.
    var start: Double? = nil
}

/// A short, generated practice piece with a fixed, textbook fingering.
struct Exercise: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let category: ExerciseCategory
    let hand: HandSide
    /// 1 = very first steps … 3 = a bit tricky.
    let level: Int
    let emoji: String
    let bpm: Double
    let notes: [ExerciseNote]
    /// True when the left and right hand play together.
    var bothHands = false

    func fits(in range: ClosedRange<Int>) -> Bool {
        guard let low = notes.map(\.pitch).min(), let high = notes.map(\.pitch).max() else { return true }
        return low >= range.lowerBound && high <= range.upperBound
    }

    func lesson() -> Lesson {
        let seconds = 60 / bpm
        var cursor = 0.0
        let converted = notes.map { note -> Note in
            let begin = note.start.map { $0 * seconds } ?? cursor
            defer { if note.start == nil { cursor += note.beats * seconds } }
            return Note(timestamp: begin, duration: note.beats * seconds, noteNumber: note.pitch, assignedFinger: note.finger, hand: note.hand)
        }
        return Lesson(title: title, composer: "Practice", hand: hand, tempoBPM: bpm, notes: converted, source: .library,
                      sourceDescription: "Practice exercise: \(subtitle)", emoji: emoji)
    }
}

/// Generates the practice library: five-finger patterns in several positions, and one-octave major and natural-minor scales
/// for each hand with the standard fingerings.
enum ExerciseLibrary {
    // MARK: Positions

    /// A five-finger position: where the thumb sits for each hand (white keys only).
    struct Position: Sendable {
        let name: String
        let rightThumb: Int
        let leftThumb: Int
    }

    static let positions: [Position] = [
        Position(name: "C", rightThumb: 60, leftThumb: 55),   // RH C D E F G · LH G F E D C
        Position(name: "G", rightThumb: 67, leftThumb: 50),   // RH G A B C D · LH D C B A G
        Position(name: "A", rightThumb: 69, leftThumb: 52)    // RH A B C D E · LH E D C B A
    ]

    /// The key under `finger` (1…5) when the hand is in `position`.
    static func note(finger: Int, position: Position, hand: HandSide) -> Int {
        let steps = finger - 1
        switch hand {
        case .right: return KeyboardSpan.note(forWhiteIndex: PianoKeys.whiteIndex(position.rightThumb) + steps)
        case .left: return KeyboardSpan.note(forWhiteIndex: PianoKeys.whiteIndex(position.leftThumb) - steps)
        }
    }

    // MARK: Patterns

    private struct Pattern {
        let id: String
        let title: String
        let blurb: String
        let category: ExerciseCategory
        let level: Int
        let fingers: [Int]
        let bpm: Double
    }

    private static let patterns: [Pattern] = [
        Pattern(id: "walk", title: "Five Finger Walk", blurb: "up and down", category: .warmUp, level: 1,
                fingers: [1, 2, 3, 4, 5, 4, 3, 2, 1], bpm: 76),
        Pattern(id: "steady", title: "Steady Fingers", blurb: "each finger three times", category: .warmUp, level: 1,
                fingers: [1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5], bpm: 84),
        Pattern(id: "hills", title: "Three-Note Hills", blurb: "little hills", category: .fingerDrills, level: 2,
                fingers: [1, 2, 3, 2, 3, 4, 3, 4, 5, 4, 3, 2, 3, 2, 1], bpm: 76),
        Pattern(id: "skips", title: "Skip and Step", blurb: "skip a finger, step back", category: .fingerDrills, level: 2,
                fingers: [1, 3, 2, 4, 3, 5, 4, 3, 2, 1], bpm: 72),
        Pattern(id: "stretch", title: "Big Stretch", blurb: "thumb and pinky", category: .fingerDrills, level: 3,
                fingers: [1, 5, 1, 5, 2, 4, 2, 4, 3], bpm: 68),
        Pattern(id: "chord-climb", title: "Chord Climb", blurb: "1-3-5 jumps", category: .arpeggios, level: 2,
                fingers: [1, 3, 5, 3, 1, 3, 5, 3, 1], bpm: 76)
    ]

    // MARK: Scales

    struct ScaleKey: Sendable {
        let name: String
        let isMinor: Bool
        /// Tonic as a pitch class (0 = C).
        let tonic: Int
        /// F major needs a different right-hand fingering from the sharp keys.
        let rightFingers: [Int]
        let leftFingers: [Int]
        let level: Int
    }

    private static let standardRight = [1, 2, 3, 1, 2, 3, 4, 5]
    private static let standardLeft = [5, 4, 3, 2, 1, 3, 2, 1]

    static let scaleKeys: [ScaleKey] = [
        ScaleKey(name: "C Major", isMinor: false, tonic: 0, rightFingers: standardRight, leftFingers: standardLeft, level: 1),
        ScaleKey(name: "G Major", isMinor: false, tonic: 7, rightFingers: standardRight, leftFingers: standardLeft, level: 2),
        ScaleKey(name: "F Major", isMinor: false, tonic: 5, rightFingers: [1, 2, 3, 4, 1, 2, 3, 4], leftFingers: standardLeft, level: 2),
        ScaleKey(name: "D Major", isMinor: false, tonic: 2, rightFingers: standardRight, leftFingers: standardLeft, level: 2),
        ScaleKey(name: "A Major", isMinor: false, tonic: 9, rightFingers: standardRight, leftFingers: standardLeft, level: 3),
        ScaleKey(name: "E Major", isMinor: false, tonic: 4, rightFingers: standardRight, leftFingers: standardLeft, level: 3),
        ScaleKey(name: "A Minor", isMinor: true, tonic: 9, rightFingers: standardRight, leftFingers: standardLeft, level: 3),
        ScaleKey(name: "E Minor", isMinor: true, tonic: 4, rightFingers: standardRight, leftFingers: standardLeft, level: 3),
        ScaleKey(name: "D Minor", isMinor: true, tonic: 2, rightFingers: standardRight, leftFingers: standardLeft, level: 3)
    ]

    private static let majorSteps = [0, 2, 4, 5, 7, 9, 11, 12]
    private static let naturalMinorSteps = [0, 2, 3, 5, 7, 8, 10, 12]

    /// One-octave scale pitches, ascending (8 notes).
    static func scalePitches(_ key: ScaleKey, hand: HandSide) -> [Int] {
        // Right hand starts in the octave above middle C. The left hand starts in the octave below it, except for the higher keys
        // (G, A…), which start an octave lower so the scale stays comfortably under the right hand.
        let tonic: Int
        switch hand {
        case .right: tonic = 60 + key.tonic
        case .left: tonic = (key.tonic >= 6 ? 36 : 48) + key.tonic
        }
        return (key.isMinor ? naturalMinorSteps : majorSteps).map { tonic + $0 }
    }

    static func scaleExercise(_ key: ScaleKey, hand: HandSide) -> Exercise {
        let up = scalePitches(key, hand: hand)
        let fingers = hand == .right ? key.rightFingers : key.leftFingers
        let pitches = up + up.dropLast().reversed()
        let allFingers = fingers + fingers.dropLast().reversed()
        let notes = zip(pitches, allFingers).enumerated().map { index, pair in
            ExerciseNote(pitch: pair.0, finger: pair.1, beats: index == pitches.count - 1 ? 2 : 1)
        }
        return Exercise(id: "scale-\(key.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(hand.rawValue)",
                        title: "\(key.name) Scale", subtitle: "\(hand.displayName) hand · up and down", category: .scales, hand: hand,
                        level: key.level, emoji: "🪜", bpm: 72, notes: notes)
    }

    static func patternExercise(id: String, position: Position, hand: HandSide) -> Exercise? {
        guard let pattern = patterns.first(where: { $0.id == id }) else { return nil }
        let notes = pattern.fingers.enumerated().map { index, finger in
            ExerciseNote(pitch: note(finger: finger, position: position, hand: hand), finger: finger,
                         beats: index == pattern.fingers.count - 1 ? 2 : 1)
        }
        return Exercise(id: "\(pattern.id)-\(position.name.lowercased())-\(hand.rawValue)", title: pattern.title,
                        subtitle: "\(hand.displayName) hand · \(position.name) position · \(pattern.blurb)", category: pattern.category, hand: hand,
                        level: pattern.level, emoji: pattern.category.emoji, bpm: pattern.bpm, notes: notes)
    }

    /// Plays the other four fingers against `finger`, so that finger gets most of the work.
    static func fingerFocus(_ finger: Finger, hand: HandSide, position: Position = positions[0]) -> Exercise {
        let others = (1...5).filter { $0 != finger.number }
        let sequence = others.flatMap { [$0, finger.number] }
        let notes = sequence.enumerated().map { index, number in
            ExerciseNote(pitch: note(finger: number, position: position, hand: hand), finger: number,
                         beats: index == sequence.count - 1 ? 2 : 1)
        }
        return Exercise(id: "focus-\(finger.number)-\(hand.rawValue)", title: "\(finger.kidName) Practice",
                        subtitle: "\(hand.displayName) hand · the \(finger.displayName.lowercased()) finger gets a workout", category: .fingerDrills, hand: hand,
                        level: 2, emoji: "🎯", bpm: 70, notes: notes)
    }

    // MARK: Both hands together

    /// The key under `finger` in the C position, for either hand.
    private static func key(_ finger: Int, _ hand: HandSide) -> Int { note(finger: finger, position: positions[0], hand: hand) }

    /// One step for each hand, starting on the same beat.
    private static func pair(right: (pitch: Int, finger: Int), left: (pitch: Int, finger: Int), at beat: Double, beats: Double) -> [ExerciseNote] {
        [ExerciseNote(pitch: right.pitch, finger: right.finger, beats: beats, hand: .right, start: beat),
         ExerciseNote(pitch: left.pitch, finger: left.finger, beats: beats, hand: .left, start: beat)]
    }

    private static func togetherExercise(_ id: String, _ title: String, _ subtitle: String, level: Int, bpm: Double, notes: [ExerciseNote]) -> Exercise {
        Exercise(id: "both-\(id)", title: title, subtitle: "Both hands · \(subtitle)", category: .bothHands, hand: .right, level: level,
                 emoji: "🙌", bpm: bpm, notes: notes, bothHands: true)
    }

    /// Hands-together scale: right hand from the octave above middle C, left hand from the octave below, moving the same way.
    static func bothHandsScale(_ scaleKey: ScaleKey) -> Exercise {
        func line(_ hand: HandSide) -> [(pitch: Int, finger: Int)] {
            let up = scalePitches(scaleKey, hand: hand)
            let fingers = hand == .right ? scaleKey.rightFingers : scaleKey.leftFingers
            return Array(zip(up + up.dropLast().reversed(), fingers + fingers.dropLast().reversed()).map { (pitch: $0.0, finger: $0.1) })
        }
        let right = line(.right), left = line(.left)
        var notes: [ExerciseNote] = []
        for index in right.indices { notes += pair(right: right[index], left: left[index], at: Double(index), beats: index == right.count - 1 ? 2 : 1) }
        return togetherExercise("scale-\(scaleKey.name.lowercased().replacingOccurrences(of: " ", with: "-"))", "\(scaleKey.name) Together",
                                "scale, hands together", level: min(scaleKey.level + 1, 3), bpm: 66, notes: notes)
    }

    static let bothHandsExercises: [Exercise] = {
        let walk = [1, 2, 3, 4, 5, 4, 3, 2, 1]
        var result: [Exercise] = []

        var mirror: [ExerciseNote] = []
        for (index, finger) in walk.enumerated() {
            mirror += pair(right: (key(finger, .right), finger), left: (key(finger, .left), finger), at: Double(index), beats: index == walk.count - 1 ? 2 : 1)
        }
        result.append(togetherExercise("mirror-walk", "Mirror Walk", "same fingers, hands move apart and back", level: 1, bpm: 66, notes: mirror))

        var twins: [ExerciseNote] = []
        for (index, finger) in walk.enumerated() {
            twins += pair(right: (key(finger, .right), finger), left: (key(6 - finger, .left), 6 - finger), at: Double(index), beats: index == walk.count - 1 ? 2 : 1)
        }
        result.append(togetherExercise("octave-twins", "Octave Twins", "both hands climb the same way", level: 2, bpm: 66, notes: twins))

        var turns: [ExerciseNote] = []
        for finger in 1...5 {
            turns.append(ExerciseNote(pitch: key(finger, .right), finger: finger, beats: 1, hand: .right))
            turns.append(ExerciseNote(pitch: key(finger, .left), finger: finger, beats: finger == 5 ? 2 : 1, hand: .left))
        }
        result.append(togetherExercise("take-turns", "Take Turns", "right, left, right, left", level: 1, bpm: 76, notes: turns))

        var holds: [ExerciseNote] = [ExerciseNote(pitch: key(5, .left), finger: 5, beats: 8, hand: .left, start: 0)]
        for (index, finger) in [1, 2, 3, 4, 5, 4, 3, 2].enumerated() {
            holds.append(ExerciseNote(pitch: key(finger, .right), finger: finger, beats: 1, hand: .right, start: Double(index)))
        }
        result.append(togetherExercise("left-holds", "Left Holds, Right Plays", "the left hand holds one key", level: 2, bpm: 68, notes: holds))

        var tune: [ExerciseNote] = []
        for bar in 0..<3 {
            let beat = Double(bar * 4)
            tune.append(ExerciseNote(pitch: key(5, .left), finger: 5, beats: 4, hand: .left, start: beat))
            tune.append(ExerciseNote(pitch: key(1, .left), finger: 1, beats: 4, hand: .left, start: beat))
            let fingers = bar == 0 ? [1, 2, 3, 4] : (bar == 1 ? [5, 4, 3, 2] : [1])
            for (index, finger) in fingers.enumerated() {
                tune.append(ExerciseNote(pitch: key(finger, .right), finger: finger, beats: bar == 2 ? 4 : 1, hand: .right, start: beat + Double(index)))
            }
        }
        result.append(togetherExercise("chord-and-tune", "Chord and Tune", "two left-hand keys under a right-hand tune", level: 3, bpm: 64, notes: tune))

        for scaleKey in scaleKeys where !scaleKey.isMinor && scaleKey.level <= 2 { result.append(bothHandsScale(scaleKey)) }
        return result
    }()

    // MARK: Whole library

    static let all: [Exercise] = {
        var result: [Exercise] = []
        for hand in HandSide.allCases.reversed() {   // right hand first
            for position in positions {
                for pattern in patterns {
                    if let exercise = patternExercise(id: pattern.id, position: position, hand: hand) { result.append(exercise) }
                }
            }
            for key in scaleKeys { result.append(scaleExercise(key, hand: hand)) }
        }
        return bothHandsExercises + result
    }()

    /// Exercises in a category (optionally one hand) that fit on a keyboard covering `range` (default: 88 keys).
    static func exercises(in category: ExerciseCategory, hand: HandSide? = nil, range: ClosedRange<Int> = 21...108) -> [Exercise] {
        all.filter { $0.category == category && (hand == nil || ($0.hand == hand && !$0.bothHands)) && $0.fits(in: range) }
    }

    static func exercise(id: String) -> Exercise? { all.first { $0.id == id } }
}

// MARK: - Daily practice block

struct PracticeStep: Identifiable {
    enum Kind { case warmUp, scale, drill, song }

    let id = UUID()
    let kind: Kind
    let title: String
    let emoji: String
    let lesson: Lesson
}

struct PracticePlan: Identifiable {
    let id: String
    let title: String
    let steps: [PracticeStep]
    /// Rough time including a few attempts per step.
    var estimatedMinutes: Int {
        let seconds = steps.reduce(0.0) { $0 + $1.lesson.duration / 0.8 + 25 }
        return max(3, Int((seconds / 60).rounded(.up)))
    }
}

enum PracticePlanner {
    /// Adds up recent finger statistics; returns a finger only with real evidence (≥ 5 tries and ≥ 30 % mix-ups).
    static func weakestFinger(from progress: [SessionSummary]) -> Finger? {
        var totals: [Int: FingerStats] = [:]
        for session in progress.prefix(10) {
            for (finger, stats) in session.perFinger {
                var entry = totals[finger] ?? FingerStats()
                entry.attempts += stats.attempts
                entry.errors += stats.errors
                totals[finger] = entry
            }
        }
        return totals
            .filter { $0.value.attempts >= 5 && $0.value.errorRate >= 0.30 }
            .max { $0.value.errorRate < $1.value.errorRate }
            .flatMap { Finger(rawValue: $0.key) }
    }

    /// Seven steps: warm-up (R, L) → scale of the day (R, L, then both hands together) → a drill → a song to finish.
    static func dailyPlan(progress: [SessionSummary], date: Date = Date(), calendar: Calendar = .current,
                          range: ClosedRange<Int> = 21...108) -> PracticePlan {
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let position = ExerciseLibrary.positions[0]
        func step(_ exercise: Exercise?, _ kind: PracticeStep.Kind) -> PracticeStep? {
            exercise.map { PracticeStep(kind: kind, title: $0.title, emoji: $0.emoji, lesson: $0.lesson()) }
        }

        // Only scales that fit on this keyboard in *both* hands.
        let majors = ExerciseLibrary.scaleKeys.filter { key in
            !key.isMinor && key.level <= 2
                && ExerciseLibrary.scaleExercise(key, hand: .right).fits(in: range) && ExerciseLibrary.scaleExercise(key, hand: .left).fits(in: range)
        }
        let scale = (majors.isEmpty ? [ExerciseLibrary.scaleKeys[0]] : majors)[day % max(majors.count, 1)]
        var steps: [PracticeStep] = []
        steps += [step(ExerciseLibrary.patternExercise(id: "walk", position: position, hand: .right), .warmUp)].compactMap { $0 }
        steps += [step(ExerciseLibrary.patternExercise(id: "walk", position: position, hand: .left), .warmUp)].compactMap { $0 }
        steps += [step(ExerciseLibrary.scaleExercise(scale, hand: .right), .scale)].compactMap { $0 }
        steps += [step(ExerciseLibrary.scaleExercise(scale, hand: .left), .scale)].compactMap { $0 }
        let together = ExerciseLibrary.bothHandsScale(scale)
        if together.fits(in: range) { steps += [step(together, .scale)].compactMap { $0 } }

        let drillHand: HandSide = day.isMultiple(of: 2) ? .right : .left
        if let weak = weakestFinger(from: progress) {
            steps.append(PracticeStep(kind: .drill, title: "\(weak.kidName) Practice", emoji: "🎯",
                                      lesson: ExerciseLibrary.fingerFocus(weak, hand: drillHand).lesson()))
        } else {
            let rotation = ["hills", "skips", "chord-climb", "stretch"]
            let id = rotation[day % rotation.count]
            if let drill = step(ExerciseLibrary.patternExercise(id: id, position: position, hand: drillHand), .drill) { steps.append(drill) }
        }

        // Finish with an easy, familiar tune: small range, white keys only, short.
        let songs = SongLibrary.all.filter { song in
            let lesson = song.lesson()
            return lesson.fits(in: range) && (lesson.highestNote ?? 0) - (lesson.lowestNote ?? 0) <= 9
                && !lesson.notes.contains { PianoKeys.isBlack($0.noteNumber) } && lesson.notes.count <= 20
        }
        if !songs.isEmpty {
            let song = songs[day % songs.count]
            steps.append(PracticeStep(kind: .song, title: song.title, emoji: song.emoji, lesson: song.lesson()))
        }
        return PracticePlan(id: "daily-\(calendar.component(.year, from: date))-\(day)", title: "Today's practice", steps: steps)
    }
}
