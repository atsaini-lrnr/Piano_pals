import XCTest
@testable import PianoPals

final class PianoGeometryTests: XCTestCase {
    func testBlackAndWhiteKeys() {
        XCTAssertFalse(PianoKeys.isBlack(60))
        XCTAssertTrue(PianoKeys.isBlack(61))
        XCTAssertTrue(PianoKeys.isBlack(70))
        XCTAssertFalse(PianoKeys.isBlack(71))
        XCTAssertEqual((0...11).filter { PianoKeys.isBlack(60 + $0) }.count, 5)
    }

    func testNamesRoundTrip() {
        XCTAssertEqual(PianoKeys.name(60), "C4")
        XCTAssertEqual(PianoKeys.name(61), "C#4")
        XCTAssertEqual(PianoKeys.name(21), "A0")
        for note in 21...108 { XCTAssertEqual(PianoKeys.midiNumber(name: PianoKeys.name(note)), note) }
        XCTAssertEqual(PianoKeys.midiNumber(name: "Bb3"), 58)
        XCTAssertEqual(PianoKeys.midiNumber(name: "c"), 60)
        XCTAssertNil(PianoKeys.midiNumber(name: "H4"))
        XCTAssertNil(PianoKeys.midiNumber(name: "C#x"))
    }

    func testWhiteKeyPositions() {
        XCTAssertEqual(PianoKeys.center(of: 62) - PianoKeys.center(of: 60), 1.0, accuracy: 1e-9)
        XCTAssertEqual(PianoKeys.center(of: 72) - PianoKeys.center(of: 60), 7.0, accuracy: 1e-9)
        // C# sits on the boundary between C and D.
        XCTAssertEqual(PianoKeys.center(of: 61), PianoKeys.center(of: 60) + 0.5, accuracy: 1e-9)
        XCTAssertEqual(PianoKeys.whiteKeyCount(from: 36, to: 84), 29)
        XCTAssertEqual(PianoKeys.whiteKeyCount(from: 21, to: 108), 52)
    }

    func testKeyboardSpanFitsAndStaysInRange() {
        let span = KeyboardSpan.fitting(low: 60, high: 67)
        XCTAssertFalse(PianoKeys.isBlack(span.lowNote))
        XCTAssertFalse(PianoKeys.isBlack(span.highNote))
        XCTAssertLessThanOrEqual(span.lowNote, 60)
        XCTAssertGreaterThanOrEqual(span.highNote, 67)
        XCTAssertGreaterThanOrEqual(span.whiteKeyCount, 8)
        let edge = KeyboardSpan.fitting(low: 21, high: 22)
        XCTAssertGreaterThanOrEqual(edge.lowNote, 21)
        let top = KeyboardSpan.fitting(low: 107, high: 108)
        XCTAssertLessThanOrEqual(top.highNote, 108)
    }
}

final class NoteModelTests: XCTestCase {
    func testDecodesValidNote() throws {
        let json = #"{"timestamp":1.5,"duration":0.5,"noteNumber":64,"assignedFinger":3}"#
        let note = try JSONDecoder().decode(Note.self, from: Data(json.utf8))
        XCTAssertEqual(note, Note(timestamp: 1.5, duration: 0.5, noteNumber: 64, assignedFinger: 3))
        XCTAssertEqual(note.finger, .middle)
    }

    func testRejectsInvalidValues() {
        let bad = [
            #"{"timestamp":1,"duration":1,"noteNumber":64,"assignedFinger":0}"#,
            #"{"timestamp":1,"duration":1,"noteNumber":64,"assignedFinger":6}"#,
            #"{"timestamp":1,"duration":1,"noteNumber":200,"assignedFinger":2}"#,
            #"{"timestamp":-1,"duration":1,"noteNumber":60,"assignedFinger":2}"#,
            #"{"timestamp":1,"duration":0,"noteNumber":60,"assignedFinger":2}"#
        ]
        for json in bad {
            XCTAssertThrowsError(try JSONDecoder().decode(Note.self, from: Data(json.utf8)), json)
        }
    }
}

final class FingeringEngineTests: XCTestCase {
    private func raw(_ names: String) -> [RawNote] { NoteNameParser.parse(names)! }

    func testAscendingFivePositionRightHandIsOneToFive() {
        let notes = FingeringEngine.assign(raw("C4 D4 E4 F4 G4"), hand: .right)
        XCTAssertEqual(notes.map(\.assignedFinger), [1, 2, 3, 4, 5])
    }

    func testDescendingFivePositionRightHandIsFiveToOne() {
        let notes = FingeringEngine.assign(raw("G4 F4 E4 D4 C4"), hand: .right)
        XCTAssertEqual(notes.map(\.assignedFinger), [5, 4, 3, 2, 1])
    }

    func testLeftHandAscendingRunsFiveToOne() {
        let notes = FingeringEngine.assign(raw("C3 D3 E3 F3 G3"), hand: .left)
        XCTAssertEqual(notes.map(\.assignedFinger), [5, 4, 3, 2, 1])
    }

    func testRepeatedNotesKeepTheSameFinger() {
        let notes = FingeringEngine.assign(raw("E4 E4 E4 G4 G4 G4"), hand: .right)
        XCTAssertEqual(notes[0].assignedFinger, notes[1].assignedFinger)
        XCTAssertEqual(notes[1].assignedFinger, notes[2].assignedFinger)
        XCTAssertEqual(notes[3].assignedFinger, notes[4].assignedFinger)
        XCTAssertEqual(notes[4].assignedFinger, notes[5].assignedFinger)
    }

    func testOdeToJoyUsesTheClassicFingering() {
        let song = SongLibrary.all.first { $0.id == "ode-to-joy" }!
        let fingers = song.lesson().notes.map(\.assignedFinger)
        XCTAssertEqual(fingers, [3, 3, 4, 5, 5, 4, 3, 2, 1, 1, 2, 3, 3, 2, 2])
    }

    func testHotCrossBunsPutsThumbOnTheLowestNote() {
        let song = SongLibrary.all.first { $0.id == "hot-cross-buns" }!
        let notes = song.lesson().notes
        let lowest = notes.map(\.noteNumber).min()!
        for note in notes where note.noteNumber == lowest { XCTAssertEqual(note.assignedFinger, 1) }
    }

    func testEveryLibrarySongGetsValidFingers() {
        for song in SongLibrary.all {
            let lesson = song.lesson()
            XCTAssertFalse(lesson.notes.isEmpty, song.title)
            XCTAssertTrue(lesson.notes.allSatisfy { (1...5).contains($0.assignedFinger) }, song.title)
            // Within each song, the same pitch played twice in a row must use the same finger.
            for (a, b) in zip(lesson.notes, lesson.notes.dropFirst()) where a.noteNumber == b.noteNumber {
                XCTAssertEqual(a.assignedFinger, b.assignedFinger, song.title)
            }
        }
    }

    func testFiveFingerSongsNeverShiftPosition() {
        // Songs that fit in a single five-key position: finger = white-key offset from the lowest note + 1.
        for id in ["five-finger-walk", "mary-lamb", "hot-cross-buns", "ode-to-joy", "jingle-bells", "row-boat"] {
            let notes = SongLibrary.all.first { $0.id == id }!.lesson().notes
            let lowestWhite = notes.map { PianoKeys.whiteIndex($0.noteNumber) }.min()!
            let highestWhite = notes.map { PianoKeys.whiteIndex($0.noteNumber) }.max()!
            guard highestWhite - lowestWhite <= 4 else { continue }
            let thumbKey = notes.first { $0.assignedFinger == 1 }.map { PianoKeys.whiteIndex($0.noteNumber) }
            for note in notes {
                let thumb = thumbKey ?? lowestWhite
                XCTAssertEqual(PianoKeys.whiteIndex(note.noteNumber) - thumb + 1, note.assignedFinger, "\(id) \(PianoKeys.name(note.noteNumber))")
            }
        }
    }

    func testTwinkleCoversSixKeysWithAHandShift() {
        let notes = SongLibrary.all.first { $0.id == "twinkle" }!.lesson().notes
        XCTAssertEqual(notes.count, 14)
        XCTAssertTrue(notes.allSatisfy { (1...5).contains($0.assignedFinger) })
    }

    func testThumbAvoidsBlackKeysWhenPossible() {
        let notes = FingeringEngine.assign(raw("C4 C#4 D4 D#4 E4"), hand: .right)
        XCTAssertNotEqual(notes[1].assignedFinger, 1)
        XCTAssertNotEqual(notes[3].assignedFinger, 1)
    }

    func testChordsAreReducedToTheMelody() {
        let chord = [RawNote(pitch: 60, start: 0, duration: 1), RawNote(pitch: 64, start: 0, duration: 1), RawNote(pitch: 67, start: 0, duration: 1),
                     RawNote(pitch: 65, start: 1, duration: 1)]
        XCTAssertEqual(FingeringEngine.assign(chord, hand: .right).map(\.noteNumber), [67, 65])
        XCTAssertEqual(FingeringEngine.assign(chord, hand: .left).map(\.noteNumber), [60, 65])
    }

    func testEmptyInput() {
        XCTAssertTrue(FingeringEngine.assign([], hand: .right).isEmpty)
    }

    func testLongRandomPhrasesAlwaysProduceValidFingers() {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<50 {
            let pitches = (0..<64).map { _ in Int.random(in: 40...84, using: &generator) }
            let raw = pitches.enumerated().map { RawNote(pitch: $1, start: Double($0) * 0.5, duration: 0.5) }
            for hand in HandSide.allCases {
                let fingers = FingeringEngine.assign(raw, hand: hand).map(\.assignedFinger)
                XCTAssertEqual(fingers.count, 64)
                XCTAssertTrue(fingers.allSatisfy { (1...5).contains($0) })
            }
        }
    }
}

final class ParserTests: XCTestCase {
    func testNoteNameParserTimingAndRests() {
        let notes = NoteNameParser.parse("C4 D4:2 R:1 E4:0.5", bpm: 60)!
        XCTAssertEqual(notes.map(\.pitch), [60, 62, 64])
        XCTAssertEqual(notes.map(\.start), [0, 1, 4])
        XCTAssertEqual(notes.map(\.duration), [1, 2, 0.5])
    }

    func testNoteNameParserRejectsGarbage() {
        XCTAssertNil(NoteNameParser.parse("C4 hello E4"))
        XCTAssertNil(NoteNameParser.parse("C4:-1"))
        XCTAssertNil(NoteNameParser.parse("C4:abc"))
        XCTAssertNil(NoteNameParser.parse(""))
        XCTAssertNil(NoteNameParser.parse("R R R"))
    }

    func testLooksLikeNotationDoesNotCatchTitles() {
        XCTAssertTrue(NoteNameParser.looksLikeNotation("C4 D4 E4 F4"))
        XCTAssertFalse(NoteNameParser.looksLikeNotation("Ode to Joy"))
        XCTAssertFalse(NoteNameParser.looksLikeNotation("A B C"))      // no octave digit: could be a title
        XCTAssertFalse(NoteNameParser.looksLikeNotation("C4 D4"))      // too short
    }

    /// Builds a tiny format-0 SMF: C4 (480 ticks), rest 480, E4 (240) at 120 bpm, 480 ticks per quarter.
    private func makeMIDIFile(tempoMicros: Int = 500_000) -> Data {
        var track: [UInt8] = []
        track += [0x00, 0xFF, 0x51, 0x03, UInt8((tempoMicros >> 16) & 0xFF), UInt8((tempoMicros >> 8) & 0xFF), UInt8(tempoMicros & 0xFF)]
        track += [0x00, 0x90, 60, 100]
        track += [0x83, 0x60, 0x80, 60, 0]         // delta 480 (VLQ 0x83 0x60)
        track += [0x83, 0x60, 0x90, 64, 100]       // delta 480 → note on E4
        track += [0x81, 0x70, 0x90, 64, 0]         // delta 240 → note-on velocity 0 (= off), running status not used
        track += [0x00, 0xFF, 0x2F, 0x00]
        var data = Data("MThd".utf8)
        data.append(contentsOf: [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0])
        data.append(Data("MTrk".utf8))
        let length = track.count
        data.append(contentsOf: [UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        data.append(contentsOf: track)
        return data
    }

    func testStandardMIDIFileParsing() throws {
        let notes = try StandardMIDIFile.parse(makeMIDIFile())
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].pitch, 60)
        XCTAssertEqual(notes[0].start, 0, accuracy: 1e-6)
        XCTAssertEqual(notes[0].duration, 0.5, accuracy: 1e-6)
        XCTAssertEqual(notes[1].pitch, 64)
        XCTAssertEqual(notes[1].start, 1.0, accuracy: 1e-6)
        XCTAssertEqual(notes[1].duration, 0.25, accuracy: 1e-6)
    }

    func testStandardMIDIFileHonoursTempo() throws {
        let notes = try StandardMIDIFile.parse(makeMIDIFile(tempoMicros: 1_000_000)) // 60 bpm → twice as slow
        XCTAssertEqual(notes[1].start, 2.0, accuracy: 1e-6)
    }

    func testStandardMIDIFileErrors() {
        XCTAssertThrowsError(try StandardMIDIFile.parse(Data("nope".utf8)))
        XCTAssertThrowsError(try StandardMIDIFile.parse(Data(makeMIDIFile().prefix(20))))
    }
}

final class ClassifierAndServiceTests: XCTestCase {
    func testYouTubeLinksInAllCommonForms() {
        let id = "dQw4w9WgXcQ"
        let links = [
            "https://www.youtube.com/watch?v=\(id)", "https://youtu.be/\(id)", "https://m.youtube.com/watch?v=\(id)&t=10s",
            "https://www.youtube.com/shorts/\(id)", "https://www.youtube.com/embed/\(id)", "https://music.youtube.com/watch?v=\(id)&list=abc",
            "check this out https://youtu.be/\(id)?si=xyz please"
        ]
        for link in links {
            XCTAssertEqual(LessonInputClassifier.classify(link), .youTube(videoID: id), link)
        }
        XCTAssertNotEqual(LessonInputClassifier.classify("https://www.youtube.com/watch?v=short"), .youTube(videoID: "short"))
    }

    func testMusicShareAndTitleSearch() {
        let share = "\u{201C}Ode to Joy\u{201D} by Beethoven https://music.apple.com/us/album/ode-to-joy/123"
        guard case .musicShare(let title, let artist, let url) = LessonInputClassifier.classify(share) else { return XCTFail("not a share") }
        XCTAssertEqual(title, "Ode to Joy")
        XCTAssertEqual(artist, "Beethoven")
        XCTAssertEqual(url?.host, "music.apple.com")

        XCTAssertEqual(LessonInputClassifier.classify("Twinkle Twinkle - Mozart"), .titleSearch(title: "Twinkle Twinkle", composer: "Mozart"))
        XCTAssertEqual(LessonInputClassifier.classify("Hot Cross Buns"), .titleSearch(title: "Hot Cross Buns", composer: nil))
        XCTAssertNil(LessonInputClassifier.classify("   \n "))
    }

    func testRawNotesClassification() {
        guard case .rawNotes(let notes) = LessonInputClassifier.classify("C4 D4 E4 F4 G4") else { return XCTFail("expected raw notes") }
        XCTAssertEqual(notes.count, 5)
    }

    // MARK: Service

    private struct StubFetcher: VideoTitleFetching {
        var result: Result<VideoMetadata, Error>
        func metadata(forVideoID id: String) async throws -> VideoMetadata { try result.get() }
    }

    private struct FixedTransport: LessonTransport {
        let data: Data
        func perform(_ request: LessonCloudRequest) async throws -> Data { data }
    }

    private struct NotFoundTransport: LessonTransport {
        func perform(_ request: LessonCloudRequest) async throws -> Data { throw LessonServiceError.notFound }
    }

    private struct HangingTransport: LessonTransport {
        func perform(_ request: LessonCloudRequest) async throws -> Data {
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
    }

    private struct StubCleaner: TitleCleaning {
        var answer: String?
        var delay: Duration = .zero
        func cleanedTitle(from raw: String) async -> String? {
            try? await Task.sleep(for: delay)
            return answer
        }
    }

    private func service(transport: LessonTransport? = nil, fetcher: VideoTitleFetching = StubFetcher(result: .failure(URLError(.notConnectedToInternet))),
                         timeout: Duration = .seconds(2), cleaner: TitleCleaning? = nil, cleanerTimeout: Duration = .seconds(3)) -> AILessonGeneratorService {
        AILessonGeneratorService(transport: transport, library: SongLibrary.all, titleFetcher: fetcher, titleCleaner: cleaner,
                                 cleanerTimeout: cleanerTimeout, timeout: timeout)
    }

    func testTheOnDeviceModelIsOnlyUsedWhenRulesFail() async throws {
        // Rules know this one: the (wrong) cleaner answer must never be consulted.
        let outcome = try await service(cleaner: StubCleaner(answer: "Hot Cross Buns")).generateLesson(from: "Ode to Joy")
        guard case .lesson(let lesson, _) = outcome else { return XCTFail() }
        XCTAssertEqual(lesson.title, "Ode to Joy")
        // Rules can't read this, the model can.
        let messy = try await service(cleaner: StubCleaner(answer: "Ode to Joy")).generateLesson(from: "Fröhliche Melodie Nr 9 finale")
        guard case .lesson(let found, _) = messy else { return XCTFail("the model's cleaned title should be matched") }
        XCTAssertEqual(found.title, "Ode to Joy")
    }

    /// An operation that ignores cancellation, like a system model call that can't be interrupted.
    private struct UncancellableCleaner: TitleCleaning {
        func cleanedTitle(from raw: String) async -> String? {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume(returning: "Ode to Joy") }
            }
        }
    }

    func testTimeoutReturnsEvenWhenTheOperationIgnoresCancellation() async throws {
        let start = Date()
        let outcome = try await service(cleaner: UncancellableCleaner(), cleanerTimeout: .milliseconds(200)).generateLesson(from: "Fröhliche Melodie Nr 9 finale")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "must not wait for a model call that can't be cancelled")
        guard case .notFound = outcome else { return XCTFail("the late answer is discarded") }
    }

    func testWithTimeoutBasics() async throws {
        let quick: Int = try await withTimeout(.seconds(2)) { 42 }
        XCTAssertEqual(quick, 42)
        do {
            let _: Int = try await withTimeout(.milliseconds(50)) { try await Task.sleep(for: .seconds(10)); return 1 }
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? LessonServiceError, .timedOut)
        }
        do {
            let _: Int = try await withTimeout(.seconds(2)) { throw LessonServiceError.notFound }
            XCTFail("should rethrow")
        } catch {
            XCTAssertEqual(error as? LessonServiceError, .notFound)
        }
    }

    func testASlowOnDeviceModelNeverBlocksTheLesson() async throws {
        let start = Date()
        let outcome = try await service(cleaner: StubCleaner(answer: "Ode to Joy", delay: .seconds(30)), cleanerTimeout: .milliseconds(100))
            .generateLesson(from: "Fröhliche Melodie Nr 9 finale")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "gave up on the model quickly")
        guard case .notFound = outcome else { return XCTFail("with no answer in time, rules decide: not found") }
        // A known song doesn't even wait for it.
        let known = Date()
        _ = try await service(cleaner: StubCleaner(answer: nil, delay: .seconds(30))).generateLesson(from: "Twinkle Twinkle")
        XCTAssertLessThan(Date().timeIntervalSince(known), 1)
    }

    func testTitleSearchFindsABuiltInSongOffline() async throws {
        let outcome = try await service().generateLesson(from: "Ode to Joy by Beethoven")
        guard case .lesson(let lesson, let origin) = outcome else { return XCTFail("expected a lesson") }
        XCTAssertEqual(lesson.title, "Ode to Joy")
        XCTAssertEqual(lesson.notes.count, 15)
        XCTAssertEqual(lesson.source, .library)
        guard case .library(let score) = origin else { return XCTFail("expected library origin") }
        XCTAssertGreaterThan(score, 0.8)
    }

    func testYouTubeLinkUsesTheVideoTitle() async throws {
        let fetcher = StubFetcher(result: .success(VideoMetadata(title: "Hot Cross Buns | Easy Piano Tutorial (Official Video)", author: "Some Channel")))
        let outcome = try await service(fetcher: fetcher).generateLesson(from: "https://youtu.be/dQw4w9WgXcQ")
        guard case .lesson(let lesson, _) = outcome else { return XCTFail("expected a lesson") }
        XCTAssertEqual(lesson.title, "Hot Cross Buns")
    }

    func testYouTubeWithUnknownSongIsHonestAboutIt() async throws {
        let fetcher = StubFetcher(result: .success(VideoMetadata(title: "Bohemian Rhapsody (Official Video Remastered)", author: "Queen Official")))
        let outcome = try await service(fetcher: fetcher).generateLesson(from: "https://youtu.be/dQw4w9WgXcQ")
        guard case .notFound(let info) = outcome else { return XCTFail("must not invent a song") }
        XCTAssertNotNil(info.resolvedTitle)
        XCTAssertTrue(info.reason.contains("isn't in the free song library"))
    }

    func testOfflineYouTubeLookupFailsGracefully() async throws {
        let outcome = try await service().generateLesson(from: "https://youtu.be/dQw4w9WgXcQ")
        guard case .notFound(let info) = outcome else { return XCTFail("expected not found") }
        XCTAssertNil(info.resolvedTitle)
        XCTAssertFalse(info.reason.isEmpty)
    }

    func testUnknownTitleOffersCloseSuggestionsButNoInventedTune() async throws {
        let outcome = try await service().generateLesson(from: "Jingle Bell Rock")
        guard case .notFound(let info) = outcome else { return XCTFail("a different song must not be shown") }
        XCTAssertTrue(info.suggestions.contains { $0.id == "jingle-bells" }, "the similar built-in song is offered as a suggestion")
    }

    func testComposerOnlyQueryIsASuggestionNotAMatch() async throws {
        let outcome = try await service().generateLesson(from: "Beethoven")
        guard case .notFound(let info) = outcome else { return XCTFail("composer-only is ambiguous") }
        XCTAssertEqual(Set(info.suggestions.map(\.id)), ["ode-to-joy", "fur-elise"])
    }

    func testExplicitPracticeTuneIsDeterministicAndLabelled() {
        let service = service()
        let a = service.practiceTune(for: "Bohemian Rhapsody", hand: .right)
        let b = service.practiceTune(for: "Bohemian Rhapsody", hand: .right)
        let c = service.practiceTune(for: "Something Else", hand: .right)
        XCTAssertEqual(a.notes, b.notes)
        XCTAssertNotEqual(a.notes, c.notes)
        XCTAssertTrue(a.title.hasPrefix("Practice tune"))
        XCTAssertTrue(a.sourceDescription.contains("wasn't found") || a.sourceDescription.contains("practice tune"))
    }

    func testCloudIsOnlyAskedAfterTheIndexMisses() async throws {
        let body = #"{"title":"Custom","composer":"Me","tempoBPM":70,"notes":[{"timestamp":0,"duration":1,"noteNumber":60,"assignedFinger":1},{"timestamp":1,"duration":1,"noteNumber":62,"assignedFinger":2}]}"#
        let svc = service(transport: FixedTransport(data: Data(body.utf8)))
        // Known song: index wins (the transport would have returned "Custom").
        guard case .lesson(let known, _) = try await svc.generateLesson(from: "Twinkle Twinkle") else { return XCTFail() }
        XCTAssertEqual(known.title, "Twinkle Twinkle")
        // Unknown song: the endpoint is asked.
        guard case .lesson(let custom, let origin) = try await svc.generateLesson(from: "Some Obscure Tune") else { return XCTFail("endpoint should answer") }
        XCTAssertEqual(custom.title, "Custom")
        XCTAssertEqual(origin, .cloud)
    }

    func testBadCloudResponsesBecomeNotFound() async throws {
        let responses = [
            "not json", #"{"title":"x","notes":[]}"#,
            #"{"title":"x","notes":[{"timestamp":0,"duration":1,"noteNumber":60,"assignedFinger":9}]}"#,
            #"{"title":"x","notes":[{"timestamp":0,"duration":1,"noteNumber":10,"assignedFinger":2}]}"#
        ]
        for body in responses {
            let outcome = try await service(transport: FixedTransport(data: Data(body.utf8))).generateLesson(from: "Some Obscure Tune")
            guard case .notFound = outcome else { return XCTFail("bad payload must not become a lesson: \(body)") }
        }
        guard case .notFound = try await service(transport: NotFoundTransport()).generateLesson(from: "Some Obscure Tune") else { return XCTFail() }
    }

    func testCloudTimeoutBecomesNotFound() async throws {
        let outcome = try await service(transport: HangingTransport(), timeout: .milliseconds(50)).generateLesson(from: "Some Obscure Tune")
        guard case .notFound(let info) = outcome else { return XCTFail("expected not found") }
        XCTAssertTrue(info.reason.contains("too long"))
    }

    func testEmptyInputThrows() async {
        do {
            _ = try await service().generateLesson(from: "   ")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? LessonServiceError, .emptyInput)
        }
    }

    func testRawNotesNeverTouchTheNetwork() async throws {
        let outcome = try await service(transport: NotFoundTransport()).generateLesson(from: "C4 D4 E4 F4 G4")
        guard case .lesson(let lesson, let origin) = outcome else { return XCTFail() }
        XCTAssertEqual(origin, .notation)
        XCTAssertEqual(lesson.notes.map(\.assignedFinger), [1, 2, 3, 4, 5])
    }

    func testOEmbedRequestAndDecoding() throws {
        let url = try XCTUnwrap(YouTubeOEmbedFetcher.requestURL(forVideoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(url.host, "www.youtube.com")
        XCTAssertEqual(url.path, "/oembed")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "url" }?.value, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(query.first { $0.name == "format" }?.value, "json")
        // Only a public URL is sent: no audio, no device identifiers.
        XCTAssertEqual(query.count, 2)

        let meta = try YouTubeOEmbedFetcher.decode(Data(#"{"title":"  Twinkle  ","author_name":"Chan","type":"video"}"#.utf8))
        XCTAssertEqual(meta, VideoMetadata(title: "Twinkle", author: "Chan"))
        XCTAssertThrowsError(try YouTubeOEmbedFetcher.decode(Data(#"{"title":" "}"#.utf8)))
        XCTAssertThrowsError(try YouTubeOEmbedFetcher.decode(Data("nope".utf8)))
    }

    func testLocalScaleAndPracticeTune() {
        let engine = LocalLessonEngine()
        let scale = engine.fiveFingerScale()
        XCTAssertEqual(scale.notes.map(\.assignedFinger), [1, 2, 3, 4, 5, 4, 3, 2, 1])
        let tune = engine.practiceTune(seed: "x", label: "x", hand: .left)
        XCTAssertTrue(tune.notes.allSatisfy { (48...55).contains($0.noteNumber) })
    }
}
