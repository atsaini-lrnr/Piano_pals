import CoreGraphics
@testable import PianoPals

/// Helpers that only tests need.
extension OverlayGeometry {
    /// The rectangle the picture occupies in the view (may extend beyond it when cropped).
    static func pictureRect(imageSize: CGSize, viewSize: CGSize, fit: Bool) -> CGRect {
        let topLeft = viewPoint(.zero, imageSize: imageSize, viewSize: viewSize, fit: fit)
        let bottomRight = viewPoint(CGPoint(x: 1, y: 1), imageSize: imageSize, viewSize: viewSize, fit: fit)
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }
}

extension CoachPhrases {
    /// Every phrase with sample values filled in (used by the safety test).
    static var allExpanded: [String] {
        var all: [String] = []
        for template in nearMiss { all += ["left", "right"].map { String(format: template, $0) } }
        for template in fingerTip { for finger in Finger.allCases { all.append(formatFinger(template, finger)) } }
        for template in handTip { all += ["left", "right"].map { String(format: template, $0) } }
        for template in practiceNext { all += Finger.allCases.map { String(format: template, $0.kidName) } }
        all += lookForGlow + hesitation + slower + waitForMe + streak + finish + replay
        return all
    }
}
