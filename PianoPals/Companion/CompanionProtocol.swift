import CoreGraphics
import Foundation

/// How the iPhone "camera mode" and the iPad talk. The iPhone watches the keys, finds the hands itself, and sends only
/// hand landmarks (plus an optional small preview picture) over a private peer-to-peer link — no internet, no cloud.
enum CompanionConstants {
    /// Bonjour service name (≤ 15 characters, lowercase letters, digits and hyphens).
    static let serviceType = "pianopals-cam"
    static let protocolVersion = 1
}

/// One hand on the wire: handedness plus 21 joints as a flat `[x, y, confidence] × 21` array (`JointID.allCases` order).
struct WireHand: Codable, Equatable, Sendable {
    /// -1 unknown, 0 left, 1 right.
    var side: Int
    var joints: [Float]

    static let jointOrder: [JointID] = JointID.allCases

    init(side: Int, joints: [Float]) {
        self.side = side
        self.joints = joints
    }

    init(_ hand: TrackedHand) {
        side = hand.side.map { $0 == .left ? 0 : 1 } ?? -1
        var flat = [Float](repeating: 0, count: WireHand.jointOrder.count * 3)
        for (index, id) in WireHand.jointOrder.enumerated() {
            guard let joint = hand.joints[id] else { continue }
            flat[index * 3] = Float(joint.point.x)
            flat[index * 3 + 1] = Float(joint.point.y)
            flat[index * 3 + 2] = joint.confidence
        }
        joints = flat
    }

    func trackedHand(id: Int) -> TrackedHand? {
        guard joints.count == WireHand.jointOrder.count * 3 else { return nil }
        var result: [JointID: TrackedJoint] = [:]
        for (index, jointID) in WireHand.jointOrder.enumerated() {
            let confidence = joints[index * 3 + 2]
            guard confidence > 0 else { continue }
            result[jointID] = TrackedJoint(point: CGPoint(x: CGFloat(joints[index * 3]), y: CGFloat(joints[index * 3 + 1])), confidence: confidence)
        }
        let handedness: HandSide? = side == 0 ? .left : (side == 1 ? .right : nil)
        return TrackedHand(id: id, side: handedness, joints: result)
    }
}

struct WireFrame: Codable, Equatable, Sendable {
    /// Capture time on the *iPhone's* host clock.
    var t: Double
    var w: Int
    var h: Int
    var hands: [WireHand]

    init(t: Double, w: Int, h: Int, hands: [WireHand]) {
        self.t = t
        self.w = w
        self.h = h
        self.hands = hands
    }

    init(_ frame: HandFrame) {
        t = frame.timestamp
        w = Int(frame.imageSize.width)
        h = Int(frame.imageSize.height)
        hands = frame.hands.map(WireHand.init)
    }

    /// Converts to a frame on the iPad's clock.
    func handFrame(channel: CameraChannelID, padTime: TimeInterval) -> HandFrame {
        HandFrame(channel: channel, timestamp: padTime, imageSize: CGSize(width: w, height: h),
                  hands: hands.enumerated().compactMap { $1.trackedHand(id: $0) })
    }
}

enum CompanionMessage: Codable, Equatable, Sendable {
    case hello(name: String, platform: String, version: Int)
    case frame(WireFrame)
    /// A small JPEG of what the iPhone sees, for the picture tile on the iPad.
    case preview(jpeg: Data, w: Int, h: Int)
    case ping(id: UInt32, sent: Double)
    case pong(id: UInt32, echoed: Double, phoneTime: Double)
    /// iPad → iPhone: turn / flip the picture.
    case control(rotation: Int, flip: Bool)
    case bye

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> CompanionMessage { try JSONDecoder().decode(CompanionMessage.self, from: data) }
}

/// Maps the iPhone's clock to the iPad's using ping/pong round trips, so a key press and the hand frame it landed in can
/// be compared even though they're timed by different devices. The lowest-latency round trip is the most trustworthy.
struct ClockSync: Sendable {
    private var samples: [(rtt: Double, offset: Double)] = []
    private let capacity = 12

    /// `offset` = phone clock − iPad clock.
    var offset: Double? { samples.min { $0.rtt < $1.rtt }?.offset }
    var roundTrip: Double? { samples.min { $0.rtt < $1.rtt }?.rtt }
    var hasEstimate: Bool { !samples.isEmpty }

    mutating func record(sentPad: Double, phoneTime: Double, receivedPad: Double) {
        let rtt = receivedPad - sentPad
        guard rtt >= 0, rtt < 2 else { return }
        samples.append((rtt, phoneTime - (sentPad + rtt / 2)))
        if samples.count > capacity { samples.removeFirst() }
    }

    /// iPad-clock time for a phone-clock timestamp; falls back to `arrival` (minus typical transit) before the first estimate.
    func padTime(forPhoneTime phoneTime: Double, arrival: Double) -> Double {
        guard let offset else { return arrival - 0.03 }
        return phoneTime - offset
    }
}

enum CompanionRole {
    /// True on an iPhone, which becomes the camera.
    static var isPhone: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
