import CoreGraphics
import Foundation
import Vision

/// A very coarse read of the child's face, used only to make the cartoon avatar mirror a smile.
/// Nothing here is stored or sent anywhere.
struct FaceExpression: Equatable, Sendable {
    /// 0 = neutral, 1 = broad smile.
    var smile: Double
    /// 0 = mouth closed, 1 = wide open.
    var mouthOpen: Double
}

enum FaceExpressionEstimator {
    /// Uses the largest detected face.
    static func estimate(from observations: [VNFaceObservation]) -> FaceExpression? {
        guard let face = observations.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let landmarks = face.landmarks, let outer = landmarks.outerLips else { return nil }
        let outerPoints = outer.normalizedPoints.map { CGPoint(x: $0.x, y: $0.y) }
        let innerPoints = (landmarks.innerLips?.normalizedPoints ?? []).map { CGPoint(x: $0.x, y: $0.y) }
        return estimate(outerLips: outerPoints, innerLips: innerPoints)
    }

    /// `outerLips` / `innerLips` are in face-bounding-box space (0…1, y pointing up), as Vision reports them.
    static func estimate(outerLips: [CGPoint], innerLips: [CGPoint]) -> FaceExpression? {
        guard outerLips.count >= 6,
              let leftCorner = outerLips.min(by: { $0.x < $1.x }),
              let rightCorner = outerLips.max(by: { $0.x < $1.x }) else { return nil }
        let width = Double(rightCorner.x - leftCorner.x)
        guard width > 0.0001 else { return nil }

        let centreY = outerLips.map { Double($0.y) }.reduce(0, +) / Double(outerLips.count)
        let cornerY = Double(leftCorner.y + rightCorner.y) / 2
        // Corners sitting above the lips' centre line (y up) read as a smile.
        let lift = (cornerY - centreY) / width
        let wideness = clamp((width - 0.38) / 0.16)
        let smile = clamp(0.5 * wideness + 0.5 * clamp(lift / 0.10))

        var open = 0.0
        if innerLips.count >= 4, let top = innerLips.map({ Double($0.y) }).max(), let bottom = innerLips.map({ Double($0.y) }).min() {
            open = clamp(((top - bottom) / width - 0.05) / 0.35)
        }
        return FaceExpression(smile: smile, mouthOpen: open)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
