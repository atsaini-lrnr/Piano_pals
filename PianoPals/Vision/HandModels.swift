import CoreGraphics
import Foundation

enum CameraChannelID: String, Codable, CaseIterable, Sendable, Identifiable {
    case primary
    case overhead

    var id: String { rawValue }
    var displayName: String { self == .primary ? "Front / side view" : "Overhead view" }
}

/// The 21 skeletal landmarks Vision reports for a hand.
enum JointID: CaseIterable, Hashable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    var isFingertip: Bool { Finger.allCases.contains { JointID.tip(of: $0) == self } }

    var finger: Finger? {
        switch self {
        case .wrist: return nil
        case .thumbCMC, .thumbMP, .thumbIP, .thumbTip: return .thumb
        case .indexMCP, .indexPIP, .indexDIP, .indexTip: return .index
        case .middleMCP, .middlePIP, .middleDIP, .middleTip: return .middle
        case .ringMCP, .ringPIP, .ringDIP, .ringTip: return .ring
        case .littleMCP, .littlePIP, .littleDIP, .littleTip: return .pinky
        }
    }

    static func tip(of finger: Finger) -> JointID {
        switch finger {
        case .thumb: return .thumbTip
        case .index: return .indexTip
        case .middle: return .middleTip
        case .ring: return .ringTip
        case .pinky: return .littleTip
        }
    }

    static func knuckle(of finger: Finger) -> JointID {
        switch finger {
        case .thumb: return .thumbCMC
        case .index: return .indexMCP
        case .middle: return .middleMCP
        case .ring: return .ringMCP
        case .pinky: return .littleMCP
        }
    }

    /// Bone segments used to draw the skeleton.
    static let bones: [(JointID, JointID)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.indexMCP, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.middleMCP, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.ringMCP, .littleMCP), (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip)
    ]
}

struct TrackedJoint: Equatable, Sendable {
    /// Normalised image coordinates of the *upright* picture: (0,0) top-left, (1,1) bottom-right.
    var point: CGPoint
    var confidence: Float
}

struct TrackedHand: Equatable, Sendable, Identifiable {
    var id: Int
    /// Which hand Vision believes this is (already corrected for mirrored video); nil when unknown.
    var side: HandSide?
    var joints: [JointID: TrackedJoint]

    func tip(of finger: Finger) -> TrackedJoint? { joints[JointID.tip(of: finger)] }
    func joint(_ id: JointID) -> TrackedJoint? { joints[id] }

    var confidence: Float {
        guard !joints.isEmpty else { return 0 }
        return joints.values.map(\.confidence).reduce(0, +) / Float(joints.count)
    }
}

struct HandFrame: Equatable, Sendable {
    var channel: CameraChannelID
    /// Capture time on the host clock (seconds).
    var timestamp: TimeInterval
    /// Size in pixels of the upright image the landmarks refer to.
    var imageSize: CGSize
    var hands: [TrackedHand]
}
