import XCTest
@testable import PianoPals

final class RegionAutoAlignerTests: XCTestCase {
    private let first = 36, last = 96   // 61 keys

    /// The region the camera really sees: `slope` white keys per picture width, `shift` white keys to the right of the baseline.
    private func truth(slope: Double, shift: Double) -> KeyboardRegion {
        // A zoom happens about the middle of the picture, so the key under x = 0.5 stays put (plus any sideways `shift`).
        KeyboardRegion(firstNote: first, lastNote: last, slope: slope, intercept: -shift + (36 - slope) * 0.5, yMin: 0.4, yMax: 0.9, isCalibrated: true)
    }

    private var baseline: KeyboardRegion { truth(slope: 36, shift: 0) }

    private func strike(_ note: Int, in real: KeyboardRegion, noise: Double = 0, seed: Int = 0) -> [HandFrame] {
        // The pressing fingertip sits over the key as the REAL camera sees it; the other four are higher up and elsewhere.
        let x = real.x(ofNote: note) + noise * Double((seed % 5) - 2) / 2
        func tip(_ f: Finger, _ dx: Double, _ y: Double) -> (JointID, TrackedJoint) { (JointID.tip(of: f), TrackedJoint(point: CGPoint(x: x + dx, y: y), confidence: 0.9)) }
        let joints = Dictionary(uniqueKeysWithValues: [tip(.index, 0, 0.8), tip(.thumb, -0.045, 0.6), tip(.middle, 0.03, 0.55), tip(.ring, 0.06, 0.58), tip(.pinky, 0.09, 0.62)])
        return [HandFrame(channel: .overhead, timestamp: 0, imageSize: CGSize(width: 1920, height: 1080), hands: [TrackedHand(id: 1, side: .right, joints: joints)])]
    }

    private func whiteNotes(_ range: ClosedRange<Int>) -> [Int] { range.filter { !PianoKeys.isBlack($0) } }

    /// Plays `count` strikes cycling over `notes` and returns the region after each correction.
    private func play(_ aligner: inout RegionAutoAligner, start: KeyboardRegion, real: KeyboardRegion, notes: [Int], count: Int, noise: Double = 0) -> KeyboardRegion {
        var region = start
        for i in 0..<count {
            let note = notes[i % notes.count]
            if let corrected = aligner.ingest(note: note, frames: strike(note, in: real, noise: noise, seed: i), region: region) { region = corrected }
        }
        return region
    }

    /// How many white keys the overlay is off for `note`, given the real picture.
    private func error(_ region: KeyboardRegion, real: KeyboardRegion, note: Int) -> Double {
        abs(region.whitePosition(forX: real.x(ofNote: note)) - region.position(ofNote: note))
    }

    func testASidewaysShiftIsCorrectedFromAFewStrikesInOneArea() {
        var aligner = RegionAutoAligner(baseline: baseline)
        let real = truth(slope: 36, shift: 0.8)
        let region = play(&aligner, start: baseline, real: real, notes: whiteNotes(60...67), count: 24)
        for note in whiteNotes(48...84) { XCTAssertLessThan(error(region, real: real, note: note), 0.25, "key \(note)") }
    }

    func testAChangeOfScaleWhenTheCameraMovesNearerIsCorrectedAcrossTheKeyboard() {
        var aligner = RegionAutoAligner(baseline: baseline)
        let real = truth(slope: 32, shift: 0.6)               // keys look about 12 % bigger and are shifted
        let notes = whiteNotes(40...84)
        let region = play(&aligner, start: baseline, real: real, notes: notes, count: 80)
        XCTAssertEqual(region.slope, 32, accuracy: 2.0)
        for note in [43, 55, 67, 79] { XCTAssertLessThan(error(region, real: real, note: note), 0.5, "key \(note)") }
    }

    func testAnAlignedOverlayIsLeftAloneDespiteNoise() {
        var aligner = RegionAutoAligner(baseline: baseline)
        let region = play(&aligner, start: baseline, real: baseline, notes: whiteNotes(48...84), count: 60, noise: 0.004)
        XCTAssertEqual(region.slope, baseline.slope, accuracy: 0.8)
        XCTAssertEqual(region.intercept, baseline.intercept, accuracy: 0.25)
    }

    func testCorrectionsAreGradualAndLimited() {
        var aligner = RegionAutoAligner(baseline: baseline)
        let real = truth(slope: 36, shift: 3.0)               // 3 keys away: more than the 2-key limit
        var region = baseline
        let notes = whiteNotes(60...67)
        var firstStep: Double?
        for i in 0..<40 {
            let note = notes[i % notes.count]
            if let corrected = aligner.ingest(note: note, frames: strike(note, in: real), region: region) {
                if firstStep == nil { firstStep = abs(corrected.intercept - region.intercept) }
                region = corrected
            }
        }
        XCTAssertLessThan(firstStep ?? 99, 2.0, "the first correction removes only part of the error")
        XCTAssertLessThanOrEqual(abs(region.whitePosition(forX: 0.5) - baseline.whitePosition(forX: 0.5)), 2.0 + 1e-6, "never more than 2 keys from the calibration")
    }

    func testBlackKeysUncalibratedRegionsAndKeysOutsideTheRangeAreIgnored() {
        var aligner = RegionAutoAligner(baseline: baseline)
        let real = truth(slope: 36, shift: 0.8)
        XCTAssertNil(aligner.ingest(note: 61, frames: strike(61, in: real), region: baseline), "black key")
        XCTAssertNil(aligner.ingest(note: 30, frames: strike(60, in: real), region: baseline), "below the keyboard")
        var uncalibrated = baseline
        uncalibrated.isCalibrated = false
        for note in whiteNotes(60...80) { XCTAssertNil(aligner.ingest(note: note, frames: strike(note, in: real), region: uncalibrated)) }
    }

    func testLowConfidenceAndMissingHandsGiveNoEvidence() {
        var aligner = RegionAutoAligner(baseline: baseline)
        let real = truth(slope: 36, shift: 0.8)
        let empty = HandFrame(channel: .overhead, timestamp: 0, imageSize: .zero, hands: [])
        var weak = strike(60, in: real)
        weak[0].hands[0].joints = weak[0].hands[0].joints.mapValues { TrackedJoint(point: $0.point, confidence: 0.1) }
        for _ in 0..<12 {
            XCTAssertNil(aligner.ingest(note: 60, frames: [empty], region: baseline))
            XCTAssertNil(aligner.ingest(note: 62, frames: weak, region: baseline))
        }
    }
}
