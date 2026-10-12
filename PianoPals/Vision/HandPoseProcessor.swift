import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Everything the Vision pass over one video frame produced.
struct VisionResult: Sendable {
    var hands: HandFrame
    var face: FaceExpression?
}

/// Runs `VNDetectHumanHandPoseRequest` (and, when asked, face landmarks) on camera frames.
///
/// One instance belongs to one camera channel and must be driven from that channel's serial capture queue, which gives
/// natural back-pressure: with `alwaysDiscardsLateVideoFrames` the camera drops frames the processor cannot keep up
/// with, so each channel runs at the fastest rate the device sustains (up to the camera's 30 / 60 fps).
final class HandPoseProcessor {
    let channel: CameraChannelID
    var minimumJointConfidence: Float = 0.3

    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var meter = FrameRateMeter()
    private(set) var framesPerSecond: Double = 0

    init(channel: CameraChannelID) {
        self.channel = channel
    }

    /// Processes a frame whose pixels are already upright (the capture connection applies rotation / mirroring).
    func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, mirrored: Bool, detectFace: Bool) -> VisionResult {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var requests: [VNRequest] = [handRequest]
        if detectFace { requests.append(faceRequest) }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        do {
            try handler.perform(requests)
        } catch {
            framesPerSecond = meter.tick(at: timestamp)
            return VisionResult(hands: HandFrame(channel: channel, timestamp: timestamp, imageSize: size, hands: []), face: nil)
        }
        framesPerSecond = meter.tick(at: timestamp)

        let observations = handRequest.results ?? []
        let hands: [TrackedHand] = observations.enumerated().compactMap { index, observation in
            guard let points = try? observation.recognizedPoints(.all) else { return nil }
            var raw: [JointID: (CGPoint, Float)] = [:]
            for (name, point) in points {
                guard let id = HandPoseProcessor.jointID(for: name) else { continue }
                raw[id] = (point.location, point.confidence)
            }
            let chirality: HandSide?
            switch observation.chirality {
            case .left: chirality = .left
            case .right: chirality = .right
            default: chirality = nil
            }
            return HandPoseProcessor.makeHand(id: index, rawJoints: raw, chirality: chirality, mirrored: mirrored,
                                              minimumConfidence: minimumJointConfidence)
        }

        var face: FaceExpression?
        if detectFace {
            face = FaceExpressionEstimator.estimate(from: faceRequest.results ?? [])
        }
        return VisionResult(hands: HandFrame(channel: channel, timestamp: timestamp, imageSize: size, hands: hands), face: face)
    }

    // MARK: Conversion (pure, unit-tested)

    /// Converts Vision's lower-left-origin joints into top-left-origin `TrackedHand` joints.
    ///
    /// Vision determines handedness from how the picture looks, so a mirrored picture (front camera as a mirror)
    /// reports the opposite hand; `mirrored` swaps it back to the child's real hand.
    static func makeHand(id: Int, rawJoints: [JointID: (location: CGPoint, confidence: Float)], chirality: HandSide?,
                         mirrored: Bool, minimumConfidence: Float) -> TrackedHand? {
        var joints: [JointID: TrackedJoint] = [:]
        for (jointID, value) in rawJoints where value.confidence >= minimumConfidence {
            joints[jointID] = TrackedJoint(point: CGPoint(x: value.location.x, y: 1 - value.location.y), confidence: value.confidence)
        }
        guard !joints.isEmpty else { return nil }
        let side = mirrored ? chirality?.opposite : chirality
        return TrackedHand(id: id, side: side, joints: joints)
    }

    static func jointID(for name: VNHumanHandPoseObservation.JointName) -> JointID? {
        switch name {
        case .wrist: return .wrist
        case .thumbCMC: return .thumbCMC
        case .thumbMP: return .thumbMP
        case .thumbIP: return .thumbIP
        case .thumbTip: return .thumbTip
        case .indexMCP: return .indexMCP
        case .indexPIP: return .indexPIP
        case .indexDIP: return .indexDIP
        case .indexTip: return .indexTip
        case .middleMCP: return .middleMCP
        case .middlePIP: return .middlePIP
        case .middleDIP: return .middleDIP
        case .middleTip: return .middleTip
        case .ringMCP: return .ringMCP
        case .ringPIP: return .ringPIP
        case .ringDIP: return .ringDIP
        case .ringTip: return .ringTip
        case .littleMCP: return .littleMCP
        case .littlePIP: return .littlePIP
        case .littleDIP: return .littleDIP
        case .littleTip: return .littleTip
        default: return nil
        }
    }
}

/// Exponentially smoothed frames-per-second estimate.
struct FrameRateMeter {
    private var lastTimestamp: TimeInterval?
    private var smoothed: Double = 0

    mutating func tick(at timestamp: TimeInterval) -> Double {
        defer { lastTimestamp = timestamp }
        guard let last = lastTimestamp, timestamp > last else { return smoothed }
        let instantaneous = 1 / (timestamp - last)
        smoothed = smoothed == 0 ? instantaneous : smoothed * 0.9 + instantaneous * 0.1
        return smoothed
    }
}
