import CoreGraphics
import Foundation

/// A strip cut out of the camera picture so that the real keys line up, key for key, with the on-screen keyboard below it.
struct AlignedCrop: Equatable, Sendable {
    /// Normalised rectangle of the picture that is shown (0…1, top-left origin).
    var rect: CGRect
    /// Width ÷ height of the strip as displayed.
    var aspect: CGFloat
    /// True when the camera sees the keyboard left-to-right reversed, so the strip is mirrored to match the screen.
    var flipX: Bool
}

enum CameraAlignment {
    /// Works out which part of the picture to show so that white key *i* of `span` appears directly above white key *i* of the
    /// on-screen keyboard. Returns nil when the keyboard isn't calibrated for this camera, or when part of the span lies outside
    /// the picture (the caller then falls back to the whole picture).
    static func crop(region: KeyboardRegion, span: KeyboardSpan, imageSize: CGSize, stripAspect: CGFloat) -> AlignedCrop? {
        guard region.isCalibrated, imageSize.width > 0, imageSize.height > 0, stripAspect > 0, abs(region.slope) > 1e-6 else { return nil }
        let startWhite = Double(span.firstWhiteIndex - PianoKeys.whiteIndex(region.firstNote))
        let x0 = region.x(forWhitePosition: startWhite)
        let x1 = region.x(forWhitePosition: startWhite + Double(span.whiteKeyCount))
        let left = min(x0, x1), right = max(x0, x1)
        let width = right - left
        guard width > 0.02, left >= -0.02, right <= 1.02 else { return nil }

        let cropLeft = max(left, 0), cropRight = min(right, 1)
        let cropWidth = cropRight - cropLeft
        // Height follows from the strip's shape so pixels stay square.
        var cropHeight = cropWidth * Double(imageSize.width) / Double(imageSize.height) / Double(stripAspect)
        var aspect = stripAspect
        if cropHeight > 1 {
            cropHeight = 1
            aspect = CGFloat(cropWidth * Double(imageSize.width) / (cropHeight * Double(imageSize.height)))
        }
        // Centre on the keys, a little higher so the fingertips above them are in view.
        let centre = (region.yMin + region.yMax) / 2 - 0.04
        let top = min(max(centre - cropHeight / 2, 0), 1 - cropHeight)
        return AlignedCrop(rect: CGRect(x: cropLeft, y: top, width: cropWidth, height: cropHeight), aspect: aspect, flipX: region.slope < 0)
    }

    /// Where a normalised picture point lands inside the strip, as a fraction (0…1) of the strip's width and height.
    static func stripPoint(_ point: CGPoint, crop: AlignedCrop) -> CGPoint {
        var u = (point.x - crop.rect.minX) / crop.rect.width
        if crop.flipX { u = 1 - u }
        let v = (point.y - crop.rect.minY) / crop.rect.height
        return CGPoint(x: u, y: v)
    }
}

extension OverlayGeometry {
    /// Like `viewPoint`, but for a picture shown as an aligned strip that exactly fills the view.
    static func viewPoint(_ point: CGPoint, crop: AlignedCrop, viewSize: CGSize) -> CGPoint {
        let p = CameraAlignment.stripPoint(point, crop: crop)
        return CGPoint(x: p.x * viewSize.width, y: p.y * viewSize.height)
    }
}
