import CoreGraphics
import Foundation

/// Keeps the keyboard region lined up with the real keys while the child plays.
///
/// Calibration is a snapshot: if the camera is bumped, tilted or moved nearer, the overlay stays where it was. Every time a white key
/// is struck we see where the fingertip over it really is in the picture, compare that with where the region says the key should be, and
/// nudge the region. A shift is corrected from a few strikes; a change of scale (the camera moved nearer or farther) needs strikes across
/// at least a quarter of the keyboard. Corrections are gradual (half of the error each time) and limited, so one odd frame cannot throw
/// the overlay across the keyboard.
struct RegionAutoAligner: Sendable {
    /// How many recent strikes are kept as evidence.
    var windowSize = 20
    /// Only fingertips within this many white keys of the struck key count (the pressing finger is the lowest one among them).
    /// Wide on purpose: after a zoom the far keys are several keys off, and a narrow window would never see them.
    var searchRadius = 6.0
    /// Errors smaller than this (white keys) are left alone, so the overlay does not hunt.
    var deadBand = 0.12
    /// Share of the error removed per correction.
    var gain = 0.5
    /// Largest total sideways move from the calibrated position (white keys) and largest change of scale.
    var maxShift = 2.0
    var maxScaleChange = 0.3
    var minimumTipConfidence: Float = 0.4

    private(set) var baseline: KeyboardRegion
    private var samples: [(x: Double, expected: Double)] = []

    init(baseline: KeyboardRegion) { self.baseline = baseline }

    /// Returns a corrected region when the strikes show the picture has moved; nil when nothing needs changing.
    mutating func ingest(note: Int, frames: [HandFrame], region: KeyboardRegion) -> KeyboardRegion? {
        guard region.isCalibrated, !PianoKeys.isBlack(note), (region.firstNote...region.lastNote).contains(note) else { return nil }
        let expected = region.position(ofNote: note)

        // The pressing finger is the lowest fingertip near the key. Median over the frames around the strike.
        var xs: [Double] = []
        for frame in frames {
            var lowest: TrackedJoint?
            for hand in frame.hands {
                for finger in Finger.allCases {
                    guard let tip = hand.tip(of: finger), tip.confidence >= minimumTipConfidence,
                          abs(region.whitePosition(forX: Double(tip.point.x)) - expected) <= searchRadius else { continue }
                    if lowest == nil || tip.point.y > lowest!.point.y { lowest = tip }
                }
            }
            if let lowest { xs.append(Double(lowest.point.x)) }
        }
        guard !xs.isEmpty else { return nil }
        samples.append((Self.median(xs), expected))
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        guard samples.count >= 5 else { return nil }

        let residual = Self.median(samples.map { region.whitePosition(forX: $0.x) - $0.expected })
        guard abs(residual) > deadBand else { return nil }

        // Target: a full line fit when the strikes cover enough of the keyboard, otherwise just the sideways shift.
        var targetSlope = region.slope
        var targetIntercept = region.intercept - residual
        let spread = (samples.map(\.x).max() ?? 0) - (samples.map(\.x).min() ?? 0)
        if samples.count >= 10, spread >= 0.25, let fit = Self.lineFit(samples),
           fit.slope * baseline.slope > 0, abs(fit.slope / baseline.slope - 1) <= maxScaleChange, fit.rms <= 0.6 {
            targetSlope = fit.slope
            targetIntercept = fit.intercept
        }

        var corrected = region
        corrected.slope = region.slope + gain * (targetSlope - region.slope)
        corrected.intercept = region.intercept + gain * (targetIntercept - region.intercept)
        corrected = limited(corrected)
        // The strikes stay as evidence: (fingertip position, key) pairs do not depend on the region, and once the region agrees with
        // them the dead band stops further corrections. Old strikes age out of the window if the camera moves again.
        return corrected == region ? nil : corrected
    }

    /// Keeps the change from the calibrated region within `maxShift` and `maxScaleChange`.
    private func limited(_ region: KeyboardRegion) -> KeyboardRegion {
        var result = region
        let lowest = baseline.slope * (1 - maxScaleChange), highest = baseline.slope * (1 + maxScaleChange)
        result.slope = min(max(result.slope, min(lowest, highest)), max(lowest, highest))
        let shift = result.whitePosition(forX: 0.5) - baseline.whitePosition(forX: 0.5)
        if abs(shift) > maxShift { result.intercept -= shift - (shift > 0 ? maxShift : -maxShift) }
        return result
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func lineFit(_ samples: [(x: Double, expected: Double)]) -> (slope: Double, intercept: Double, rms: Double)? {
        let n = Double(samples.count)
        let meanX = samples.map(\.x).reduce(0, +) / n, meanP = samples.map(\.expected).reduce(0, +) / n
        let variance = samples.map { ($0.x - meanX) * ($0.x - meanX) }.reduce(0, +)
        guard variance > 1e-6 else { return nil }
        let slope = samples.map { ($0.x - meanX) * ($0.expected - meanP) }.reduce(0, +) / variance
        let intercept = meanP - slope * meanX
        let rms = (samples.map { pow(slope * $0.x + intercept - $0.expected, 2) }.reduce(0, +) / n).squareRoot()
        return (slope, intercept, rms)
    }
}
