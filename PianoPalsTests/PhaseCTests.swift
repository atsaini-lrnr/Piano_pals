import XCTest
@testable import PianoPals

/// Audio helpers for synthesising test tones.
private enum Synth {
    static func tone(frequency: Double, seconds: Double, sampleRate: Double = 44_100, harmonics: [Double] = [1],
                     vibratoCents: Double = 0, amplitude: Double = 0.4, startPhase: Double = 0) -> [Float] {
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var phase = startPhase
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let bend = vibratoCents == 0 ? 1 : pow(2, vibratoCents * sin(2 * .pi * 5 * t) / 1200)
            phase += 2 * .pi * frequency * bend / sampleRate
            var value = 0.0
            for (k, weight) in harmonics.enumerated() { value += weight * sin(phase * Double(k + 1)) }
            samples[i] = Float(amplitude * value / harmonics.reduce(0, +))
        }
        return samples
    }

    static func frequency(midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    static func silence(_ seconds: Double, sampleRate: Double = 44_100) -> [Float] { [Float](repeating: 0, count: Int(seconds * sampleRate)) }

    /// Runs the full listen pipeline (detector + segmenter) over audio, exactly as `ListenRecorder` does.
    static func transcribe(_ samples: [Float], sampleRate: Double = 44_100) -> [RawNote] {
        let detector = YINPitchDetector(sampleRate: sampleRate, frameSize: 2_048)
        var segmenter = NoteSegmenter(frameDuration: 1_024 / sampleRate)
        var offset = 0
        while offset + 2_048 <= samples.count {
            let estimate = detector.estimate(Array(samples[offset..<offset + 2_048]))
            segmenter.ingest(time: Double(offset) / sampleRate, estimate: estimate)
            offset += 1_024
        }
        return segmenter.finish(endTime: Double(samples.count) / sampleRate)
    }
}

final class PitchDetectionTests: XCTestCase {
    private func cents(_ measured: Double, _ expected: Double) -> Double { 1200 * log2(measured / expected) }

    // MARK: M6 — pitch accuracy

    func testPureTonesAreWithin25CentsAcrossTheRange() {
        let detector = YINPitchDetector()
        for midi in [41, 45, 48, 55, 60, 62, 64, 67, 72, 76, 81, 84, 88] {
            let f = Synth.frequency(midi: midi)
            guard f >= detector.minFrequency, f <= detector.maxFrequency else { continue }
            let estimate = detector.estimate(Synth.tone(frequency: f, seconds: 0.2))
            guard let measured = estimate.frequency else { return XCTFail("no pitch for MIDI \(midi)") }
            XCTAssertEqual(cents(measured, f), 0, accuracy: 25, "MIDI \(midi) measured \(measured) Hz")
            XCTAssertGreaterThan(estimate.clarity, 0.9)
        }
    }

    func testRichHarmonicToneDoesNotJumpAnOctave() {
        // A piano/voice-like spectrum where the 2nd harmonic is as strong as the fundamental.
        let detector = YINPitchDetector()
        for midi in [48, 55, 60, 64, 69, 72] {
            let f = Synth.frequency(midi: midi)
            let estimate = detector.estimate(Synth.tone(frequency: f, seconds: 0.2, harmonics: [1, 1, 0.6, 0.4, 0.2]))
            XCTAssertEqual(Int(YINPitchDetector.midiNote(forFrequency: estimate.frequency ?? 0).rounded()), midi, "MIDI \(midi)")
        }
    }

    func testWorksAt48kHz() {
        let detector = YINPitchDetector(sampleRate: 48_000)
        let f = Synth.frequency(midi: 64)
        let estimate = detector.estimate(Synth.tone(frequency: f, seconds: 0.2, sampleRate: 48_000))
        XCTAssertEqual(cents(estimate.frequency ?? 0, f), 0, accuracy: 25)
    }

    func testVibratoStaysOnTheRightNote() {
        let detector = YINPitchDetector()
        let f = Synth.frequency(midi: 67)
        let estimate = detector.estimate(Synth.tone(frequency: f, seconds: 0.2, vibratoCents: 30))
        XCTAssertEqual(Int(YINPitchDetector.midiNote(forFrequency: estimate.frequency ?? 0).rounded()), 67)
    }

    // MARK: M8 — silence and noise

    func testSilenceAndQuietNoiseGiveNoPitch() {
        let detector = YINPitchDetector()
        XCTAssertNil(detector.estimate(Synth.silence(0.2)).frequency)
        var generator = SeededGenerator(seed: 7)
        let hiss = (0..<4096).map { _ in Float.random(in: -0.004...0.004, using: &generator) }
        XCTAssertNil(detector.estimate(hiss).frequency, "background hiss below the gate")
    }

    func testLoudNoiseIsNotMistakenForAPitch() {
        let detector = YINPitchDetector()
        var generator = SeededGenerator(seed: 11)
        let noise = (0..<4096).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        XCTAssertNil(detector.estimate(noise).frequency)
    }

    func testTooShortInputIsRejected() {
        XCTAssertNil(YINPitchDetector().estimate([0.1, 0.2, 0.3]).frequency)
    }

    func testThroughputIsFasterThanRealTime() {
        let detector = YINPitchDetector()
        let frame = Synth.tone(frequency: 261.63, seconds: 0.1)
        let start = Date()
        for _ in 0..<20 { _ = detector.estimate(frame) }
        let perFrame = Date().timeIntervalSince(start) / 20
        XCTAssertLessThan(perFrame, 1_024.0 / 44_100.0, "each hop (23 ms of audio) must analyse in less than 23 ms, even in a debug build")
    }
}

final class ListenTranscriptionTests: XCTestCase {
    // MARK: M7 — note-level F1

    private func f1(expected: [RawNote], heard: [RawNote]) -> Double {
        var used = Set<Int>()
        var hits = 0
        for note in expected {
            if let index = heard.indices.first(where: { !used.contains($0) && heard[$0].pitch == note.pitch && abs(heard[$0].start - note.start) < 0.15 }) {
                used.insert(index)
                hits += 1
            }
        }
        guard hits > 0 else { return 0 }
        let precision = Double(hits) / Double(heard.count)
        let recall = Double(hits) / Double(expected.count)
        return 2 * precision * recall / (precision + recall)
    }

    private func render(_ notes: [RawNote], harmonics: [Double] = [1, 0.5, 0.3]) -> [Float] {
        var audio: [Float] = []
        var cursor = 0.0
        for note in notes {
            if note.start > cursor { audio += Synth.silence(note.start - cursor); cursor = note.start }
            audio += Synth.tone(frequency: Synth.frequency(midi: note.pitch), seconds: note.duration, harmonics: harmonics)
            cursor += note.duration
        }
        return audio
    }

    func testSimpleMelodiesAreTranscribedAccurately() {
        var scores: [Double] = []
        for id in ["twinkle", "mary-lamb", "ode-to-joy", "frere-jacques", "au-clair", "hot-cross-buns"] {
            guard let song = SongLibrary.all.first(where: { $0.id == id }) else { return XCTFail("missing \(id)") }
            // Played one note at a time at a steady 0.45 s per note with a short breath between.
            var cursor = 0.0
            let played: [RawNote] = song.lesson().notes.map { note in
                defer { cursor += 0.55 }
                return RawNote(pitch: note.noteNumber, start: cursor, duration: 0.45)
            }
            let heard = Synth.transcribe(render(played))
            let score = f1(expected: played, heard: heard)
            scores.append(score)
            XCTAssertGreaterThanOrEqual(score, 0.9, "\(id): expected \(played.map(\.pitch)) heard \(heard.map(\.pitch))")
        }
        XCTAssertGreaterThanOrEqual(scores.reduce(0, +) / Double(scores.count), 0.95)
    }

    func testRepeatedNotesAndLegatoStepsStaySeparate() {
        let melody = [RawNote(pitch: 60, start: 0, duration: 0.4), RawNote(pitch: 60, start: 0.5, duration: 0.4),   // same note twice, short breath
                      RawNote(pitch: 62, start: 0.9, duration: 0.4), RawNote(pitch: 64, start: 1.3, duration: 0.4)]   // legato steps
        let heard = Synth.transcribe(render(melody))
        XCTAssertEqual(heard.map(\.pitch), [60, 60, 62, 64], "heard \(heard)")
    }

    func testSilenceYieldsNoNotes() {
        XCTAssertTrue(Synth.transcribe(Synth.silence(2)).isEmpty)
    }

    func testBlipsShorterThanATenthOfASecondAreIgnored() {
        let audio = Synth.tone(frequency: 440, seconds: 0.05) + Synth.silence(0.5) + Synth.tone(frequency: 330, seconds: 0.4)
        let heard = Synth.transcribe(audio)
        XCTAssertEqual(heard.map(\.pitch), [64])
    }

    // MARK: Transcriber

    func testTranscriberNeedsEnoughNotes() {
        let three = (0..<3).map { RawNote(pitch: 60 + $0, start: Double($0) * 0.5, duration: 0.4) }
        XCTAssertNil(ListenTranscriber.lesson(from: three, hand: .right))
        XCTAssertNil(ListenTranscriber.lesson(from: [], hand: .right))
    }

    func testTranscriberShiftsIntoTheHandsRegisterAndFingers() {
        // Sung an octave and a half too high / too low.
        let highTune = [84, 86, 88, 89, 91, 89, 88, 86].enumerated().map { RawNote(pitch: $1, start: Double($0) * 0.5, duration: 0.4) }
        let lesson = try! XCTUnwrap(ListenTranscriber.lesson(from: highTune, hand: .right))
        XCTAssertTrue(lesson.notes.allSatisfy { (55...80).contains($0.noteNumber) }, "\(lesson.notes.map(\.noteNumber))")
        // Shifting is by whole octaves, so the tune's shape is unchanged.
        let intervals = zip(lesson.notes, lesson.notes.dropFirst()).map { $1.noteNumber - $0.noteNumber }
        XCTAssertEqual(intervals, [2, 2, 1, 2, -2, -1, -2])
        XCTAssertTrue(lesson.notes.allSatisfy { (1...5).contains($0.assignedFinger) })
        XCTAssertEqual(lesson.source, .imported)

        let lowTune = highTune.map { RawNote(pitch: $0.pitch - 36, start: $0.start, duration: $0.duration) }
        let left = try! XCTUnwrap(ListenTranscriber.lesson(from: lowTune, hand: .left))
        XCTAssertTrue(left.notes.allSatisfy { (40...64).contains($0.noteNumber) }, "\(left.notes.map(\.noteNumber))")
    }

    func testTranscriberCompressesLongSilencesAndSnapsRhythm() {
        let heard = [RawNote(pitch: 60, start: 0, duration: 0.47), RawNote(pitch: 62, start: 0.52, duration: 0.41),
                     RawNote(pitch: 64, start: 6.0, duration: 0.52), RawNote(pitch: 65, start: 6.6, duration: 0.44)]
        let lesson = try! XCTUnwrap(ListenTranscriber.lesson(from: heard, hand: .right))
        XCTAssertLessThan(lesson.notes[2].timestamp, 3, "a 5 s pause is shortened")
        XCTAssertTrue(lesson.notes.allSatisfy { $0.duration >= 0.25 * 0.3 })
        XCTAssertEqual(lesson.notes.map(\.noteNumber).count, 4)
    }
}

final class SmoothingAndVotingTests: XCTestCase {
    private func frame(_ time: TimeInterval, hands: [TrackedHand], channel: CameraChannelID = .overhead) -> HandFrame {
        HandFrame(channel: channel, timestamp: time, imageSize: CGSize(width: 1920, height: 1080), hands: hands)
    }

    private func hand(id: Int = 0, side: HandSide? = .right, wrist: CGPoint, tips: [Finger: CGPoint] = [:]) -> TrackedHand {
        var joints: [JointID: TrackedJoint] = [.wrist: TrackedJoint(point: wrist, confidence: 0.9)]
        for (finger, point) in tips { joints[JointID.tip(of: finger)] = TrackedJoint(point: point, confidence: 0.9) }
        return TrackedHand(id: id, side: side, joints: joints)
    }

    private func stdDev(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    // MARK: M9 — jitter

    func testJitterAtRestIsCutByMoreThanHalf() {
        var smoother = HandSmoother()
        var generator = SeededGenerator(seed: 3)
        var raw: [Double] = []
        var smoothed: [Double] = []
        for i in 0..<120 {
            let noisy = 0.5 + Double.random(in: -0.006...0.006, using: &generator)
            let output = smoother.smooth(frame(Double(i) / 30, hands: [hand(wrist: CGPoint(x: noisy, y: 0.5), tips: [.index: CGPoint(x: noisy, y: 0.4)])]))
            if i >= 30 {
                raw.append(noisy)
                smoothed.append(Double(output.hands[0].tip(of: .index)!.point.x))
            }
        }
        XCTAssertLessThan(stdDev(smoothed), 0.5 * stdDev(raw), "σ raw \(stdDev(raw)) smoothed \(stdDev(smoothed))")
    }

    func testFastMovementIsFollowedWithoutLargeLag() {
        var smoother = HandSmoother()
        var lastError = 0.0
        for i in 0..<60 {
            let x = 0.2 + Double(i) / 60 * 0.6    // 0.6 of the picture in 2 s = 0.3 units/s
            let output = smoother.smooth(frame(Double(i) / 30, hands: [hand(wrist: CGPoint(x: x, y: 0.5), tips: [.index: CGPoint(x: x, y: 0.4)])]))
            lastError = abs(Double(output.hands[0].tip(of: .index)!.point.x) - x)
        }
        XCTAssertLessThan(lastError, 0.02, "lag while moving")
    }

    func testAJumpIsFollowedQuickly() {
        var smoother = HandSmoother()
        for i in 0..<10 { _ = smoother.smooth(frame(Double(i) / 30, hands: [hand(wrist: CGPoint(x: 0.3, y: 0.5), tips: [.index: CGPoint(x: 0.3, y: 0.4)])])) }
        var x = 0.0
        for i in 10..<20 {
            let output = smoother.smooth(frame(Double(i) / 30, hands: [hand(wrist: CGPoint(x: 0.4, y: 0.5), tips: [.index: CGPoint(x: 0.4, y: 0.4)])]))
            x = Double(output.hands[0].tip(of: .index)!.point.x)
        }
        XCTAssertEqual(x, 0.4, accuracy: 0.01, "settled within ~10 frames of a real move")
    }

    func testHandIdentityIsStableEvenWhenDetectionOrderSwaps() {
        var smoother = HandSmoother()
        let left = CGPoint(x: 0.3, y: 0.7), right = CGPoint(x: 0.7, y: 0.7)
        let first = smoother.smooth(frame(0, hands: [hand(id: 0, side: .left, wrist: left), hand(id: 1, side: .right, wrist: right)]))
        let swapped = smoother.smooth(frame(0.033, hands: [hand(id: 0, side: .right, wrist: right), hand(id: 1, side: .left, wrist: left)]))
        let idForSide = { (frame: HandFrame, side: HandSide) in frame.hands.first { $0.side == side }!.id }
        XCTAssertEqual(idForSide(first, .left), idForSide(swapped, .left))
        XCTAssertEqual(idForSide(first, .right), idForSide(swapped, .right))
        XCTAssertNotEqual(idForSide(swapped, .left), idForSide(swapped, .right))
    }

    func testAHandThatReturnsAfterALongAbsenceStartsFresh() {
        var smoother = HandSmoother()
        let a = smoother.smooth(frame(0, hands: [hand(wrist: CGPoint(x: 0.3, y: 0.5), tips: [.index: CGPoint(x: 0.3, y: 0.4)])]))
        _ = smoother.smooth(frame(2, hands: []))
        let b = smoother.smooth(frame(2.1, hands: [hand(wrist: CGPoint(x: 0.9, y: 0.5), tips: [.index: CGPoint(x: 0.9, y: 0.4)])]))
        XCTAssertNotEqual(a.hands[0].id, b.hands[0].id)
        XCTAssertEqual(Double(b.hands[0].tip(of: .index)!.point.x), 0.9, accuracy: 1e-9, "no glide from a stale position")
    }

    func testSmoothingKeepsConfidenceSideAndSize() {
        var smoother = HandSmoother()
        let out = smoother.smooth(frame(0, hands: [hand(side: .left, wrist: CGPoint(x: 0.5, y: 0.5))]))
        XCTAssertEqual(out.hands[0].side, .left)
        XCTAssertEqual(out.hands[0].joint(.wrist)?.confidence, 0.9)
        XCTAssertEqual(out.imageSize, CGSize(width: 1920, height: 1080))
    }

    // MARK: M10 — multi-frame voting

    private var region: KeyboardRegion {
        let first = Double(PianoKeys.whiteIndex(36))
        let slope = 20.0
        return KeyboardRegion(firstNote: 36, lastNote: 96, slope: slope, intercept: PianoKeys.center(of: 60) - slope * 0.4 - first,
                              yMin: 0.4, yMax: 0.8, isCalibrated: true)
    }

    func testVotingOutvotesASingleNoisyFrame() {
        let x62 = region.x(ofNote: 62)
        var frames: [HandFrame] = []
        for i in 0..<5 {
            // Index finger sits on the key; middle finger is 0.6 keys away… except in frame 2, where noise puts it right on the key.
            let middle = i == 2 ? x62 + 0.02 / 20 : x62 + 0.6 / 20
            let index = i == 2 ? x62 + 0.3 / 20 : x62
            frames.append(frame(Double(i) * 0.033, hands: [hand(wrist: CGPoint(x: x62, y: 0.9), tips: [.index: CGPoint(x: index, y: 0.5), .middle: CGPoint(x: middle, y: 0.5)])]))
        }
        let attributor = FingerAttributor()
        XCTAssertEqual(attributor.attribute(note: 62, frame: frames[2], region: region)?.finger, .middle, "a single noisy frame is wrong…")
        XCTAssertEqual(attributor.attribute(note: 62, frames: frames, region: region)?.finger, .index, "…the vote is right")
    }

    func testVotingRequiresTheFingerInHalfTheFrames() {
        let x = region.x(ofNote: 62)
        let seen = frame(0, hands: [hand(wrist: CGPoint(x: x, y: 0.9), tips: [.index: CGPoint(x: x, y: 0.5)])])
        let unseen = [frame(0.03, hands: []), frame(0.06, hands: []), frame(0.09, hands: [])]
        XCTAssertNil(FingerAttributor().attribute(note: 62, frames: [seen] + unseen, region: region))
        XCTAssertEqual(FingerAttributor().attribute(note: 62, frames: [seen], region: region)?.finger, .index)
        XCTAssertNil(FingerAttributor().attribute(note: 62, frames: [], region: region))
    }

    func testVotingKeepsTwoHandsApartByIdentity() {
        let x = region.x(ofNote: 62)
        var frames: [HandFrame] = []
        for i in 0..<4 {
            frames.append(frame(Double(i) * 0.03, hands: [
                hand(id: 0, side: .left, wrist: CGPoint(x: x, y: 0.9), tips: [.thumb: CGPoint(x: x + 0.8 / 20, y: 0.5)]),
                hand(id: 1, side: .right, wrist: CGPoint(x: x, y: 0.9), tips: [.index: CGPoint(x: x + 0.1 / 20, y: 0.5)])]))
        }
        let result = FingerAttributor().attribute(note: 62, frames: frames, region: region)
        XCTAssertEqual(result?.finger, .index)
        XCTAssertEqual(result?.hand, .right)
    }

    // MARK: Latency meter

    func testLatencyPercentiles() {
        let meter = LatencyMeter(capacity: 200)
        XCTAssertNil(meter.percentile(50))
        for ms in 1...100 { meter.record(milliseconds: Double(ms)) }
        XCTAssertEqual(meter.percentile(50), 50)
        XCTAssertEqual(meter.percentile(95), 95)
        XCTAssertEqual(meter.percentile(100), 100)
        XCTAssertEqual(meter.count, 100)
        for ms in 101...300 { meter.record(milliseconds: Double(ms)) }
        XCTAssertEqual(meter.count, 200, "rolling window")
        meter.reset()
        XCTAssertEqual(meter.count, 0)
    }
}
