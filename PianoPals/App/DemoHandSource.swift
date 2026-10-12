import CoreGraphics
import Foundation

/// Builds synthetic hand frames so tracking-dependent UI can be exercised without a camera (e.g. in the Simulator).
enum DemoHandSource {
    static let imageSize = CGSize(width: 1920, height: 1080)

    /// A region that puts middle C at the centre of the picture with ~16 white keys visible.
    static func region(firstNote: Int, lastNote: Int) -> KeyboardRegion {
        let slope = 11.0
        let intercept = PianoKeys.center(of: 60) - Double(PianoKeys.whiteIndex(firstNote)) - slope * 0.5
        return KeyboardRegion(firstNote: firstNote, lastNote: lastNote, slope: slope, intercept: intercept,
                              yMin: 0.45, yMax: 0.85, isCalibrated: true)
    }

    /// A hand hovering over the keys with `finger` positioned over `note`.
    static func playingFrame(channel: CameraChannelID, note: Int, finger: Finger, side: HandSide, region: KeyboardRegion, time: TimeInterval) -> HandFrame {
        // Fingers lie on consecutive white keys; ascending to the right for the right hand, mirrored for the left.
        let direction: Double = side == .right ? 1 : -1
        let basePosition = region.position(ofNote: note)
        var tips: [Finger: CGPoint] = [:]
        for other in Finger.allCases {
            let offset = Double(other.number - finger.number) * direction
            let x = region.x(forWhitePosition: basePosition + offset)
            let bob = 0.012 * sin(time * 3 + Double(other.number))
            tips[other] = CGPoint(x: x, y: 0.58 + (other == finger ? 0.05 : 0) + bob)
        }
        return makeFrame(channel: channel, tips: tips, side: side, time: time)
    }

    /// A hand exactly on the hand-print template, for demoing calibration.
    static func templateFrame(channel: CameraChannelID, template: HandTemplate, time: TimeInterval) -> HandFrame {
        var joints: [JointID: TrackedJoint] = [:]
        for joint in JointID.allCases {
            guard let target = template.target(for: joint) else { continue }
            joints[joint] = TrackedJoint(point: target, confidence: 0.95)
        }
        return HandFrame(channel: channel, timestamp: time, imageSize: imageSize,
                         hands: [TrackedHand(id: 0, side: template.side, joints: joints)])
    }

    private static func makeFrame(channel: CameraChannelID, tips: [Finger: CGPoint], side: HandSide, time: TimeInterval) -> HandFrame {
        var joints: [JointID: TrackedJoint] = [:]
        let meanX = tips.values.map(\.x).reduce(0, +) / CGFloat(max(tips.count, 1))
        let wrist = CGPoint(x: meanX, y: min((tips.values.map(\.y).max() ?? 0.6) + 0.30, 0.98))
        joints[.wrist] = TrackedJoint(point: wrist, confidence: 0.95)
        for finger in Finger.allCases {
            guard let tip = tips[finger] else { continue }
            let knuckle = CGPoint(x: wrist.x + (tip.x - wrist.x) * 0.55, y: wrist.y + (tip.y - wrist.y) * 0.50)
            let chain: [(JointID, CGFloat)]
            switch finger {
            case .thumb: chain = [(.thumbCMC, 0.30), (.thumbMP, 0.55), (.thumbIP, 0.78), (.thumbTip, 1)]
            case .index: chain = [(.indexMCP, 0.50), (.indexPIP, 0.68), (.indexDIP, 0.85), (.indexTip, 1)]
            case .middle: chain = [(.middleMCP, 0.50), (.middlePIP, 0.68), (.middleDIP, 0.85), (.middleTip, 1)]
            case .ring: chain = [(.ringMCP, 0.50), (.ringPIP, 0.68), (.ringDIP, 0.85), (.ringTip, 1)]
            case .pinky: chain = [(.littleMCP, 0.50), (.littlePIP, 0.68), (.littleDIP, 0.85), (.littleTip, 1)]
            }
            _ = knuckle
            for (joint, fraction) in chain {
                let point = CGPoint(x: wrist.x + (tip.x - wrist.x) * fraction, y: wrist.y + (tip.y - wrist.y) * fraction)
                joints[joint] = TrackedJoint(point: point, confidence: 0.95)
            }
        }
        return HandFrame(channel: channel, timestamp: time, imageSize: imageSize, hands: [TrackedHand(id: 0, side: side, joints: joints)])
    }
}
