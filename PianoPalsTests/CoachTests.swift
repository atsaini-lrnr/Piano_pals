import XCTest
@testable import PianoPals

final class MistakeAnalyzerTests: XCTestCase {
    private func note(_ pitch: Int, finger: Int) -> Note { Note(timestamp: 0, duration: 1, noteNumber: pitch, assignedFinger: finger) }

    // MARK: M1 — classification

    func testKeyNearness() {
        XCTAssertEqual(KeyNearness.between(played: 60, expected: 62), .adjacent(expectedIs: .right))
        XCTAssertEqual(KeyNearness.between(played: 62, expected: 60), .adjacent(expectedIs: .left))
        XCTAssertEqual(KeyNearness.between(played: 61, expected: 60), .adjacent(expectedIs: .left))
        XCTAssertEqual(KeyNearness.between(played: 48, expected: 60), .otherOctave)
        XCTAssertEqual(KeyNearness.between(played: 72, expected: 60), .otherOctave)
        XCTAssertEqual(KeyNearness.between(played: 60, expected: 67), .far)
        XCTAssertEqual(KeyNearness.between(played: 60, expected: 60), .far, "same key is never a nearness case")
    }

    func testWrongKeyIsClassifiedAgainstTheNearestExpectedKey() {
        var analyzer = MistakeAnalyzer()
        _ = analyzer.ingest(.started, lessonHand: .right, now: 0)
        let mistakes = analyzer.ingest(.gentleMiss(played: 63, expected: [60, 64]), lessonHand: .right, now: 1)
        XCTAssertEqual(mistakes, [Mistake(time: 1, kind: .wrongKey(played: 63, expected: 64, nearness: .adjacent(expectedIs: .right)))])
        XCTAssertEqual(analyzer.stats.wrongKeys, 1)
        XCTAssertEqual(analyzer.stats.consecutiveWrongKeys, 1)
    }

    func testWrongFingerAndWrongHandAreReportedAndCounted() {
        var analyzer = MistakeAnalyzer()
        _ = analyzer.ingest(.started, lessonHand: .right, now: 0)
        let target = note(60, finger: 1)
        let finger = analyzer.ingest(.noteHit(index: 0, note: target, quality: .fingerOff(played: .ring)), lessonHand: .right, now: 1)
        XCTAssertEqual(finger, [Mistake(time: 1, kind: .wrongFinger(expected: .thumb, played: .ring))])
        let hand = analyzer.ingest(.noteHit(index: 1, note: note(62, finger: 2), quality: .wrongHand(played: .left)), lessonHand: .right, now: 2)
        XCTAssertEqual(hand, [Mistake(time: 2, kind: .wrongHand(expected: .right, played: .left))])
        XCTAssertEqual(analyzer.stats.wrongFingers, 1)
        XCTAssertEqual(analyzer.stats.wrongHands, 1)
        XCTAssertEqual(analyzer.stats.hits, 2, "wrong finger on the right key still counts as a hit")
    }

    func testPerfectAndUnverifiedProduceNoMistakeAndFeedAccuracy() {
        var analyzer = MistakeAnalyzer()
        _ = analyzer.ingest(.started, lessonHand: .right, now: 0)
        XCTAssertTrue(analyzer.ingest(.noteHit(index: 0, note: note(60, finger: 1), quality: .perfect), lessonHand: .right, now: 1).isEmpty)
        XCTAssertTrue(analyzer.ingest(.noteHit(index: 1, note: note(62, finger: 2), quality: .fingerUnverified), lessonHand: .right, now: 2).isEmpty)
        XCTAssertEqual(analyzer.stats.fingerVerified, 1, "an unverified note says nothing about the finger")
        XCTAssertEqual(analyzer.stats.fingerAccuracy, 1)
        XCTAssertEqual(analyzer.stats.firstTryAccuracy, 1)
    }

    func testFirstTryAccuracyIgnoresRetriesOfTheSameNote() {
        var analyzer = MistakeAnalyzer()
        _ = analyzer.ingest(.started, lessonHand: .right, now: 0)
        _ = analyzer.ingest(.gentleMiss(played: 70, expected: [60]), lessonHand: .right, now: 1)
        _ = analyzer.ingest(.noteHit(index: 0, note: note(60, finger: 1), quality: .perfect), lessonHand: .right, now: 2)   // 2nd try
        _ = analyzer.ingest(.noteHit(index: 1, note: note(62, finger: 2), quality: .perfect), lessonHand: .right, now: 3)   // 1st try
        XCTAssertEqual(analyzer.stats.hits, 2)
        XCTAssertEqual(analyzer.stats.firstTryHits, 1)
        XCTAssertEqual(analyzer.stats.firstTryAccuracy, 0.5, accuracy: 1e-9)
        XCTAssertEqual(analyzer.stats.consecutiveWrongKeys, 0, "a hit ends the streak of wrong keys")
    }

    func testHesitationFiresOnceAfterSevenSecondsAndResetsOnTheNextHit() {
        var analyzer = MistakeAnalyzer()
        _ = analyzer.ingest(.started, lessonHand: .right, now: 100)
        XCTAssertTrue(analyzer.tick(now: 106.9, hasTargets: true).isEmpty)
        XCTAssertEqual(analyzer.tick(now: 107, hasTargets: true), [Mistake(time: 107, kind: .hesitation)])
        XCTAssertTrue(analyzer.tick(now: 120, hasTargets: true).isEmpty, "only once per waiting period")
        _ = analyzer.ingest(.noteHit(index: 0, note: note(60, finger: 1), quality: .perfect), lessonHand: .right, now: 121)
        XCTAssertTrue(analyzer.tick(now: 125, hasTargets: true).isEmpty)
        XCTAssertEqual(analyzer.tick(now: 128, hasTargets: true).count, 1)
        XCTAssertEqual(analyzer.stats.hesitations, 2)
    }

    func testNoHesitationWithoutTargetsOrAfterResume() {
        var analyzer = MistakeAnalyzer()
        _ = analyzer.ingest(.started, lessonHand: .right, now: 0)
        XCTAssertTrue(analyzer.tick(now: 50, hasTargets: false).isEmpty)
        analyzer.resumed(at: 100)   // came back from a pause
        XCTAssertTrue(analyzer.tick(now: 103, hasTargets: true).isEmpty)
        XCTAssertEqual(analyzer.tick(now: 108, hasTargets: true).count, 1)
    }

    func testSkippedNotesAreCountedGently() {
        var analyzer = MistakeAnalyzer()
        _ = analyzer.ingest(.started, lessonHand: .right, now: 0)
        let mistakes = analyzer.ingest(.noteMissed(index: 0, note: note(60, finger: 1)), lessonHand: .right, now: 1)
        XCTAssertEqual(mistakes, [Mistake(time: 1, kind: .skippedNote)])
        XCTAssertEqual(analyzer.stats.skipped, 1)
    }

    func testWeakestFingerNeedsRealEvidence() {
        var stats = SessionStats()
        stats.perFinger = [4: FingerStats(attempts: 2, errors: 2)]
        XCTAssertNil(stats.weakestFinger, "two tries aren't enough")
        stats.perFinger = [4: FingerStats(attempts: 4, errors: 1)]
        XCTAssertNil(stats.weakestFinger, "25 % isn't a pattern")
        stats.perFinger = [4: FingerStats(attempts: 4, errors: 3), 2: FingerStats(attempts: 5, errors: 2)]
        XCTAssertEqual(stats.weakestFinger, .ring)
    }

    func testRecentWindowKeepsTenAndStartedResets() {
        var stats = SessionStats()
        for i in 0..<15 { stats.pushRecent(i.isMultiple(of: 2)) }
        XCTAssertEqual(stats.recent.count, 10)
        var analyzer = MistakeAnalyzer()
        _ = analyzer.ingest(.gentleMiss(played: 61, expected: [60]), lessonHand: .right, now: 0)
        _ = analyzer.ingest(.started, lessonHand: .right, now: 1)
        XCTAssertEqual(analyzer.stats, SessionStats())
    }
}

final class CoachTests: XCTestCase {
    private func wrongKey(_ played: Int = 70, expected: Int = 60, at time: TimeInterval) -> Mistake {
        Mistake(time: time, kind: .wrongKey(played: played, expected: expected, nearness: .between(played: played, expected: expected)))
    }

    private func spoken(_ actions: [CoachAction]) -> [String] {
        actions.compactMap { if case .say(let text) = $0 { return text } else { return nil } }
    }

    // MARK: M2 — nothing negative can ever be said

    func testNoPhraseContainsANegativeWord() {
        let all = CoachPhrases.allExpanded
        XCTAssertGreaterThan(all.count, 30)
        for phrase in all {
            let lowered = phrase.lowercased()
            for word in CoachPhrases.banned {
                XCTAssertFalse(lowered.contains(word), "“\(phrase)” contains banned “\(word)”")
            }
            XCTAssertFalse(phrase.contains("%"), "unfilled placeholder in “\(phrase)”")
        }
    }

    func testParentSummaryTextIsKindToo() async {
        var stats = SessionStats()
        stats.hits = 10; stats.firstTryHits = 4
        stats.perFinger = [4: FingerStats(attempts: 4, errors: 3)]
        let summary = SessionSummary(lessonTitle: "Mary", durationSeconds: 90, notes: 14, stars: 1, stats: stats)
        let text = await TemplateSummaryPhraser().phrase(for: summary)
        for word in ["wrong", "bad", "fail", "terrible", "poor"] { XCTAssertFalse(text.lowercased().contains(word), text) }
        XCTAssertTrue(text.contains("40%"))
        XCTAssertTrue(text.contains("ring finger"))
    }

    // MARK: Escalation

    func testFirstPlainWrongKeyIsSilentJustTheVisualPulse() {
        var coach = Coach()
        var stats = SessionStats(); stats.consecutiveWrongKeys = 1
        XCTAssertTrue(coach.react(to: wrongKey(at: 0), stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 0).isEmpty)
    }

    func testNearMissGetsADirectionalHint() {
        var coach = Coach()
        var stats = SessionStats(); stats.consecutiveWrongKeys = 1
        let actions = coach.react(to: wrongKey(61, expected: 62, at: 0), stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 0)
        XCTAssertEqual(spoken(actions).count, 1)
        XCTAssertTrue(spoken(actions)[0].contains("right"))
        let left = coach.react(to: wrongKey(63, expected: 62, at: 10), stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 10)
        XCTAssertTrue(spoken(left)[0].contains("left"))
    }

    func testSecondWrongKeyGlowsTheTargetAndPointsToIt() {
        var coach = Coach()
        var stats = SessionStats(); stats.consecutiveWrongKeys = 2
        let actions = coach.react(to: wrongKey(at: 0), stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 0)
        XCTAssertTrue(actions.contains(.highlightTarget))
        XCTAssertEqual(spoken(actions), [CoachPhrases.lookForGlow[0]])
    }

    // MARK: M11 — rate limiting

    func testAtMostOneSpokenTipEverySixSeconds() {
        var coach = Coach()
        var stats = SessionStats(); stats.consecutiveWrongKeys = 2
        var spokenAt: [TimeInterval] = []
        for second in stride(from: 0.0, through: 30.0, by: 1.0) {
            let actions = coach.react(to: wrongKey(at: second), stats: stats, mode: .waitForMe, tempoScale: 0.8, now: second)
            if !spoken(actions).isEmpty { spokenAt.append(second) }
        }
        XCTAssertGreaterThan(spokenAt.count, 3)
        for (a, b) in zip(spokenAt, spokenAt.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, Coach.speechGap) }
    }

    func testCoachDoesNotRepeatItselfBackToBack() {
        var coach = Coach()
        var stats = SessionStats(); stats.consecutiveWrongKeys = 2
        let first = spoken(coach.react(to: wrongKey(at: 0), stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 0))
        let second = spoken(coach.react(to: wrongKey(at: 10), stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 10))
        XCTAssertNotEqual(first, second)
    }

    // MARK: Fingers, hands, hesitation

    func testWrongFingerShowsABadgeThenSpeaksOnRepeats() {
        var coach = Coach()
        let stats = SessionStats()
        let mistake = Mistake(time: 0, kind: .wrongFinger(expected: .index, played: .ring))
        let first = coach.react(to: mistake, stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 0)
        XCTAssertEqual(first, [.showFingerHint(.index)], "first time: visual cue only")
        let second = coach.react(to: mistake, stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 10)
        XCTAssertTrue(second.contains(.showFingerHint(.index)))
        XCTAssertTrue(spoken(second)[0].contains("Blue Circle"))
        XCTAssertTrue(spoken(second)[0].contains("2"))
    }

    func testWrongHandIsExplainedKindly() {
        var coach = Coach()
        let actions = coach.react(to: Mistake(time: 0, kind: .wrongHand(expected: .right, played: .left)), stats: SessionStats(), mode: .waitForMe, tempoScale: 0.8, now: 0)
        XCTAssertTrue(spoken(actions)[0].contains("right hand"))
    }

    func testHesitationOffersTimeAndAGlow() {
        var coach = Coach()
        let actions = coach.react(to: Mistake(time: 0, kind: .hesitation), stats: SessionStats(), mode: .waitForMe, tempoScale: 0.8, now: 0)
        XCTAssertTrue(actions.contains(.highlightTarget))
        XCTAssertEqual(spoken(actions), [CoachPhrases.hesitation[0]])
    }

    // MARK: Adaptive pace

    func testFourWrongKeysInARowSlowsThingsDownOnce() {
        var coach = Coach()
        var stats = SessionStats(); stats.consecutiveWrongKeys = 4
        let actions = coach.react(to: wrongKey(at: 0), stats: stats, mode: .waitForMe, tempoScale: 0.8, now: 0)
        XCTAssertTrue(actions.contains(.adjustPace(waitForMe: true, tempoScale: 0.65)))
        XCTAssertTrue(spoken(actions).contains(CoachPhrases.slower[0]))
        // Still struggling a few seconds later: no second change inside the cooldown.
        let again = coach.react(to: wrongKey(at: 5), stats: stats, mode: .waitForMe, tempoScale: 0.65, now: 5)
        XCTAssertFalse(again.contains { if case .adjustPace = $0 { return true } else { return false } })
    }

    func testSlowingNeverGoesBelowFortyPercent() {
        var coach = Coach()
        var stats = SessionStats(); stats.consecutiveWrongKeys = 4
        let actions = coach.react(to: wrongKey(at: 0), stats: stats, mode: .waitForMe, tempoScale: 0.55, now: 0)
        XCTAssertTrue(actions.contains(.adjustPace(waitForMe: true, tempoScale: 0.4)))
        var floor = Coach()
        XCTAssertFalse(floor.react(to: wrongKey(at: 100), stats: stats, mode: .waitForMe, tempoScale: 0.5, now: 100)
            .contains { if case .adjustPace = $0 { return true } else { return false } }, "already at the floor")
    }

    func testPlayAlongStrugglesSwitchToWaitForMe() {
        var coach = Coach()
        var stats = SessionStats(); stats.consecutiveWrongKeys = 4
        let actions = coach.react(to: wrongKey(at: 0), stats: stats, mode: .playAlong, tempoScale: 0.8, now: 0)
        XCTAssertTrue(actions.contains(.adjustPace(waitForMe: true, tempoScale: nil)))
    }

    func testRepeatedSkipsSwitchToWaitForMe() {
        var coach = Coach()
        var stats = SessionStats(); stats.recent = [true, true, true]
        let actions = coach.react(to: Mistake(time: 0, kind: .skippedNote), stats: stats, mode: .playAlong, tempoScale: 0.8, now: 0)
        XCTAssertTrue(actions.contains(.adjustPace(waitForMe: true, tempoScale: nil)))
        var calm = Coach()
        var fine = SessionStats(); fine.recent = [false, true, false, false]
        XCTAssertTrue(calm.react(to: Mistake(time: 0, kind: .skippedNote), stats: fine, mode: .playAlong, tempoScale: 0.8, now: 0).isEmpty)
    }

    // MARK: Praise & finish

    func testPraiseOnEveryFifthRightNoteAndBrokenByATrickyOne() {
        var coach = Coach()
        var said: [Int] = []
        for i in 1...10 {
            if !spoken(coach.reactToHit(quality: .perfect, now: Double(i) * 4)).isEmpty { said.append(i) }
        }
        XCTAssertEqual(said, [5, 10])
        var broken = Coach()
        for i in 1...4 { _ = broken.reactToHit(quality: .perfect, now: Double(i) * 4) }
        _ = broken.react(to: Mistake(time: 0, kind: .hesitation), stats: SessionStats(), mode: .waitForMe, tempoScale: 0.8, now: 100)
        XCTAssertTrue(broken.reactToHit(quality: .perfect, now: 200).isEmpty, "streak restarts after a stumble")
    }

    func testFinishMentionsAFingerToPracticeAsAPositive() {
        var coach = Coach()
        var stats = SessionStats()
        stats.perFinger = [5: FingerStats(attempts: 4, errors: 3)]
        let said = spoken(coach.reactToFinish(stars: 3, stats: stats))
        XCTAssertEqual(said.count, 2)
        XCTAssertTrue(said[1].contains("Purple Heart"))
        var plain = Coach()
        XCTAssertEqual(spoken(plain.reactToFinish(stars: 2, stats: SessionStats())).count, 1)
    }

    // MARK: Progress store

    func testProgressStoreKeepsOnlyTheLatest30() {
        let defaults = UserDefaults(suiteName: "PianoPalsTests.progress.\(UUID().uuidString)")!
        let store = ProgressStore(defaults: defaults)
        for i in 0..<35 {
            store.append(SessionSummary(lessonTitle: "Song \(i)", durationSeconds: 60, notes: 10, stars: 2, stats: SessionStats()))
        }
        let all = store.load()
        XCTAssertEqual(all.count, ProgressStore.limit)
        XCTAssertEqual(all.first?.lessonTitle, "Song 34", "newest first")
        store.clear()
        XCTAssertTrue(store.load().isEmpty)
    }

    func testSessionSummaryCapturesStats() {
        var stats = SessionStats()
        stats.hits = 8; stats.firstTryHits = 6; stats.fingerVerified = 4; stats.fingerCorrect = 3
        stats.wrongKeys = 2; stats.hesitations = 1
        let summary = SessionSummary(lessonTitle: "T", durationSeconds: 42, notes: 8, stars: 3, stats: stats)
        XCTAssertEqual(summary.firstTryAccuracy, 0.75, accuracy: 1e-9)
        XCTAssertEqual(summary.fingerAccuracy ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(summary.wrongKeys, 2)
        XCTAssertEqual(summary.hesitations, 1)
    }
}
