import AVFoundation
import XCTest
@testable import PianoPals

/// Piano-ish test tone: a few harmonics with a fast decay.
private func tone(_ notes: [(pitch: Int, start: Double, length: Double)], seconds: Double, rate: Double = BasicPitch.sampleRate) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(seconds * rate))
    for note in notes {
        let frequency = 440 * pow(2, Double(note.pitch - 69) / 12)
        let from = Int(note.start * rate), to = min(samples.count, Int((note.start + note.length) * rate))
        guard from < to else { continue }
        for i in from..<to {
            let t = Double(i - from) / rate
            let envelope = min(1, t * 200) * exp(-t * 0.8) * min(1, Double(to - i) / (0.02 * rate))
            var value = 0.0
            for (harmonic, amplitude) in [(1.0, 1.0), (2.0, 0.5), (3.0, 0.25), (4.0, 0.12)] { value += amplitude * sin(2 * .pi * frequency * harmonic * t) }
            samples[i] += Float(0.3 * envelope * value / 1.9)
        }
    }
    return samples
}

private func writeWAV(_ samples: [Float], rate: Double, channels: Int = 1) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).wav")
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for channel in 0..<channels { for i in 0..<samples.count { buffer.floatChannelData![channel][i] = samples[i] } }
    try file.write(from: buffer)
    return url
}

final class BasicPitchWindowTests: XCTestCase {
    func testConstantsMatchTheModel() {
        XCTAssertEqual(BasicPitch.keptFrames, 142)
        XCTAssertEqual(BasicPitch.hopSamples, 36_352)
        XCTAssertEqual(BasicPitch.seconds(forFrame: 86), 86.0 * 256 / 22_050, accuracy: 1e-12)
    }

    func testWindowsCoverTheRecordingAndTheFirstStartsBeforeIt() {
        XCTAssertEqual(BasicPitch.windowStarts(sampleCount: 0), [])
        XCTAssertEqual(BasicPitch.windowStarts(sampleCount: 22_050), [-15 * 256], "one second fits in one window")
        for seconds in [1.0, 2.0, 5.5, 30.0, 89.9] {
            let samples = Int(seconds * 22_050)
            let starts = BasicPitch.windowStarts(sampleCount: samples)
            let frames = Int((Double(samples) / 256).rounded(.up))
            XCTAssertGreaterThanOrEqual(starts.count * BasicPitch.keptFrames, frames, "\(seconds) s covered")
            XCTAssertLessThan((starts.count - 1) * BasicPitch.keptFrames, frames, "no spare window at \(seconds) s")
            for (a, b) in zip(starts, starts.dropFirst()) { XCTAssertEqual(b - a, BasicPitch.hopSamples) }
        }
    }

    func testWindowIsZeroFilledOutsideTheAudio() {
        let samples = [Float](repeating: 1, count: 1_000)
        let first = BasicPitch.window(of: samples, start: -15 * 256)
        XCTAssertEqual(first.count, BasicPitch.windowSamples)
        XCTAssertEqual(first[0], 0)
        XCTAssertEqual(first[15 * 256 - 1], 0)
        XCTAssertEqual(first[15 * 256], 1)
        XCTAssertEqual(first[15 * 256 + 999], 1)
        XCTAssertEqual(first[15 * 256 + 1000], 0)
        XCTAssertEqual(BasicPitch.window(of: samples, start: 10_000).reduce(0, +), 0)
    }

    func testStitchPlacesEveryKeptFrameAtItsGlobalFrame() {
        let samples = 100_000                                  // 391 frames → 3 windows
        let starts = BasicPitch.windowStarts(sampleCount: samples)
        XCTAssertEqual(starts.count, 3)
        // Encode (window, frame) into the value of key 0 so the mapping can be read back.
        let outputs: [[Float]] = starts.indices.map { w in
            (0..<BasicPitch.framesPerWindow).flatMap { f in [Float](repeating: Float(w * 1000 + f), count: BasicPitch.keyCount) }
        }
        let stitched = BasicPitch.stitch(outputs, sampleCount: samples)
        XCTAssertEqual(stitched.frames, 391)
        XCTAssertEqual(stitched.grid[0], 0 * 1000 + 15, "global frame 0 = window 0 frame 15")
        XCTAssertEqual(stitched.grid[141 * 88], 0 * 1000 + 156)
        XCTAssertEqual(stitched.grid[142 * 88], 1 * 1000 + 15, "window 1 continues with no gap or repeat")
        XCTAssertEqual(stitched.grid[390 * 88], 2 * 1000 + 15 + (390 - 284))
        // And the same frame really is the same moment: window start + frame × hop matches the global time.
        let globalFrame = 150
        let window = globalFrame / 142, local = globalFrame % 142 + 15
        XCTAssertEqual(Double(starts[window] + local * 256) / 22_050, BasicPitch.seconds(forFrame: globalFrame), accuracy: 1e-9)
    }
}

final class BasicPitchDecoderTests: XCTestCase {
    private let keys = BasicPitch.keyCount

    /// Builds note/onset grids from simple notes: (key index, first frame, last frame).
    private func grids(_ notes: [(key: Int, from: Int, to: Int)], frames: Int, onsetAt: [(Int, Int)]? = nil) -> (note: [Float], onset: [Float]) {
        var note = [Float](repeating: 0.05, count: frames * keys), onset = [Float](repeating: 0.02, count: frames * keys)
        for n in notes {
            for f in n.from...n.to { note[f * keys + n.key] = 0.8 }
            onset[n.from * keys + n.key] = 0.9
        }
        return (note, onset)
    }

    func testOneNoteHasTheRightPitchAndExactTimes() {
        let g = grids([(48, 40, 100)], frames: 200)
        let notes = BasicPitchDecoder().decode(note: g.note, onset: g.onset, frames: 200)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].pitch, 69, "key 48 = A4")
        XCTAssertEqual(notes[0].start, BasicPitch.seconds(forFrame: 40), accuracy: 1e-9)
        XCTAssertEqual(notes[0].end, BasicPitch.seconds(forFrame: 101), accuracy: 1e-9)
        XCTAssertEqual(notes[0].strength, 0.8, accuracy: 1e-6)
    }

    func testRepeatedNotesOnTheSameKeySplitAtTheirOnsets() {
        var g = grids([(39, 20, 120)], frames: 200)
        g.onset[70 * keys + 39] = 0.9
        let notes = BasicPitchDecoder().decode(note: g.note, onset: g.onset, frames: 200)
        XCTAssertEqual(notes.map(\.pitch), [60, 60])
        XCTAssertEqual(notes[0].end, notes[1].start, accuracy: 1e-9, "first note stops where the second begins")
    }

    func testChordGivesOneNotePerKey() {
        let g = grids([(39, 10, 60), (43, 10, 60), (46, 10, 60)], frames: 100)
        let notes = BasicPitchDecoder().decode(note: g.note, onset: g.onset, frames: 100)
        XCTAssertEqual(notes.map(\.pitch), [60, 64, 67])
    }

    func testQuietGapsInsideANoteAreForgivenButLongOnesEndIt() {
        var g = grids([(30, 10, 100)], frames: 200)
        for f in 40..<48 { g.note[f * keys + 30] = 0.05 }       // 8 quiet frames: forgiven
        XCTAssertEqual(BasicPitchDecoder().decode(note: g.note, onset: g.onset, frames: 200).first?.end ?? 0, BasicPitch.seconds(forFrame: 101), accuracy: 1e-9)
        for f in 40..<60 { g.note[f * keys + 30] = 0.05 }       // 20 quiet frames: note ends at 39
        XCTAssertEqual(BasicPitchDecoder().decode(note: g.note, onset: g.onset, frames: 200).first?.end ?? 0, BasicPitch.seconds(forFrame: 40), accuracy: 1e-9)
    }

    func testWeakOnsetsAndShortBlipsAreIgnored() {
        var g = grids([(20, 10, 40), (25, 10, 14)], frames: 100)      // second is only 5 frames long
        g.onset[10 * keys + 20] = 0.4                                // below the onset threshold
        XCTAssertTrue(BasicPitchDecoder().decode(note: g.note, onset: g.onset, frames: 100).isEmpty)
    }

    func testEmptyAndMismatchedInputs() {
        XCTAssertTrue(BasicPitchDecoder().decode(note: [], onset: [], frames: 0).isEmpty)
        XCTAssertTrue(BasicPitchDecoder().decode(note: [0.1], onset: [0.1], frames: 5).isEmpty)
    }

    func testANoteCrossingAWindowBoundaryStaysOneNote() {
        // Window outputs where the note's activation continues across the 142-frame seam.
        let windowCount = 2
        var note = [[Float]](repeating: [Float](repeating: 0.05, count: BasicPitch.framesPerWindow * keys), count: windowCount)
        var onset = note
        // Global frames 120…170 on key 40. Window 0 kept frames cover global 0…141 (local 15…156); window 1 covers 142…283.
        for g in 120...170 {
            let w = g / 142, local = g % 142 + 15
            note[w][local * keys + 40] = 0.8
        }
        onset[0][(120 + 15) * keys + 40] = 0.9
        let n = BasicPitch.stitch(note, sampleCount: 284 * 256), o = BasicPitch.stitch(onset, sampleCount: 284 * 256)
        let notes = BasicPitchDecoder().decode(note: n.grid, onset: o.grid, frames: n.frames)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].start, BasicPitch.seconds(forFrame: 120), accuracy: 1e-9)
        XCTAssertEqual(notes[0].end, BasicPitch.seconds(forFrame: 171), accuracy: 1e-9)
    }
}

final class HarmonicSuppressionTests: XCTestCase {
    private func note(_ pitch: Int, _ start: Double, _ strength: Float) -> DecodedNote { DecodedNote(pitch: pitch, start: start, end: start + 0.5, strength: strength) }

    func testWeakOvertonesAreDroppedButRealOctavesStay() {
        let heard = [note(60, 1.0, 0.75), note(72, 1.01, 0.45), note(79, 1.0, 0.40), note(84, 1.02, 0.30)]
        XCTAssertEqual(BasicPitchDecoder.suppressingHarmonics(heard).map(\.pitch), [60])
        let octave = [note(60, 1.0, 0.75), note(72, 1.0, 0.72)]
        XCTAssertEqual(BasicPitchDecoder.suppressingHarmonics(octave).map(\.pitch), [60, 72], "a played octave sounds equally strong")
    }

    func testOnlyNotesThatStartTogetherAreCompared() {
        let later = [note(60, 1.0, 0.75), note(72, 2.0, 0.40)]
        XCTAssertEqual(BasicPitchDecoder.suppressingHarmonics(later).map(\.pitch), [60, 72])
        let otherInterval = [note(60, 1.0, 0.75), note(67, 1.0, 0.40)]
        XCTAssertEqual(BasicPitchDecoder.suppressingHarmonics(otherInterval).count, 2, "a fifth is not an overtone")
    }
}

final class AudioImporterTests: XCTestCase {
    func testStereo44kFileBecomesMono22kAndKeepsItsPitch() throws {
        let source = tone([(69, 0, 1.0)], seconds: 1.0, rate: 44_100)
        let url = try writeWAV(source, rate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = try AudioImporter.samples(from: url)
        XCTAssertEqual(Double(samples.count), 22_050, accuracy: 300)
        let estimate = YINPitchDetector(sampleRate: 22_050, frameSize: 2_048).estimate(Array(samples[4_000..<6_048]))
        XCTAssertEqual(Int(YINPitchDetector.midiNote(forFrequency: estimate.frequency ?? 0).rounded()), 69)
    }

    func testBadFilesGiveGentleErrors() throws {
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: text)
        XCTAssertThrowsError(try AudioImporter.samples(from: text)) { XCTAssertEqual($0 as? AudioImportError, .unreadable) }
        let silent = try writeWAV([Float](repeating: 0, count: 22_050), rate: 22_050)
        XCTAssertThrowsError(try AudioImporter.samples(from: silent)) { XCTAssertEqual($0 as? AudioImportError, .empty) }
        let long = try writeWAV(tone([(60, 0, 3)], seconds: 3), rate: 22_050)
        XCTAssertThrowsError(try AudioImporter.samples(from: long, maximumSeconds: 2)) { XCTAssertEqual($0 as? AudioImportError, .tooLong(seconds: 2)) }
    }
}

final class RecordingLessonTests: XCTestCase {
    private func notes(_ pitches: [Int], from start: Double = 0) -> [RawNote] {
        pitches.enumerated().map { RawNote(pitch: $1, start: start + Double($0) * 0.5, duration: 0.45) }
    }

    func testMelodyAboveAndBassBelowMiddleCBecomeTwoLessons() {
        let melody = notes([72, 74, 76, 77, 79, 77, 76, 74])
        let bass = notes([48, 43, 45, 41, 48, 43, 45, 41])
        let lessons = RecordingLessons.lessons(from: melody + bass, title: "Tune", description: "test")
        XCTAssertEqual(lessons.map(\.hand), [.right, .left])
        XCTAssertEqual(lessons[1].title, "Tune (left hand)")
        XCTAssertTrue(lessons.allSatisfy { $0.notes.allSatisfy { (1...5).contains($0.assignedFinger) } })
        XCTAssertTrue(lessons[1].notes.map(\.noteNumber).allSatisfy { $0 <= 60 }, "left hand stays low")
    }

    func testChordsKeepOnlyTheTopNoteForTheTune() {
        let chords = (0..<6).flatMap { i in [72, 76, 79].map { RawNote(pitch: $0 + (i % 2 == 0 ? 0 : 2), start: Double(i) * 0.5, duration: 0.45) } }
        let lessons = RecordingLessons.lessons(from: chords, title: "Chords", description: "test")
        XCTAssertEqual(lessons.count, 1)
        XCTAssertEqual(lessons[0].notes.count, 6, "one tune note per chord")
    }

    func testLowOnlyMusicBecomesOneRightHandLessonMovedUp() {
        let lessons = RecordingLessons.lessons(from: notes([40, 43, 45, 47, 45, 43, 40]), title: "Low", description: "test")
        XCTAssertEqual(lessons.count, 1)
        XCTAssertEqual(lessons[0].hand, .right)
        XCTAssertGreaterThanOrEqual(lessons[0].notes.map(\.noteNumber).min() ?? 0, 52)
    }

    func testTooFewNotesGivesNothing() {
        XCTAssertTrue(RecordingLessons.lessons(from: notes([60, 62]), title: "x", description: "t").isEmpty)
    }
}

final class RecordingTranscriberTests: XCTestCase {
    private let melody: [(pitch: Int, start: Double, length: Double)] = [(60, 0.3, 0.5), (62, 1.0, 0.5), (64, 1.7, 0.5), (65, 2.4, 0.5), (67, 3.1, 0.6)]

    func testSingleVoiceFallbackWorksWithoutTheModel() throws {
        let result = try RecordingTranscriber(model: nil).transcribe(samples: tone(melody, seconds: 4.0), title: "Walk")
        XCTAssertEqual(result.method, .pitchTracker)
        let pitches = result.lessons[0].notes.map(\.noteNumber)
        XCTAssertEqual(pitches.map { $0 - pitches[0] }, [0, 2, 4, 5, 7])
    }

    func testSilenceAndNoiseGiveAGentleError() {
        let noise = (0..<88_200).map { _ in Float.random(in: -0.02...0.02) }
        XCTAssertThrowsError(try RecordingTranscriber(model: nil).transcribe(samples: noise, title: "n")) { XCTAssertEqual($0 as? TranscriptionError, .noNotes) }
        XCTAssertFalse((TranscriptionError.noNotes.errorDescription ?? "").lowercased().contains("wrong"))
    }

    func testTheBundledModelIsInstalled() throws {
        XCTAssertNotNil(BasicPitchModel(bundle: Bundle(for: AppModel.self)), "nmp.mlmodelc must ship in the app")
    }

    func testModelFindsTheNotesOfASyntheticMelody() throws {
        let model = try XCTUnwrap(BasicPitchModel(bundle: Bundle(for: AppModel.self)))
        let result = try RecordingTranscriber(model: model).transcribe(samples: tone(melody, seconds: 4.0), title: "Walk")
        XCTAssertEqual(result.method, .basicPitch)
        let pitches = result.lessons[0].notes.map(\.noteNumber)
        XCTAssertEqual(pitches.map { $0 - pitches[0] }, [0, 2, 4, 5, 7], "C D E F G found in order, nothing extra: \(pitches)")
    }

    func testModelHearsTwoNotesAtOnceAndAMelodyThatCrossesWindows() throws {
        let model = try XCTUnwrap(BasicPitchModel(bundle: Bundle(for: AppModel.self)))
        // C4 + G4 together, then a long melody whose notes straddle the 1.65 s window seam.
        var notes: [(pitch: Int, start: Double, length: Double)] = [(60, 0.2, 1.2), (67, 0.2, 1.2)]
        let tune = [72, 74, 76, 77, 79, 77, 76, 74]
        for (i, p) in tune.enumerated() { notes.append((p, 1.8 + Double(i) * 0.6, 0.5)) }
        let samples = tone(notes, seconds: 7.0)
        let outputs = try windows(samples, model)
        let raw = BasicPitchDecoder().decode(
            note: BasicPitch.stitch(outputs.map(\.note), sampleCount: samples.count).grid,
            onset: BasicPitch.stitch(outputs.map(\.onset), sampleCount: samples.count).grid,
            frames: Int((Double(samples.count) / 256).rounded(.up)))
        XCTAssertGreaterThan(raw.count, 10 + 2, "the raw output does contain weak harmonic ghosts")
        let decoded = BasicPitchDecoder.suppressingHarmonics(raw)
        let early = decoded.filter { $0.start < 1.0 }.map(\.pitch).sorted()
        XCTAssertEqual(early, [60, 67], "both notes of the dyad: \(decoded)")
        XCTAssertEqual(decoded.filter { $0.start > 1.5 }.map(\.pitch), tune, "melody across window seams: \(decoded)")
        for (note, expected) in zip(decoded.filter { $0.start > 1.5 }, 0..<8) {
            XCTAssertEqual(note.start, 1.8 + Double(expected) * 0.6, accuracy: 0.08, "onset time of note \(expected)")
        }
    }

    func testThirtySecondsIsTranscribedWellInsideFifteen() throws {
        let model = try XCTUnwrap(BasicPitchModel(bundle: Bundle(for: AppModel.self)))
        let notes = (0..<40).map { (pitch: 60 + ($0 % 8), start: 0.3 + Double($0) * 0.7, length: 0.5) }
        let samples = tone(notes, seconds: 30)
        let began = Date()
        _ = try RecordingTranscriber(model: model).transcribe(samples: samples, title: "Long")
        let elapsed = Date().timeIntervalSince(began)
        print("T6: 30 s clip transcribed in \(elapsed) s (simulator)")
        XCTAssertLessThan(elapsed, 15)
    }

    private func windows(_ samples: [Float], _ model: BasicPitchModel) throws -> [(note: [Float], onset: [Float])] {
        try BasicPitch.windowStarts(sampleCount: samples.count).map { try model.predict(window: BasicPitch.window(of: samples, start: $0)) }
    }
}
