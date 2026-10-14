import SwiftUI

/// A gentle "use this finger instead" cue for the camera view. Deliberately has no red and no negative wording.
struct FingerCorrection: Equatable {
    let id = UUID()
    let expected: Finger
    /// The finger the camera saw on the key, when known.
    let played: Finger?
    /// Set when the right key was played with the other hand.
    let wrongHand: HandSide?

    static func == (lhs: FingerCorrection, rhs: FingerCorrection) -> Bool { lhs.id == rhs.id }
}

/// Everything the camera tile needs to coach.
struct CoachingContext: Equatable {
    var region: KeyboardRegion
    /// The note the child should play now.
    var target: Note?
    var correction: FingerCorrection?
    var lessonHand: HandSide
}

/// Pure geometry for the overlay (unit-tested).
enum CoachingGeometry {
    /// The target key as a normalised rectangle in the camera picture, or nil when the keyboard isn't calibrated or the key is out of view.
    static func targetMarker(region: KeyboardRegion, note: Int) -> CGRect? {
        guard region.isCalibrated, abs(region.slope) > 1e-6 else { return nil }
        let centre = region.x(ofNote: note)
        guard centre > -0.05, centre < 1.05 else { return nil }
        let keyWidth = 1 / abs(region.slope) * (PianoKeys.isBlack(note) ? 0.6 : 0.95)
        let box = region.boundingBox
        return CGRect(x: centre - keyWidth / 2, y: box.minY, width: keyWidth, height: box.height)
    }

    /// Where the finger used and the finger wanted are in the picture. `from` is nil when the used finger isn't visible.
    static func correctionVector(frame: HandFrame, correction: FingerCorrection, lessonHand: HandSide) -> (from: CGPoint?, to: CGPoint)? {
        let hands = frame.hands.sorted { lhs, _ in lhs.side == lessonHand }
        for hand in hands {
            guard let target = hand.tip(of: correction.expected), target.confidence >= 0.3 else { continue }
            let from = correction.played.flatMap { hand.tip(of: $0) }.flatMap { $0.confidence >= 0.3 ? $0.point : nil }
            return (from, target.point)
        }
        return nil
    }
}

/// Draws the target-key marker and the finger correction over a camera picture.
struct CoachingOverlayView: View {
    let frame: HandFrame?
    let context: CoachingContext
    var fit = false
    var imageSize: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            Canvas { canvas, size in
                let pulse = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 6)
                drawMarker(&canvas, size: size, pulse: pulse)
                drawCorrection(&canvas, size: size, pulse: pulse)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func map(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        OverlayGeometry.viewPoint(point, imageSize: imageSize, viewSize: size, fit: fit)
    }

    private func drawMarker(_ canvas: inout GraphicsContext, size: CGSize, pulse: Double) {
        guard let target = context.target, let marker = CoachingGeometry.targetMarker(region: context.region, note: target.noteNumber) else { return }
        let topLeft = map(CGPoint(x: marker.minX, y: marker.minY), size)
        let bottomRight = map(CGPoint(x: marker.maxX, y: marker.maxY), size)
        let rect = CGRect(x: topLeft.x, y: topLeft.y, width: max(bottomRight.x - topLeft.x, 10), height: max(bottomRight.y - topLeft.y, 10))
        let color = target.finger.color
        let shape = Path(roundedRect: rect, cornerRadius: min(rect.width * 0.25, 12))
        canvas.fill(shape, with: .color(color.opacity(0.22 + 0.16 * pulse)))
        canvas.stroke(shape, with: .color(color), style: StrokeStyle(lineWidth: 3, dash: [8, 5]))

        // A badge above the key: "play here with this finger".
        let badge = CGRect(x: rect.midX - 22, y: rect.minY - 52 - 6 * pulse, width: 44, height: 44)
        canvas.fill(target.finger.glyph.path(in: badge), with: .color(color))
        canvas.draw(Text("\(target.finger.number)").font(.kid(22)).foregroundStyle(.white), at: CGPoint(x: badge.midX, y: badge.midY))
        var arrow = Path()
        arrow.move(to: CGPoint(x: rect.midX - 9, y: badge.maxY + 4))
        arrow.addLine(to: CGPoint(x: rect.midX + 9, y: badge.maxY + 4))
        arrow.addLine(to: CGPoint(x: rect.midX, y: badge.maxY + 16))
        arrow.closeSubpath()
        canvas.fill(arrow, with: .color(color))
    }

    private func drawCorrection(_ canvas: inout GraphicsContext, size: CGSize, pulse: Double) {
        guard let frame, HostClock.now - frame.timestamp < 0.6, let correction = context.correction,
              let vector = CoachingGeometry.correctionVector(frame: frame, correction: correction, lessonHand: context.lessonHand) else { return }
        let to = map(vector.to, size)
        // A pulsing ring on the finger to use.
        let ring = 30 + 10 * pulse
        let ringRect = CGRect(x: to.x - ring, y: to.y - ring, width: ring * 2, height: ring * 2)
        // White + amber: a friendly "look here", never the finger's own colour (the thumb's is red, which could read as an error).
        canvas.stroke(Path(ellipseIn: ringRect), with: .color(.white), lineWidth: 6)
        canvas.stroke(Path(ellipseIn: ringRect.insetBy(dx: 3, dy: 3)), with: .color(Palette.hint), lineWidth: 4)

        // A soft amber arrow from the finger that was used.
        if let from = vector.from.map({ map($0, size) }), hypot(to.x - from.x, to.y - from.y) > 24 {
            var line = Path()
            line.move(to: from)
            line.addLine(to: to)
            canvas.stroke(line, with: .color(Palette.hint), style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [2, 12]))
            let angle = atan2(to.y - from.y, to.x - from.x)
            let tip = CGPoint(x: to.x - cos(angle) * (ring + 4), y: to.y - sin(angle) * (ring + 4))
            var head = Path()
            head.move(to: tip)
            head.addLine(to: CGPoint(x: tip.x - cos(angle - 0.5) * 20, y: tip.y - sin(angle - 0.5) * 20))
            head.addLine(to: CGPoint(x: tip.x - cos(angle + 0.5) * 20, y: tip.y - sin(angle + 0.5) * 20))
            head.closeSubpath()
            canvas.fill(head, with: .color(Palette.hint))
        }
        canvas.draw(Text("This one!").font(.kid(20)).foregroundStyle(.white), at: CGPoint(x: to.x, y: to.y - ring - 18))
    }
}
