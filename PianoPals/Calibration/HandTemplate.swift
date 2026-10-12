import CoreGraphics
import Foundation

/// A hand-print outline shown on screen. The child lays a hand over it and Vision checks the alignment.
struct HandTemplate: Equatable, Sendable {
    let side: HandSide
    /// Where the template is drawn, in normalised preview coordinates (top-left origin).
    let placement: CGRect
    /// Landmark positions inside the unit square of the template (top-left origin).
    let unitJoints: [JointID: CGPoint]

    /// Joints compared during alignment: the wrist and the five fingertips.
    static let matchedJoints: [JointID] = [.wrist, .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]

    /// Right hand, palm down, fingers pointing up, seen from above.
    private static let rightHandUnit: [JointID: CGPoint] = [
        .wrist: CGPoint(x: 0.52, y: 0.97),
        .thumbCMC: CGPoint(x: 0.32, y: 0.80), .thumbMP: CGPoint(x: 0.22, y: 0.68),
        .thumbIP: CGPoint(x: 0.15, y: 0.58), .thumbTip: CGPoint(x: 0.10, y: 0.48),
        .indexMCP: CGPoint(x: 0.38, y: 0.50), .indexPIP: CGPoint(x: 0.37, y: 0.34),
        .indexDIP: CGPoint(x: 0.36, y: 0.23), .indexTip: CGPoint(x: 0.355, y: 0.14),
        .middleMCP: CGPoint(x: 0.52, y: 0.46), .middlePIP: CGPoint(x: 0.52, y: 0.28),
        .middleDIP: CGPoint(x: 0.52, y: 0.16), .middleTip: CGPoint(x: 0.52, y: 0.07),
        .ringMCP: CGPoint(x: 0.65, y: 0.50), .ringPIP: CGPoint(x: 0.66, y: 0.34),
        .ringDIP: CGPoint(x: 0.67, y: 0.24), .ringTip: CGPoint(x: 0.675, y: 0.16),
        .littleMCP: CGPoint(x: 0.76, y: 0.58), .littlePIP: CGPoint(x: 0.80, y: 0.46),
        .littleDIP: CGPoint(x: 0.83, y: 0.38), .littleTip: CGPoint(x: 0.85, y: 0.31)
    ]

    static func make(for side: HandSide) -> HandTemplate {
        let joints: [JointID: CGPoint]
        switch side {
        case .right:
            joints = rightHandUnit
        case .left:
            joints = rightHandUnit.mapValues { CGPoint(x: 1 - $0.x, y: $0.y) }
        }
        // Right hand on the right half of the picture, left hand on the left half.
        let placement = side == .right
            ? CGRect(x: 0.52, y: 0.10, width: 0.36, height: 0.82)
            : CGRect(x: 0.12, y: 0.10, width: 0.36, height: 0.82)
        return HandTemplate(side: side, placement: placement, unitJoints: joints)
    }

    /// Landmark position in normalised preview coordinates.
    func target(for joint: JointID) -> CGPoint? {
        guard let unit = unitJoints[joint] else { return nil }
        return CGPoint(x: placement.minX + unit.x * placement.width, y: placement.minY + unit.y * placement.height)
    }
}

struct TemplateMatch: Equatable, Sendable {
    var handDetected: Bool
    var isAligned: Bool
    /// 0 (nothing alike) … 1 (perfect overlap); drives the outline colour.
    var score: Double
    /// Fingertip positions of the matched hand, in normalised image coordinates.
    var tips: [Finger: CGPoint]
}

enum HandTemplateMatcher {
    /// Tolerances are generous on purpose: this is for 5-year-olds.
    static let shapeTolerance = 0.55
    static let positionTolerance = 1.5   // in multiples of the template's own radius
    static let scaleRange = 0.4...2.4

    /// Finds the detected hand that best fits `template`. `aspectRatio` is the picture's width ÷ height.
    static func match(frame: HandFrame, template: HandTemplate, aspectRatio: Double) -> TemplateMatch {
        let aspect = max(aspectRatio, 0.1)
        func scaled(_ p: CGPoint) -> SIMD2<Double> { SIMD2(Double(p.x) * aspect, Double(p.y)) }

        let targets = HandTemplate.matchedJoints.compactMap { template.target(for: $0) }.map(scaled)
        guard targets.count == HandTemplate.matchedJoints.count else {
            return TemplateMatch(handDetected: false, isAligned: false, score: 0, tips: [:])
        }
        let targetCentre = centroid(targets)
        let targetRadius = rms(targets, around: targetCentre)

        var best = TemplateMatch(handDetected: false, isAligned: false, score: 0, tips: [:])
        for hand in frame.hands {
            let points = HandTemplate.matchedJoints.compactMap { joint -> SIMD2<Double>? in
                guard let tracked = hand.joint(joint), tracked.confidence >= 0.3 else { return nil }
                return scaled(tracked.point)
            }
            guard points.count == HandTemplate.matchedJoints.count else { continue }

            let centre = centroid(points)
            let radius = rms(points, around: centre)
            guard radius > 1e-6, targetRadius > 1e-6 else { continue }

            var squared = 0.0
            for (point, target) in zip(points, targets) {
                let a = (point - centre) / radius
                let b = (target - targetCentre) / targetRadius
                let delta = a - b
                squared += delta.x * delta.x + delta.y * delta.y
            }
            let shapeError = (squared / Double(points.count)).squareRoot()
            let offset = centre - targetCentre
            let positionError = (offset.x * offset.x + offset.y * offset.y).squareRoot() / targetRadius
            let scale = radius / targetRadius

            let aligned = shapeError <= shapeTolerance && positionError <= positionTolerance && scaleRange.contains(scale)
            let score = max(0, 1 - shapeError / 0.9) * max(0, 1 - positionError / 2.5)
            if score >= best.score || !best.handDetected {
                var tips: [Finger: CGPoint] = [:]
                for finger in Finger.allCases { if let tip = hand.tip(of: finger) { tips[finger] = tip.point } }
                best = TemplateMatch(handDetected: true, isAligned: aligned, score: score, tips: tips)
            }
        }
        return best
    }

    private static func centroid(_ points: [SIMD2<Double>]) -> SIMD2<Double> {
        points.reduce(SIMD2<Double>(0, 0), +) / Double(points.count)
    }

    private static func rms(_ points: [SIMD2<Double>], around centre: SIMD2<Double>) -> Double {
        let sum = points.reduce(0.0) { partial, point in
            let d = point - centre
            return partial + d.x * d.x + d.y * d.y
        }
        return (sum / Double(points.count)).squareRoot()
    }
}
