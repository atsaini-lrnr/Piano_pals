import Foundation

struct DetectedFinger: Equatable, Sendable {
    var finger: Finger
    var hand: HandSide?
    var channel: CameraChannelID
    /// Distance between the fingertip and the struck key, in white-key widths.
    var distance: Double
}

/// Decides which fingertip was over the key at the moment a MIDI Note-On arrived.
struct FingerAttributor: Sendable {
    /// Fingertips farther than this (in white-key widths) from the struck key are ignored.
    var maxDistance = 1.0
    var minimumJointConfidence: Float = 0.3
    /// Two candidates closer than this are treated as a tie and resolved by confidence.
    var tieMargin = 0.1

    func attribute(note: Int, frame: HandFrame, region: KeyboardRegion) -> DetectedFinger? {
        let target = region.position(ofNote: note)
        var best: (candidate: DetectedFinger, confidence: Float)?
        for hand in frame.hands {
            for finger in Finger.allCases {
                guard let tip = hand.tip(of: finger), tip.confidence >= minimumJointConfidence else { continue }
                let position = region.whitePosition(forX: Double(tip.point.x))
                let distance = abs(position - target)
                guard distance <= maxDistance else { continue }
                let candidate = DetectedFinger(finger: finger, hand: hand.side, channel: frame.channel, distance: distance)
                if let current = best {
                    let closer = distance < current.candidate.distance - tieMargin
                    let tied = abs(distance - current.candidate.distance) <= tieMargin
                    if closer || (tied && tip.confidence > current.confidence) {
                        best = (candidate, tip.confidence)
                    }
                } else {
                    best = (candidate, tip.confidence)
                }
            }
        }
        return best?.candidate
    }
}

extension FingerAttributor {
    /// Votes across several frames around the strike: for each (hand, finger) the *mean* distance to the struck key over
    /// the window is used, so a single noisy frame can't flip the answer. Hand identities come from `HandSmoother`.
    func attribute(note: Int, frames: [HandFrame], region: KeyboardRegion) -> DetectedFinger? {
        guard !frames.isEmpty else { return nil }
        struct Key: Hashable { let hand: Int; let finger: Finger }
        struct Accumulator { var distances: [Double] = []; var confidences: [Float] = []; var sides: [HandSide] = [] }
        let target = region.position(ofNote: note)
        var table: [Key: Accumulator] = [:]
        for frame in frames {
            for hand in frame.hands {
                for finger in Finger.allCases {
                    guard let tip = hand.tip(of: finger), tip.confidence >= minimumJointConfidence else { continue }
                    let distance = abs(region.whitePosition(forX: Double(tip.point.x)) - target)
                    var entry = table[Key(hand: hand.id, finger: finger)] ?? Accumulator()
                    entry.distances.append(distance)
                    entry.confidences.append(tip.confidence)
                    if let side = hand.side { entry.sides.append(side) }
                    table[Key(hand: hand.id, finger: finger)] = entry
                }
            }
        }
        let needed = max(1, (frames.count + 1) / 2)
        var best: (key: Key, mean: Double, confidence: Float, sides: [HandSide])?
        for (key, entry) in table where entry.distances.count >= needed {
            let mean = entry.distances.reduce(0, +) / Double(entry.distances.count)
            guard mean <= maxDistance else { continue }
            let confidence = entry.confidences.reduce(0, +) / Float(entry.confidences.count)
            if let current = best {
                let closer = mean < current.mean - tieMargin
                let tied = abs(mean - current.mean) <= tieMargin
                if closer || (tied && confidence > current.confidence) { best = (key, mean, confidence, entry.sides) }
            } else {
                best = (key, mean, confidence, entry.sides)
            }
        }
        guard let winner = best else { return nil }
        let side = [HandSide.left, .right].max { a, b in winner.sides.filter { $0 == a }.count < winner.sides.filter { $0 == b }.count }
        return DetectedFinger(finger: winner.key.finger, hand: winner.sides.isEmpty ? nil : side,
                              channel: frames[0].channel, distance: winner.mean)
    }
}

/// Short rolling buffer of recent hand frames per camera, written from capture queues and read on demand.
final class HandFrameHistory: @unchecked Sendable {
    private let storage = Locked<[CameraChannelID: [HandFrame]]>([:])
    private let window: TimeInterval

    init(window: TimeInterval = 1.5) { self.window = window }

    func append(_ frame: HandFrame) {
        storage.withLock { buffers in
            var frames = buffers[frame.channel, default: []]
            frames.append(frame)
            let cutoff = frame.timestamp - window
            frames.removeAll { $0.timestamp < cutoff }
            buffers[frame.channel] = frames
        }
    }

    func clear() { storage.withLock { $0.removeAll() } }

    func latest(for channel: CameraChannelID) -> HandFrame? {
        storage.withLock { $0[channel]?.last }
    }

    /// The frame whose timestamp is nearest `time`, if it is within `tolerance` seconds.
    func frame(nearest time: TimeInterval, channel: CameraChannelID, tolerance: TimeInterval = 0.15) -> HandFrame? {
        storage.withLock { buffers in
            guard let frames = buffers[channel], !frames.isEmpty else { return nil }
            let best = frames.min { abs($0.timestamp - time) < abs($1.timestamp - time) }
            guard let best, abs(best.timestamp - time) <= tolerance else { return nil }
            return best
        }
    }

    /// All frames for `channel` captured within `[start, end]`, oldest first.
    func frames(from start: TimeInterval, to end: TimeInterval, channel: CameraChannelID) -> [HandFrame] {
        storage.withLock { buffers in (buffers[channel] ?? []).filter { $0.timestamp >= start && $0.timestamp <= end } }
    }

    /// True once a frame captured at or after `time` has arrived for `channel`.
    func hasFrame(atOrAfter time: TimeInterval, channel: CameraChannelID) -> Bool {
        storage.withLock { ($0[channel]?.last?.timestamp ?? -.infinity) >= time }
    }
}
