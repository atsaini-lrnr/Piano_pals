import XCTest
@testable import PianoPals

final class StreamResamplerTests: XCTestCase {
    func testTheOutputIsTheRightLengthAndKeepsThePitch() {
        var resampler = StreamResampler(inputRate: 48_000, outputRate: 22_050)
        let input = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: 1_000) { output += resampler.process(Array(input[start..<min(start + 1_000, input.count)])) }
        XCTAssertEqual(Double(output.count), 22_050, accuracy: 3, "one second in, one second out, however the input was chunked")
        let estimate = YINPitchDetector(sampleRate: 22_050, frameSize: 2_048).estimate(Array(output[4_000..<6_048]))
        XCTAssertEqual(Int(YINPitchDetector.midiNote(forFrequency: estimate.frequency ?? 0).rounded()), 69)
    }

    func testSameRateAndSilenceAreHarmless() {
        var same = StreamResampler(inputRate: 22_050, outputRate: 22_050)
        XCTAssertEqual(same.process([1, 2, 3]), [1, 2, 3])
        var quiet = StreamResampler(inputRate: 44_100, outputRate: 22_050)
        XCTAssertTrue(quiet.process([Float](repeating: 0, count: 4_410)).allSatisfy { $0 == 0 })
        XCTAssertTrue(quiet.process([]).isEmpty)
    }
}

final class MIDIRecordingTests: XCTestCase {
    private func play(_ notes: [(Int, Double, Double)]) -> [MIDIRecording.Event] {
        notes.flatMap { [MIDIRecording.Event(note: $0.0, isOn: true, time: 100 + $0.1), MIDIRecording.Event(note: $0.0, isOn: false, time: 100 + $0.1 + $0.2)] }
    }

    func testKeysBecomeNotesWithTheirRealTimingStartingAtZero() {
        let raw = MIDIRecording.rawNotes(from: play([(60, 2.0, 0.5), (64, 2.5, 0.5), (67, 3.0, 1.0)]), endTime: 110)
        XCTAssertEqual(raw.map(\.pitch), [60, 64, 67])
        XCTAssertEqual(raw.map(\.start), [0, 0.5, 1.0])
        XCTAssertEqual(raw[2].duration, 1.0, accuracy: 1e-9)
    }

    func testChordsAndAKeyHeldAtTheEndAreKept() {
        var events = play([(60, 0, 1), (64, 0, 1), (67, 0, 1)])
        events.append(MIDIRecording.Event(note: 72, isOn: true, time: 100.5))
        let raw = MIDIRecording.rawNotes(from: events, endTime: 102)
        XCTAssertEqual(raw.filter { $0.start == 0 }.map(\.pitch).sorted(), [60, 64, 67])
        XCTAssertEqual(raw.last?.pitch, 72)
        XCTAssertGreaterThan(raw.last?.duration ?? 0, 1.0, "closed when the recording stopped")
        XCTAssertTrue(MIDIRecording.rawNotes(from: [], endTime: 1).isEmpty)
    }

    func testBothHandsBecomeOneLessonWithEachHandsOwnFingers() throws {
        let right = [60, 62, 64, 65, 67].enumerated().map { RawNote(pitch: $1, start: Double($0), duration: 0.8) }
        let left = [48, 43, 45, 41, 48].enumerated().map { RawNote(pitch: $1, start: Double($0), duration: 0.8) }
        let lesson = try XCTUnwrap(MIDIRecording.lesson(from: right + left, title: "Mine"))
        XCTAssertTrue(lesson.isBothHands)
        XCTAssertEqual(lesson.notes.filter { $0.hand == .right }.count, 5)
        XCTAssertEqual(lesson.notes.filter { $0.hand == .left }.count, 5)
        XCTAssertTrue(lesson.notes.allSatisfy { (1...5).contains($0.assignedFinger) })
        XCTAssertEqual(lesson.notes.map(\.noteNumber).sorted(), (right + left).map(\.pitch).sorted(), "no note lost or moved")
    }

    func testOneHandMakesAnOrdinaryLessonAndTooFewKeysMakeNone() throws {
        let tune = [60, 62, 64, 65, 67, 65].enumerated().map { RawNote(pitch: $1, start: Double($0), duration: 0.8) }
        let lesson = try XCTUnwrap(MIDIRecording.lesson(from: tune, title: "One"))
        XCTAssertFalse(lesson.isBothHands)
        XCTAssertEqual(lesson.hand, .right)
        XCTAssertNil(MIDIRecording.lesson(from: Array(tune.prefix(2)), title: "x"))
    }
}
