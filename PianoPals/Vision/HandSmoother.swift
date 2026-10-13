import CoreGraphics
import Foundation

/// One-Euro filter (Casiez et al., 2012): heavy smoothing when a joint is still, light smoothing when it moves fast.
struct OneEuroFilter: Sendable {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff = 1.0

    private var previousValue: Double?
    private var previousDerivative = 0.0
    private var previousTime: TimeInterval?

    init(minCutoff: Double = 1.5, beta: Double = 10) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func reset() {
        previousValue = nil
        previousDerivative = 0
        previousTime = nil
    }

    var lastTime: TimeInterval? { previousTime }

    mutating func filter(_ value: Double, at time: TimeInterval) -> Double {
        guard let last = previousValue, let lastTime = previousTime, time > lastTime else {
            previousValue = value
            previousTime = time
            return value
        }
        let dt = time - lastTime
        let derivative = (value - last) / dt
        let smoothedDerivative = previousDerivative + alpha(derivativeCutoff, dt) * (derivative - previousDerivative)
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let result = last + alpha(cutoff, dt) * (value - last)
        previousValue = result
        previousDerivative = smoothedDerivative
        previousTime = time
        return result
    }

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Steadies jittery joints and gives each hand a stable identity across frames (the camera's own hand order can swap).
struct HandSmoother: Sendable {
    var minCutoff = 1.5
    var beta = 10.0
    /// A hand not seen for this long loses its identity.
    var maxAge: TimeInterval = 0.5
    /// A joint missing this long restarts its filter instead of gliding from a stale position.
    var jointGap: TimeInterval = 0.3
    /// Max wrist travel (normalised) between frames for two detections to be "the same hand".
    var matchDistance = 0.25

    private struct Track {
        var id: Int
        var side: HandSide?
        var wrist: CGPoint
        var lastSeen: TimeInterval
        var x: [JointID: OneEuroFilter] = [:]
        var y: [JointID: OneEuroFilter] = [:]
    }

    private var tracks: [Track] = []
    private var nextID = 0

    mutating func reset() {
        tracks = []
    }

    mutating func smooth(_ frame: HandFrame) -> HandFrame {
        tracks.removeAll { frame.timestamp - $0.lastSeen > maxAge }
        var claimed = Set<Int>()
        var output: [TrackedHand] = []

        for hand in frame.hands {
            let anchor = hand.joint(.wrist)?.point ?? hand.joints.values.first?.point ?? .zero
            let trackIndex = matchingTrack(for: hand, anchor: anchor, excluding: claimed)
                ?? newTrack(side: hand.side, anchor: anchor, time: frame.timestamp)
            claimed.insert(tracks[trackIndex].id)
            tracks[trackIndex].lastSeen = frame.timestamp
            tracks[trackIndex].wrist = anchor
            if let side = hand.side { tracks[trackIndex].side = side }

            var joints: [JointID: TrackedJoint] = [:]
            for (id, joint) in hand.joints {
                var fx = tracks[trackIndex].x[id] ?? OneEuroFilter(minCutoff: minCutoff, beta: beta)
                var fy = tracks[trackIndex].y[id] ?? OneEuroFilter(minCutoff: minCutoff, beta: beta)
                if let last = fx.lastTime, frame.timestamp - last > jointGap { fx.reset(); fy.reset() }
                let point = CGPoint(x: fx.filter(Double(joint.point.x), at: frame.timestamp), y: fy.filter(Double(joint.point.y), at: frame.timestamp))
                tracks[trackIndex].x[id] = fx
                tracks[trackIndex].y[id] = fy
                joints[id] = TrackedJoint(point: point, confidence: joint.confidence)
            }
            output.append(TrackedHand(id: tracks[trackIndex].id, side: hand.side ?? tracks[trackIndex].side, joints: joints))
        }
        return HandFrame(channel: frame.channel, timestamp: frame.timestamp, imageSize: frame.imageSize, hands: output)
    }

    private func matchingTrack(for hand: TrackedHand, anchor: CGPoint, excluding claimed: Set<Int>) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, track) in tracks.enumerated() where !claimed.contains(track.id) {
            if let side = hand.side, let trackSide = track.side, side != trackSide { continue }
            let distance = hypot(Double(anchor.x - track.wrist.x), Double(anchor.y - track.wrist.y))
            if distance <= matchDistance, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    private mutating func newTrack(side: HandSide?, anchor: CGPoint, time: TimeInterval) -> Int {
        tracks.append(Track(id: nextID, side: side, wrist: anchor, lastSeen: time))
        nextID += 1
        return tracks.count - 1
    }
}

/// Rolling latency percentiles (milliseconds), e.g. from a key press until the app has reacted.
final class LatencyMeter: @unchecked Sendable {
    private let samples = Locked<[Double]>([])
    private let capacity: Int

    init(capacity: Int = 200) { self.capacity = capacity }

    func record(milliseconds: Double) {
        samples.withLock {
            $0.append(milliseconds)
            if $0.count > capacity { $0.removeFirst($0.count - capacity) }
        }
    }

    var count: Int { samples.current.count }

    /// Nearest-rank percentile (p in 0…100); nil with no samples.
    func percentile(_ p: Double) -> Double? {
        let sorted = samples.current.sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    func reset() { samples.withLock { $0.removeAll() } }
}
