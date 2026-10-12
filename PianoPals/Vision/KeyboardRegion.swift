import CoreGraphics
import Foundation

/// A point expressed in the coordinate space of the physical keyboard.
struct KeyboardPoint: Equatable, Sendable {
    /// 0 at the left edge of the lowest key, 1 at the right edge of the highest key (clamped).
    var along: Double
    /// 0 at the back (far) edge of the keys, 1 at the front edge (clamped).
    var across: Double
    /// Whether the original point fell inside the keyboard's bounding box.
    var isInside: Bool
}

/// Where the physical keyboard sits inside one camera's picture.
///
/// Horizontal position is a linear map from image x to "white-key position" (0 = left edge of the lowest
/// white key). The sign of `slope` handles cameras that see the keyboard reversed.
struct KeyboardRegion: Codable, Equatable, Sendable {
    var firstNote: Int
    var lastNote: Int
    /// White keys per unit of normalised image x.
    var slope: Double
    /// White-key position at image x = 0.
    var intercept: Double
    /// Vertical band (normalised, top-left origin) where the keys appear.
    var yMin: Double
    var yMax: Double
    var isCalibrated: Bool

    var whiteKeyCount: Int { max(PianoKeys.whiteKeyCount(from: firstNote, to: lastNote), 1) }
    private var firstWhiteIndex: Int { PianoKeys.whiteIndex(firstNote) }

    /// An uncalibrated guess: the keyboard spans the full width of the picture, in the lower part.
    static func uncalibrated(firstNote: Int, lastNote: Int) -> KeyboardRegion {
        let count = max(PianoKeys.whiteKeyCount(from: firstNote, to: lastNote), 1)
        return KeyboardRegion(firstNote: firstNote, lastNote: lastNote, slope: Double(count), intercept: 0,
                              yMin: 0.4, yMax: 1.0, isCalibrated: false)
    }

    func whitePosition(forX x: Double) -> Double { slope * x + intercept }

    func x(forWhitePosition position: Double) -> Double {
        guard abs(slope) > 1e-9 else { return 0.5 }
        return (position - intercept) / slope
    }

    /// Centre of `note` in white-key units relative to the lowest white key.
    func position(ofNote note: Int) -> Double { PianoKeys.center(of: note) - Double(firstWhiteIndex) }

    /// Normalised image x of the centre of `note`.
    func x(ofNote note: Int) -> Double { x(forWhitePosition: position(ofNote: note)) }

    /// The keyboard's bounding box in normalised image coordinates.
    var boundingBox: CGRect {
        let left = x(forWhitePosition: 0)
        let right = x(forWhitePosition: Double(whiteKeyCount))
        let minX = min(left, right)
        return CGRect(x: minX, y: yMin, width: abs(right - left), height: max(yMax - yMin, 0.0001))
    }

    /// Maps an image point into keyboard space, clamped to 0…1.
    func normalize(_ point: CGPoint) -> KeyboardPoint {
        let along = whitePosition(forX: Double(point.x)) / Double(whiteKeyCount)
        let height = max(yMax - yMin, 0.0001)
        let across = (Double(point.y) - yMin) / height
        let inside = (0...1).contains(along) && (0...1).contains(across)
        return KeyboardPoint(along: min(max(along, 0), 1), across: min(max(across, 0), 1), isInside: inside)
    }
}

enum KeyboardRegionFitter {
    struct Sample: Equatable, Sendable {
        var x: Double
        var y: Double
        /// Absolute white-key position of the key this fingertip is expected to rest on.
        var expectedWhitePosition: Double
    }

    /// Least-squares fit of `expected = slope * x + intercept`. Returns nil when the fit is implausible.
    static func fit(samples: [Sample], firstNote: Int, lastNote: Int) -> KeyboardRegion? {
        guard samples.count >= 4 else { return nil }
        let n = Double(samples.count)
        let meanX = samples.map(\.x).reduce(0, +) / n
        let meanP = samples.map(\.expectedWhitePosition).reduce(0, +) / n
        let varianceX = samples.map { ($0.x - meanX) * ($0.x - meanX) }.reduce(0, +)
        guard varianceX > 1e-6 else { return nil }
        let covariance = samples.map { ($0.x - meanX) * ($0.expectedWhitePosition - meanP) }.reduce(0, +)
        let slope = covariance / varianceX
        let absoluteIntercept = meanP - slope * meanX

        // Sanity: a white key should span between ~1/80 and ~1/3 of the picture width.
        guard abs(slope) >= 3, abs(slope) <= 80 else { return nil }
        let residuals = samples.map { sample -> Double in
            let predicted = slope * sample.x + absoluteIntercept
            return (predicted - sample.expectedWhitePosition) * (predicted - sample.expectedWhitePosition)
        }
        let rms = (residuals.reduce(0, +) / n).squareRoot()
        guard rms <= 0.9 else { return nil }

        let meanY = samples.map(\.y).reduce(0, +) / n
        let band = 0.18
        return KeyboardRegion(firstNote: firstNote, lastNote: lastNote, slope: slope,
                              intercept: absoluteIntercept - Double(PianoKeys.whiteIndex(firstNote)),
                              yMin: max(meanY - band, 0), yMax: min(meanY + band, 1), isCalibrated: true)
    }
}
