import XCTest
@testable import PianoPals

final class BothHandsExerciseTests: XCTestCase {
    private let together = ExerciseLibrary.bothHandsExercises

    func testThereAreBothHandsExercisesInTheirOwnCategoryAndOnlyUnderTheBothFilter() {
        XCTAssertGreaterThanOrEqual(together.count, 8)
        XCTAssertTrue(together.allSatisfy { $0.bothHands && $0.category == .bothHands })
        XCTAssertEqual(ExerciseLibrary.exercises(in: .bothHands).count, together.count, "no hand filter: all of them")
        XCTAssertTrue(ExerciseLibrary.exercises(in: .bothHands, hand: .right).isEmpty, "a single-hand filter never shows them")
        XCTAssertTrue(ExerciseLibrary.exercises(in: .bothHands, hand: .left).isEmpty)
        XCTAssertEqual(ExerciseCategory.allCases.first, .bothHands, "shown first when the filter is Both")
        XCTAssertEqual(Set(ExerciseLibrary.all.map(\.id)).count, ExerciseLibrary.all.count, "ids stay unique")
    }

    func testEveryNoteHasAHandFingers1To5AndStaysInThatHandsArea() {
        for exercise in together {
            let lesson = exercise.lesson()
            XCTAssertTrue(lesson.isBothHands, exercise.title)
            for note in lesson.notes {
                XCTAssertNotNil(note.hand, exercise.title)
                XCTAssertTrue((1...5).contains(note.assignedFinger), exercise.title)
                switch note.hand {
                case .right?: XCTAssertGreaterThanOrEqual(note.noteNumber, 60, "\(exercise.title): right hand at or above middle C")
                case .left?: XCTAssertLessThanOrEqual(note.noteNumber, 65, "\(exercise.title): left hand below the right"); XCTAssertGreaterThanOrEqual(note.noteNumber, 36)
                case nil: XCTFail("hand missing")
                }
            }
            XCTAssertTrue(exercise.fits(in: 36...96), "\(exercise.title) fits a 61-key keyboard")
        }
    }

    func testTheHandsReallyPlayTogether() {
        let mirror = tryUnwrap(together.first { $0.id == "both-mirror-walk" }).lesson()
        let firstBeat = mirror.notes.filter { $0.timestamp == 0 }
        XCTAssertEqual(Set(firstBeat.compactMap(\.hand)), [.left, .right], "a right and a left note start together")
        XCTAssertEqual(mirror.notes.count, 18, "nine steps, two hands")
        let holds = tryUnwrap(together.first { $0.id == "both-left-holds" }).lesson()
        let held = tryUnwrap(holds.notes.first { $0.hand == .left })
        XCTAssertGreaterThan(held.endTime, 6 * (60 / 68.0), "the left hand note lasts while the right hand plays")
        XCTAssertEqual(holds.notes.filter { $0.hand == .right }.count, 8)
    }

    func testTheTwoHandScaleUsesTheStandardFingeringForEachHand() {
        let c = tryUnwrap(together.first { $0.title == "C Major Together" })
        let up = c.lesson().notes.prefix(16)
        XCTAssertEqual(up.filter { $0.hand == .right }.map(\.assignedFinger), [1, 2, 3, 1, 2, 3, 4, 5])
        XCTAssertEqual(up.filter { $0.hand == .left }.map(\.assignedFinger), [5, 4, 3, 2, 1, 3, 2, 1])
        XCTAssertEqual(up.filter { $0.hand == .right }.map(\.noteNumber).first, 60)
        XCTAssertEqual(up.filter { $0.hand == .left }.map(\.noteNumber).first, 48)
    }

    func testTheDailyPlanIncludesAHandsTogetherStep() {
        let plan = PracticePlanner.dailyPlan(progress: [], range: 36...96)
        XCTAssertEqual(plan.steps.filter { $0.lesson.isBothHands }.count, 1)
        XCTAssertLessThanOrEqual(plan.estimatedMinutes, 12)
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else { XCTFail("missing", file: file, line: line); fatalError("missing") }
        return value
    }
}

@MainActor
final class BothHandsSessionTests: XCTestCase {
    private func session(_ lesson: Lesson, mode: PaceMode = .waitForMe) -> LessonSession {
        let session = LessonSession()
        var now = Date(timeIntervalSince1970: 1_000)
        session.clock = { now }
        session.tempoScale = 1
        session.mode = mode
        session.load(lesson)
        session.start()
        now = now.addingTimeInterval(5)
        return session
    }

    private let mirror = ExerciseLibrary.bothHandsExercises.first { $0.id == "both-mirror-walk" }!.lesson()

    func testBothKeysOfAStepAreWantedAndTheStepNeedsBoth() {
        let session = session(mirror)
        XCTAssertEqual(Set(session.targets.map(\.note.noteNumber)), [60, 55], "the right thumb on C4 and the left thumb on G3")
        XCTAssertEqual(Set(session.targets.compactMap(\.note.hand)), [.left, .right])
        session.handleNoteOn(note: 60, detected: nil)
        XCTAssertEqual(session.targets.map(\.note.noteNumber), [55], "one key down, one to go")
        session.handleNoteOn(note: 55, detected: nil)
        XCTAssertEqual(Set(session.targets.map(\.note.noteNumber)), [62, 53], "then the next step")
    }

    func testAWrongHandIsJudgedAgainstTheNotesOwnHandNotTheLessons() {
        let session = session(mirror)
        session.redoOnWrongFinger = false
        // The left-hand note played with a right hand is a wrong hand; the right-hand note played with a right hand is fine.
        session.handleNoteOn(note: 55, detected: DetectedFinger(finger: .thumb, hand: .right, channel: .overhead, distance: 0))
        XCTAssertEqual(session.noteProgress[mirror.notes.firstIndex { $0.noteNumber == 55 }!], .hit(.wrongHand(played: .right)))
        session.handleNoteOn(note: 60, detected: DetectedFinger(finger: .thumb, hand: .right, channel: .overhead, distance: 0))
        XCTAssertEqual(session.noteProgress[mirror.notes.firstIndex { $0.noteNumber == 60 }!], .hit(.perfect))
    }

    func testOldLessonsWithoutAHandStillWork() throws {
        let data = Data(#"{"timestamp":0,"duration":1,"noteNumber":60,"assignedFinger":1}"#.utf8)
        let note = try JSONDecoder().decode(Note.self, from: data)
        XCTAssertNil(note.hand)
        let encoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(Note(timestamp: 0, duration: 1, noteNumber: 55, assignedFinger: 1, hand: .left)))
        XCTAssertEqual(encoded.hand, .left)
    }
}

final class SongLinkTests: XCTestCase {
    private struct StubFetcher: VideoTitleFetching {
        var result: Result<VideoMetadata, Error>
        func metadata(forVideoID id: String) async throws -> VideoMetadata { try result.get() }
    }

    func testAYouTubeLinkBecomesTheCleanedSongTitle() async {
        let metadata = VideoMetadata(title: "Ode to Joy (Official Video) [HD]", author: "Some Channel")
        let searcher = SongSearcher(titleFetcher: StubFetcher(result: .success(metadata)))
        let resolved = await searcher.resolve("https://youtu.be/dQw4w9WgXcQ")
        guard case .words(let words, let from) = resolved else { return XCTFail("\(resolved)") }
        XCTAssertEqual(from, "Ode to Joy (Official Video) [HD]")
        XCTAssertTrue(words.lowercased().contains("ode to joy"), words)
        XCTAssertFalse(words.lowercased().contains("official"), words)
    }

    func testAnUnreadableLinkSaysSoAndPlainWordsPassThrough() async {
        let searcher = SongSearcher(titleFetcher: StubFetcher(result: .failure(URLError(.notConnectedToInternet))))
        let unreadable = await searcher.resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(unreadable, .unreadable)
        let typed = await searcher.resolve("when we were young")
        XCTAssertEqual(typed, .words("when we were young", from: nil))
    }

    func testFullSongLinksAreBuiltSafely() {
        let song = CatalogSong(id: "1", title: "Rock & Roll #1", artist: "A/B", trackViewURL: URL(string: "https://music.apple.com/x"))
        let youtube = song.youTubeSearchURL?.absoluteString ?? ""
        XCTAssertTrue(youtube.hasPrefix("https://www.youtube.com/results?search_query="), youtube)
        XCTAssertFalse(youtube.contains("Rock & Roll"), "the ampersand is encoded: \(youtube)")
        XCTAssertTrue((song.chordSearchURL?.absoluteString ?? "").contains("piano%20chords"))
        XCTAssertEqual(CatalogParser.iTunes(Data(#"{"results":[{"trackId":1,"trackName":"T","artistName":"A","trackViewUrl":"https://music.apple.com/us/album/t/1"}]}"#.utf8)).first?.trackViewURL?.host, "music.apple.com")
    }
}
