import Combine
import XCTest
@testable import PianoPals

@MainActor
final class LessonSessionTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000)
    private var cancellables: Set<AnyCancellable> = []

    private func lesson(_ notation: String = "C4 D4 E4", hand: HandSide = .right) -> Lesson {
        Lesson(title: "Test", hand: hand, notes: FingeringEngine.assign(NoteNameParser.parse(notation, bpm: 60)!, hand: hand), source: .library)
    }

    private func makeSession(_ lesson: Lesson, mode: PaceMode = .waitForMe) -> LessonSession {
        let session = LessonSession()
        session.clock = { [unowned self] in self.now }
        session.tempoScale = 1
        session.mode = mode
        session.load(lesson)
        return session
    }

    private func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    private func collect(_ session: LessonSession) -> () -> [SessionEvent] {
        var events: [SessionEvent] = []
        session.events.sink { events.append($0) }.store(in: &cancellables)
        return { events }
    }

    func testLoadingPreparesReadyState() {
        let session = makeSession(lesson())
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.noteProgress, [.pending, .pending, .pending])
        XCTAssertEqual(session.targets.map(\.note.noteNumber), [60])
        XCTAssertEqual(session.songTime(at: now), -LessonSession.leadIn)
    }

    func testWaitModeHoldsTheClockAtTheNextNote() {
        let session = makeSession(lesson())
        session.start()
        advance(1)
        XCTAssertEqual(session.songTime(at: now), -1, accuracy: 1e-6)
        advance(30)
        XCTAssertEqual(session.songTime(at: now), 0, accuracy: 1e-6, "the first note waits at the keys")
    }

    func testCorrectNotesAdvanceAndFinishWithStars() {
        let session = makeSession(lesson())
        let events = collect(session)
        session.start()
        advance(5)
        let finger1 = DetectedFinger(finger: .thumb, hand: .right, channel: .overhead, distance: 0)
        session.handleNoteOn(note: 60, detected: finger1)
        XCTAssertEqual(session.noteProgress[0], .hit(.perfect))
        XCTAssertEqual(session.targets.map(\.note.noteNumber), [62])
        advance(5)
        session.handleNoteOn(note: 62, detected: nil)
        XCTAssertEqual(session.noteProgress[1], .hit(.fingerUnverified))
        advance(5)
        session.handleNoteOn(note: 64, detected: DetectedFinger(finger: .middle, hand: .right, channel: .overhead, distance: 0))
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.stars, 3)
        XCTAssertEqual(events().last, .finished(stars: 3))
        XCTAssertEqual(events().filter { if case .noteHit = $0 { return true } else { return false } }.count, 3)
    }

    func testWrongKeyNeverPenalisesAndGivesAHintAfterTwoTries() {
        let session = makeSession(lesson())
        let events = collect(session)
        session.start()
        advance(5)
        session.handleNoteOn(note: 70, detected: nil)
        XCTAssertEqual(session.noteProgress, [.pending, .pending, .pending])
        XCTAssertEqual(session.keyFeedback[70]?.kind, .gentle)
        XCTAssertNil(session.keyFeedback[60])
        session.handleNoteOn(note: 71, detected: nil)
        XCTAssertEqual(session.keyFeedback[60]?.kind, .hint, "after two wrong tries the right key softly glows")
        XCTAssertEqual(events().filter { if case .gentleMiss = $0 { return true } else { return false } }.count, 2)
        // …and the right key still works afterwards.
        session.handleNoteOn(note: 60, detected: nil)
        XCTAssertEqual(session.noteProgress[0], .hit(.fingerUnverified))
        XCTAssertEqual(session.consecutiveWrong, 0)
        XCTAssertEqual(session.keyFeedback[60]?.kind, .success)
    }

    func testWrongFingerStillAdvancesButIsReported() {
        let session = makeSession(lesson())
        let events = collect(session)
        session.start()
        advance(5)
        session.handleNoteOn(note: 60, detected: DetectedFinger(finger: .ring, hand: .right, channel: .overhead, distance: 0.1))
        XCTAssertEqual(session.noteProgress[0], .hit(.fingerOff(played: .ring)))
        XCTAssertTrue(events().contains(.noteHit(index: 0, note: session.lesson!.notes[0], quality: .fingerOff(played: .ring))))
        XCTAssertEqual(session.targets.map(\.note.noteNumber), [62])
    }

    func testWrongHandCountsAsAFingerMismatch() {
        let session = makeSession(lesson())
        session.start()
        advance(5)
        session.handleNoteOn(note: 60, detected: DetectedFinger(finger: .thumb, hand: .left, channel: .overhead, distance: 0))
        XCTAssertEqual(session.noteProgress[0], .hit(.wrongHand(played: .left)))
    }

    func testStarsReflectFingerAccuracyButAlwaysAtLeastOne() {
        let session = makeSession(lesson("C4 D4 E4 F4"))
        session.start()
        let wrong = DetectedFinger(finger: .pinky, hand: .right, channel: .overhead, distance: 0)
        for note in [60, 62, 64, 65] {
            advance(5)
            session.handleNoteOn(note: note, detected: wrong)
        }
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.stars, 2, "right keys with the wrong finger still earn a generous two stars")

        let mixed = makeSession(lesson("C4 D4 E4 F4"))
        mixed.start()
        let right = [Finger.thumb, .index, .middle, .ring]
        for (index, note) in [60, 62, 64, 65].enumerated() {
            advance(5)
            mixed.handleNoteOn(note: note, detected: DetectedFinger(finger: index < 2 ? right[index] : .pinky, hand: .right, channel: .overhead, distance: 0))
        }
        XCTAssertEqual(mixed.stars, 2)
    }

    func testKeysWhileNotPlayingAreFreePlay() {
        let session = makeSession(lesson())
        let events = collect(session)
        session.handleNoteOn(note: 60, detected: nil)
        XCTAssertEqual(events(), [.freePlay(note: 60)])
        XCTAssertEqual(session.noteProgress[0], .pending)
    }

    func testPauseFreezesTheClock() {
        let session = makeSession(lesson("C4:1 R:5 D4"))
        session.start()
        advance(1)
        session.pause()
        let frozen = session.songTime(at: now)
        advance(10)
        XCTAssertEqual(session.songTime(at: now), frozen)
        session.resume()
        advance(0.5)
        XCTAssertEqual(session.songTime(at: now), frozen + 0.5, accuracy: 1e-6)
    }

    func testTempoScaleChangesSpeedWithoutJumping() {
        let session = makeSession(lesson("C4 D4"))
        session.start()
        advance(1)
        let before = session.songTime(at: now)
        session.tempoScale = 0.5
        XCTAssertEqual(session.songTime(at: now), before, accuracy: 1e-6)
        advance(1)
        XCTAssertEqual(session.songTime(at: now), before + 0.5, accuracy: 1e-6)
    }

    func testPlayAlongMarksMissedNotesGentlyAndStillFinishes() {
        let session = makeSession(lesson("C4 D4 E4"), mode: .playAlong)
        session.start()
        advance(LessonSession.leadIn + 0.1)
        session.handleNoteOn(note: 60, detected: nil)
        XCTAssertEqual(session.noteProgress[0], .hit(.fingerUnverified))
        // Never touch the keys again: the song carries on and the remaining notes simply fade.
        advance(10)
        session.tick()
        XCTAssertEqual(session.noteProgress[1], .missed)
        XCTAssertEqual(session.noteProgress[2], .missed)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.stars, 1, "finishing always earns a star, even when most notes faded")
    }

    func testPlayAlongReportsEachSkippedNoteExactlyOnce() {
        let session = makeSession(lesson("C4 D4"), mode: .playAlong)
        let events = collect(session)
        session.start()
        advance(30)
        session.tick()
        session.tick()
        let missed = events().filter { if case .noteMissed = $0 { return true } else { return false } }
        XCTAssertEqual(missed.count, 2)
    }

    func testShowHintGlowsTheWaitingKey() {
        let session = makeSession(lesson())
        session.start()
        advance(5)
        session.showHint()
        XCTAssertEqual(session.keyFeedback[60]?.kind, .hint)
        XCTAssertNil(session.keyFeedback[62])
    }

    func testPlayAlongIgnoresNotesOutsideTheWindow() {
        let session = makeSession(lesson("C4 R:10 D4"), mode: .playAlong)
        session.start()
        advance(LessonSession.leadIn + 0.1)
        session.handleNoteOn(note: 62, detected: nil)       // D4 is ~10 s away: gentle miss, not a hit
        XCTAssertEqual(session.noteProgress[1], .pending)
        XCTAssertEqual(session.keyFeedback[62]?.kind, .gentle)
    }

    func testChordsRequireEveryKey() {
        let chord = Lesson(title: "Chord", hand: .right, notes: [
            Note(timestamp: 0, duration: 1, noteNumber: 60, assignedFinger: 1),
            Note(timestamp: 0, duration: 1, noteNumber: 64, assignedFinger: 3),
            Note(timestamp: 1, duration: 1, noteNumber: 67, assignedFinger: 5)], source: .library)
        let session = makeSession(chord)
        session.start()
        advance(5)
        XCTAssertEqual(Set(session.targets.map(\.note.noteNumber)), [60, 64])
        session.handleNoteOn(note: 67, detected: nil)      // too early: gentle
        XCTAssertEqual(session.noteProgress[2], .pending)
        session.handleNoteOn(note: 64, detected: nil)
        XCTAssertEqual(session.targets.map(\.note.noteNumber), [60])
        session.handleNoteOn(note: 60, detected: nil)
        XCTAssertEqual(session.targets.map(\.note.noteNumber), [67])
    }

    func testRestartResetsEverything() {
        let session = makeSession(lesson())
        session.start()
        advance(5)
        session.handleNoteOn(note: 60, detected: nil)
        session.start()
        XCTAssertEqual(session.noteProgress, [.pending, .pending, .pending])
        XCTAssertEqual(session.stars, 0)
        XCTAssertEqual(session.phase, .playing)
    }

    func testEmptyLessonStaysIdle() {
        let session = makeSession(Lesson(title: "Empty", notes: [], source: .library))
        session.start()
        XCTAssertEqual(session.phase, .idle)
    }
}

@MainActor
final class CalibrationFlowTests: XCTestCase {
    private func frames(for template: HandTemplate, from start: TimeInterval, seconds: TimeInterval, jitter: Double = 0) -> [HandFrame] {
        var result: [HandFrame] = []
        var time = start
        var tick = 0
        while time < start + seconds {
            var joints: [JointID: TrackedJoint] = [:]
            for joint in JointID.allCases {
                guard let target = template.target(for: joint) else { continue }
                let wobble = tick.isMultiple(of: 2) ? jitter : -jitter
                joints[joint] = TrackedJoint(point: CGPoint(x: target.x + wobble, y: target.y), confidence: 0.9)
            }
            result.append(HandFrame(channel: .overhead, timestamp: time, imageSize: CGSize(width: 1920, height: 1080),
                                    hands: [TrackedHand(id: 0, side: template.side, joints: joints)]))
            time += 1.0 / 30.0
            tick += 1
        }
        return result
    }

    func testBothHandsCalibrateAndProduceAKeyboardRegion() {
        let flow = CalibrationFlow(firstNote: 36, lastNote: 96)
        XCTAssertEqual(flow.steps.map(\.side), [.right, .left])
        var completed: [HandSide] = []
        let token = flow.stepCompleted.sink { completed.append($0.side) }

        var time = 0.0
        for step in flow.steps {
            for frame in frames(for: step.template, from: time, seconds: 2.0, jitter: 0.002) { flow.ingest(frame) }
            time += 2.0
        }
        token.cancel()
        XCTAssertEqual(completed, [.right, .left])
        guard case .success(let region) = flow.outcome else { return XCTFail("expected success, got \(String(describing: flow.outcome))") }
        XCTAssertTrue(region.isCalibrated)
        XCTAssertEqual(region.slope, 17, accuracy: 3)
        // Right-hand thumb (C4) should land near the template's thumb tip.
        let thumbX = Double(HandTemplate.make(for: .right).target(for: .thumbTip)!.x)
        XCTAssertEqual(region.x(ofNote: 60), thumbX, accuracy: 0.04)
    }

    func testProgressBuildsWhileAlignedAndResetsWhenTheHandLeaves() {
        let flow = CalibrationFlow(firstNote: 36, lastNote: 96)
        let template = flow.steps[0].template
        let aligned = frames(for: template, from: 0, seconds: 0.7)
        for frame in aligned { flow.ingest(frame) }
        XCTAssertTrue(flow.isAligned)
        XCTAssertGreaterThan(flow.progress, 0.3)
        XCTAssertLessThan(flow.progress, 1)
        // Hand leaves.
        for index in 0..<30 {
            flow.ingest(HandFrame(channel: .overhead, timestamp: 0.7 + Double(index) / 30, imageSize: CGSize(width: 1920, height: 1080), hands: []))
        }
        XCTAssertFalse(flow.isAligned)
        XCTAssertEqual(flow.progress, 0, accuracy: 1e-9)
    }

    func testSmallKeyboardSkipsTheLeftHandStep() {
        // A keyboard starting at middle C can't host the left-hand position.
        let flow = CalibrationFlow(firstNote: 60, lastNote: 84)
        XCTAssertEqual(flow.steps.map(\.side), [.right])
    }

    func testSkippingEverythingFailsGracefully() {
        let flow = CalibrationFlow(firstNote: 36, lastNote: 96)
        flow.skipCurrentStep()
        flow.skipCurrentStep()
        guard case .failed = flow.outcome else { return XCTFail("expected failure") }
        flow.restart()
        XCTAssertNil(flow.outcome)
        XCTAssertEqual(flow.currentIndex, 0)
    }

    func testCalibrationStoreRoundTrip() {
        let defaults = UserDefaults(suiteName: "PianoPalsTests.\(UUID().uuidString)")!
        let store = CalibrationStore(defaults: defaults)
        let region = KeyboardRegion(firstNote: 36, lastNote: 96, slope: 15, intercept: -3, yMin: 0.4, yMax: 0.8, isCalibrated: true)
        store.save(region, channel: .overhead)
        XCTAssertEqual(store.load(channel: .overhead, firstNote: 36, lastNote: 96), region)
        XCTAssertNil(store.load(channel: .overhead, firstNote: 21, lastNote: 108), "a different keyboard size invalidates it")
        XCTAssertNil(store.load(channel: .primary, firstNote: 36, lastNote: 96))
        store.clear(channel: .overhead)
        XCTAssertNil(store.load(channel: .overhead, firstNote: 36, lastNote: 96))
    }
}
