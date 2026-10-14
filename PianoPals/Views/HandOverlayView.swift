import SwiftUI

/// Draws the tracked hand skeleton and puts a numbered, coloured circle on each fingertip.
struct HandOverlayView: View {
    let frame: HandFrame?
    var highlight: Finger?
    /// Fades the overlay out if no new frame has arrived for a moment (hand left the picture).
    var staleAfter: TimeInterval = 0.5
    /// `true` when the picture underneath is shown aspect-fit (letterboxed) rather than aspect-fill (cropped).
    var fit = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: frame == nil)) { context in
            Canvas { canvas, size in
                guard let frame else { return }
                let age = HostClock.now - frame.timestamp
                guard age < staleAfter else { return }
                let pulse = 1 + 0.18 * sin(context.date.timeIntervalSinceReferenceDate * 7)
                for hand in frame.hands { draw(hand, imageSize: frame.imageSize, canvas: &canvas, size: size, pulse: pulse) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ hand: TrackedHand, imageSize: CGSize, canvas: inout GraphicsContext, size: CGSize, pulse: Double) {
        let radius = max(15, size.height * 0.04)
        func point(_ joint: TrackedJoint, _ size: CGSize) -> CGPoint {
            OverlayGeometry.viewPoint(joint.point, imageSize: imageSize, viewSize: size, fit: fit)
        }

        for (a, b) in JointID.bones {
            guard let ja = hand.joint(a), let jb = hand.joint(b) else { continue }
            var path = Path()
            path.move(to: point(ja, size))
            path.addLine(to: point(jb, size))
            canvas.stroke(path, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            canvas.stroke(path, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        for id in JointID.allCases where !id.isFingertip {
            guard let joint = hand.joint(id) else { continue }
            let p = point(joint, size)
            canvas.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.white))
        }
        for finger in Finger.allCases {
            guard let tip = hand.tip(of: finger) else { continue }
            let p = point(tip, size)
            if finger == highlight {
                let ring = radius * 1.7 * pulse
                canvas.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                              with: .color(.white), lineWidth: 5)
            }
            let circle = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            canvas.fill(circle, with: .color(finger.color))
            canvas.stroke(circle, with: .color(.white), lineWidth: 3.5)
            canvas.draw(Text("\(finger.number)").font(.kid(radius * 1.15)).foregroundStyle(.white), at: p)
        }
    }
}
