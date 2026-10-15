import XCTest
@testable import PianoPals

@MainActor
private final class StubVoice: VoiceIO {
    var spoken: [String] = []
    var answers: [VoiceAnswer?] = []
    var listens = 0
    /// True: `listen` waits until the task is cancelled (a child who says nothing).
    var hang = false

    func speak(_ text: String) async { spoken.append(text) }

    func listen(for seconds: TimeInterval) async -> VoiceAnswer? {
        listens += 1
        if hang { try? await Task.sleep(for: .seconds(60)); return nil }
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

final class VoiceAnswerTests: XCTestCase {
    func testWordsMapToAgainOrNext() {
        for text in ["again", "play it again", "Again please", "repeat", "yes", "one more time same", "yeah"] { XCTAssertEqual(VoiceAnswer.parse(text), .again, text) }
        for text in ["new song", "next", "a different one", "no", "more songs", "skip", "another song"] { XCTAssertEqual(VoiceAnswer.parse(text), .next, text) }
        for text in ["", "banana", "hello panda"] { XCTAssertNil(VoiceAnswer.parse(text), text) }
        XCTAssertEqual(VoiceAnswer.parse("play it again or a new song"), .again, "the first option in the question wins")
    }
}

@MainActor
final class FinishPromptTests: XCTestCase {
    private func run(_ voice: StubVoice) async -> VoiceAnswer? {
        let prompt = FinishPrompt()
        let done = expectation(description: "answered")
        var result: VoiceAnswer?
        prompt.start(io: voice) { result = $0; done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return result
    }

    func testAnAnswerInTheFirstRoundIsActedOnAfterOneQuestion() async {
        let voice = StubVoice()
        voice.answers = [.again]
        let answer = await run(voice)
        XCTAssertEqual(answer, .again)
        XCTAssertEqual(voice.spoken, [FinishPrompt.questions[0]])
    }

    func testSilenceAsksOnceMoreThenMovesToTheNextSong() async {
        let voice = StubVoice()
        let answer = await run(voice)
        XCTAssertEqual(answer, .next)
        XCTAssertEqual(voice.spoken, FinishPrompt.questions, "asked twice, with a different second question")
        XCTAssertNotEqual(FinishPrompt.questions[0], FinishPrompt.questions[1])
        XCTAssertEqual(voice.listens, 2)
    }

    func testAnAnswerInTheSecondRoundCounts() async {
        let voice = StubVoice()
        voice.answers = [nil, .next]
        let answer = await run(voice)
        XCTAssertEqual(answer, .next)
        XCTAssertEqual(voice.spoken.count, 2)
    }

    func testAKeyOnTheRealKeyboardAnswersAgainWhileListening() async {
        let voice = StubVoice()
        voice.hang = true
        let prompt = FinishPrompt()
        var answers: [VoiceAnswer] = []
        prompt.start(io: voice) { answers.append($0) }
        for _ in 0..<100 where prompt.phase != .listening(round: 1) { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(prompt.phase, .listening(round: 1))
        XCTAssertEqual(prompt.text, FinishPrompt.questions[0], "the question is shown in words too")
        prompt.keyPressed()
        prompt.keyPressed()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(answers, [.again], "answered once")
        XCTAssertEqual(prompt.phase, .idle)
    }

    func testCancellingStopsEverythingAndAnswersNothing() async {
        let voice = StubVoice()
        voice.hang = true
        let prompt = FinishPrompt()
        var called = false
        prompt.start(io: voice) { _ in called = true }
        for _ in 0..<100 where prompt.phase != .listening(round: 1) { try? await Task.sleep(for: .milliseconds(20)) }
        prompt.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(called)
        XCTAssertFalse(prompt.isActive)
        XCTAssertNil(prompt.text)
    }
}

@MainActor
final class KeyboardRemoteTests: XCTestCase {
    private func makeApp() throws -> AppModel {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "remote-\(UUID().uuidString)"))
        return AppModel(settings: AppSettings(defaults: suite))
    }

    private func lesson(_ title: String, _ notation: String = "C4 D4") -> Lesson {
        Lesson(title: title, hand: .right, notes: FingeringEngine.assign(NoteNameParser.parse(notation, bpm: 60)!, hand: .right), source: .library)
    }

    private func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testAnyKeyOnTheRealKeyboardStartsTheSongAndIsNotAWrongNote() async throws {
        let app = try makeApp()
        app.open(lesson("A"))
        XCTAssertEqual(app.screen, .lesson)
        XCTAssertEqual(app.session.phase, .ready)
        app.midi.injectOnScreen(note: 90, isOn: true, origin: .hardware)       // a key that is not even in the song
        await wait { app.session.phase == .playing }
        XCTAssertEqual(app.session.phase, .playing)
        XCTAssertEqual(app.session.consecutiveWrong, 0, "the first press is not a note")
        XCTAssertEqual(app.session.noteProgress, [.pending, .pending])
    }

    func testOnScreenKeysDoNotStartTheSong() async throws {
        let app = try makeApp()
        app.open(lesson("A"))
        app.midi.injectOnScreen(note: 60, isOn: true)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(app.session.phase, .ready)
    }

    func testFinishingAsksByVoiceAndAKeyPlaysItAgain() async throws {
        let app = try makeApp()
        let voice = StubVoice()
        voice.hang = true
        app.voice = voice
        app.open(lesson("A"))
        app.startLesson()
        app.session.handleNoteOn(note: 60, detected: nil)
        app.session.handleNoteOn(note: 62, detected: nil)
        XCTAssertEqual(app.session.phase, .finished)
        await wait { app.finishPrompt.phase == .listening(round: 1) }
        XCTAssertEqual(app.finishPrompt.phase, .listening(round: 1))
        app.midi.injectOnScreen(note: 70, isOn: true, origin: .hardware)
        await wait { app.session.phase == .playing }
        XCTAssertEqual(app.session.phase, .playing, "played again")
        XCTAssertFalse(app.finishPrompt.isActive)
    }

    func testVoiceOffMeansNoQuestion() async throws {
        let app = try makeApp()
        app.settings.voicePrompts = false
        let voice = StubVoice()
        app.voice = voice
        app.open(lesson("A"))
        app.startLesson()
        app.session.handleNoteOn(note: 60, detected: nil)
        app.session.handleNoteOn(note: 62, detected: nil)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(voice.spoken.isEmpty)
        XCTAssertFalse(app.finishPrompt.isActive)
    }

    func testNextMovesToTheNextSongReadyForAKey() throws {
        let app = try makeApp()
        app.add(lesson("B", "E4 F4"))
        app.add(lesson("A"))                         // newest first: A, B, then the built-in songs
        let order = app.songs.map(\.title)
        XCTAssertEqual(Array(order.prefix(2)), ["A", "B"])
        app.open(app.songs[0])
        app.handleFinishAnswer(.next)
        XCTAssertEqual(app.session.lesson?.title, "B")
        XCTAssertEqual(app.session.phase, .ready, "waits for a key to start")
        app.open(app.songs.last!)
        app.handleFinishAnswer(.next)
        XCTAssertEqual(app.session.lesson?.title, "A", "wraps round to the first song")
    }
}
