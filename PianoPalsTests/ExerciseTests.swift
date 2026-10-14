import XCTest
@testable import PianoPals

final class ExerciseLibraryTests: XCTestCase {
    private func fingers(_ exercise: Exercise) -> [Int] { exercise.notes.map(\.finger) }
    private func pitches(_ exercise: Exercise) -> [Int] { exercise.notes.map(\.pitch) }

    // MARK: E1 — size and shape

    func testLibraryIsLargeAndEveryCategoryHasBothHands() {
        XCTAssertGreaterThanOrEqual(ExerciseLibrary.all.count, 40)
        XCTAssertEqual(Set(ExerciseLibrary.all.map(\.id)).count, ExerciseLibrary.all.count, "unique ids")
        for category in ExerciseCategory.allCases {
            for hand in HandSide.allCases {
                XCTAssertFalse(ExerciseLibrary.exercises(in: category, hand: hand).isEmpty, "\(category) \(hand)")
            }
        }
    }

    func testEveryExerciseTurnsIntoAValidLesson() {
        for exercise in ExerciseLibrary.all {
            let lesson = exercise.lesson()
            XCTAssertEqual(lesson.notes.count, exercise.notes.count)
            XCTAssertEqual(lesson.hand, exercise.hand)
            XCTAssertTrue(lesson.notes.allSatisfy { (1...5).contains($0.assignedFinger) }, exercise.id)
            XCTAssertTrue(lesson.notes.allSatisfy { (21...108).contains($0.noteNumber) }, exercise.id)
            XCTAssertTrue(zip(lesson.notes, lesson.notes.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp }, "\(exercise.id) in order")
            XCTAssertLessThan(lesson.duration, 40, "\(exercise.id) should be short")
        }
    }

    // MARK: E2 — textbook scales

    func testCMajorFingeringsAndNotes() throws {
        let right = ExerciseLibrary.scaleExercise(try XCTUnwrap(ExerciseLibrary.scaleKeys.first { $0.name == "C Major" }), hand: .right)
        XCTAssertEqual(pitches(right), [60, 62, 64, 65, 67, 69, 71, 72, 71, 69, 67, 65, 64, 62, 60])
        XCTAssertEqual(fingers(right), [1, 2, 3, 1, 2, 3, 4, 5, 4, 3, 2, 1, 3, 2, 1])
        let left = ExerciseLibrary.scaleExercise(try XCTUnwrap(ExerciseLibrary.scaleKeys.first { $0.name == "C Major" }), hand: .left)
        XCTAssertEqual(pitches(left), [48, 50, 52, 53, 55, 57, 59, 60, 59, 57, 55, 53, 52, 50, 48])
        XCTAssertEqual(fingers(left), [5, 4, 3, 2, 1, 3, 2, 1, 2, 3, 1, 2, 3, 4, 5])
    }

    func testOtherKeysUseTheStandardPatterns() throws {
        func key(_ name: String) throws -> ExerciseLibrary.ScaleKey { try XCTUnwrap(ExerciseLibrary.scaleKeys.first { $0.name == name }) }
        XCTAssertEqual(pitches(ExerciseLibrary.scaleExercise(try key("G Major"), hand: .right)).prefix(8), [67, 69, 71, 72, 74, 76, 78, 79])
        XCTAssertEqual(pitches(ExerciseLibrary.scaleExercise(try key("D Major"), hand: .right)).prefix(8), [62, 64, 66, 67, 69, 71, 73, 74])
        XCTAssertEqual(pitches(ExerciseLibrary.scaleExercise(try key("F Major"), hand: .right)).prefix(8), [65, 67, 69, 70, 72, 74, 76, 77])
        XCTAssertEqual(fingers(ExerciseLibrary.scaleExercise(try key("F Major"), hand: .right)).prefix(8), [1, 2, 3, 4, 1, 2, 3, 4])
        XCTAssertEqual(fingers(ExerciseLibrary.scaleExercise(try key("F Major"), hand: .left)).prefix(8), [5, 4, 3, 2, 1, 3, 2, 1])
        XCTAssertEqual(pitches(ExerciseLibrary.scaleExercise(try key("A Minor"), hand: .right)).prefix(8), [69, 71, 72, 74, 76, 77, 79, 81])
        XCTAssertEqual(pitches(ExerciseLibrary.scaleExercise(try key("E Minor"), hand: .right)).prefix(8), [64, 66, 67, 69, 71, 72, 74, 76])
        XCTAssertEqual(pitches(ExerciseLibrary.scaleExercise(try key("D Minor"), hand: .left)).prefix(8), [50, 52, 53, 55, 57, 58, 60, 62])
        XCTAssertEqual(pitches(ExerciseLibrary.scaleExercise(try key("G Major"), hand: .left)).prefix(8), [43, 45, 47, 48, 50, 52, 54, 55], "high keys start lower")
    }

    func testEveryScaleIsAPerfectOctaveUpAndDownWithMirroredFingering() {
        for hand in HandSide.allCases {
            for key in ExerciseLibrary.scaleKeys {
                let exercise = ExerciseLibrary.scaleExercise(key, hand: hand)
                let p = pitches(exercise), f = fingers(exercise)
                XCTAssertEqual(p.count, 15)
                XCTAssertEqual(p[7] - p[0], 12, "\(exercise.id) spans an octave")
                XCTAssertEqual(Array(p[8...]), Array(p[0..<7].reversed()), "\(exercise.id) comes back down the same notes")
                XCTAssertEqual(Array(f[8...]), Array(f[0..<7].reversed()), "\(exercise.id) mirrored fingering")
                // The first note of the scale is its tonic.
                XCTAssertEqual(p[0] % 12, key.tonic)
                // Major scales have the right shape: whole/half steps W W H W W W H.
                let steps = zip(p[0..<8], p[1..<8]).map { $1 - $0 }
                XCTAssertEqual(steps, key.isMinor ? [2, 1, 2, 2, 1, 2, 2] : [2, 2, 1, 2, 2, 2, 1], exercise.id)
            }
        }
    }

    // MARK: E3 — registers and positions

    func testRightHandIsAboveAndLeftHandBelowMiddleC() {
        for exercise in ExerciseLibrary.all {
            let top = pitches(exercise).max()!, bottom = pitches(exercise).min()!
            switch exercise.hand {
            case .right: XCTAssertGreaterThanOrEqual(bottom, 60, exercise.id)
            case .left: XCTAssertLessThanOrEqual(top, 65, exercise.id); XCTAssertGreaterThanOrEqual(bottom, 36, exercise.id)
            }
        }
    }

    func testFivePositionNotesFollowTheFingers() {
        let c = ExerciseLibrary.positions[0]
        XCTAssertEqual((1...5).map { ExerciseLibrary.note(finger: $0, position: c, hand: .right) }, [60, 62, 64, 65, 67])
        XCTAssertEqual((1...5).map { ExerciseLibrary.note(finger: $0, position: c, hand: .left) }, [55, 53, 52, 50, 48])
        let g = ExerciseLibrary.positions[1]
        XCTAssertEqual((1...5).map { ExerciseLibrary.note(finger: $0, position: g, hand: .right) }, [67, 69, 71, 72, 74])
    }

    func testPatternsUseTheirOwnFingeringAndEndOnALongNote() throws {
        let walk = try XCTUnwrap(ExerciseLibrary.patternExercise(id: "walk", position: ExerciseLibrary.positions[0], hand: .right))
        XCTAssertEqual(fingers(walk), [1, 2, 3, 4, 5, 4, 3, 2, 1])
        XCTAssertEqual(walk.notes.last?.beats, 2)
        XCTAssertNil(ExerciseLibrary.patternExercise(id: "nope", position: ExerciseLibrary.positions[0], hand: .right))
    }

    func testFingerFocusGivesThatFingerHalfTheNotes() {
        for finger in Finger.allCases {
            let exercise = ExerciseLibrary.fingerFocus(finger, hand: .right)
            XCTAssertEqual(exercise.notes.filter { $0.finger == finger.number }.count, 4, "\(finger)")
            XCTAssertEqual(exercise.notes.count, 8)
            XCTAssertTrue(exercise.title.contains(finger.kidName))
        }
    }

    // MARK: E4 — the daily block

    private func summary(perFinger: [Int: FingerStats]) -> SessionSummary {
        var s = SessionStats(); s.perFinger = perFinger
        return SessionSummary(lessonTitle: "x", durationSeconds: 60, notes: 10, stars: 2, stats: s)
    }

    func testDailyPlanIsShortAndUsesBothHandsAScaleAndASong() {
        let plan = PracticePlanner.dailyPlan(progress: [])
        XCTAssertGreaterThanOrEqual(plan.steps.count, 6)
        XCTAssertLessThanOrEqual(plan.estimatedMinutes, 12)
        XCTAssertEqual(Set(plan.steps.map(\.lesson.hand)), [.left, .right])
        XCTAssertTrue(plan.steps.contains { $0.kind == .scale })
        XCTAssertTrue(plan.steps.contains { $0.kind == .song })
        XCTAssertEqual(plan.steps.first?.kind, .warmUp)
        XCTAssertEqual(plan.steps.last?.kind, .song, "finishing with a song is the reward")
    }

    func testDailyPlanChangesFromDayToDay() {
        let calendar = Calendar(identifier: .gregorian)
        let a = PracticePlanner.dailyPlan(progress: [], date: calendar.date(from: DateComponents(year: 2026, month: 3, day: 3))!, calendar: calendar)
        let b = PracticePlanner.dailyPlan(progress: [], date: calendar.date(from: DateComponents(year: 2026, month: 3, day: 4))!, calendar: calendar)
        XCTAssertNotEqual(a.steps.map(\.title), b.steps.map(\.title))
        XCTAssertNotEqual(a.id, b.id)
    }

    func testDailyPlanTargetsTheWeakestFingerWhenThereIsEvidence() {
        let weak = [summary(perFinger: [4: FingerStats(attempts: 6, errors: 4), 2: FingerStats(attempts: 6, errors: 0)])]
        XCTAssertEqual(PracticePlanner.weakestFinger(from: weak), .ring)
        let plan = PracticePlanner.dailyPlan(progress: weak)
        let drill = plan.steps.first { $0.kind == .drill }
        XCTAssertTrue(drill?.title.contains("Orange Diamond") ?? false, "\(drill?.title ?? "no drill")")
        XCTAssertEqual(drill?.lesson.notes.filter { $0.assignedFinger == 4 }.count, 4)
    }

    func testNoWeakFingerWithoutEnoughEvidence() {
        XCTAssertNil(PracticePlanner.weakestFinger(from: []))
        XCTAssertNil(PracticePlanner.weakestFinger(from: [summary(perFinger: [4: FingerStats(attempts: 3, errors: 3)])]))
        XCTAssertNil(PracticePlanner.weakestFinger(from: [summary(perFinger: [4: FingerStats(attempts: 10, errors: 1)])]))
        // Evidence adds up across sessions.
        let two = [summary(perFinger: [3: FingerStats(attempts: 3, errors: 2)]), summary(perFinger: [3: FingerStats(attempts: 3, errors: 2)])]
        XCTAssertEqual(PracticePlanner.weakestFinger(from: two), .middle)
    }

    func testEveryDayOfTheYearProducesAValidPlan() {
        let calendar = Calendar(identifier: .gregorian)
        for day in 1...366 {
            let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: day))!
            let plan = PracticePlanner.dailyPlan(progress: [], date: date, calendar: calendar)
            XCTAssertGreaterThanOrEqual(plan.steps.count, 6, "day \(day)")
            XCTAssertLessThanOrEqual(plan.estimatedMinutes, 12, "day \(day)")
            XCTAssertTrue(plan.steps.allSatisfy { !$0.lesson.notes.isEmpty })
        }
    }
}
