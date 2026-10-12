import SwiftUI

/// Notes slide down towards the keys. Each is a bar in its finger's colour carrying that finger's shape and number.
struct FallingNotesView: View {
    @ObservedObject var session: LessonSession
    let span: KeyboardSpan

    /// How many seconds of music fit in the lane.
    private let visibleSeconds: Double = 3.4

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                draw(into: &canvas, size: size, date: context.date)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(into canvas: inout GraphicsContext, size: CGSize, date: Date) {
        let whiteWidth = size.width / CGFloat(max(span.whiteKeyCount, 1))
        let pointsPerSecond = size.height / visibleSeconds
        let time = session.songTime(at: date)
        let pulse = 1 + 0.05 * sin(date.timeIntervalSinceReferenceDate * 6)

        // Lane stripes: one per white key, alternating, so notes line up visually with the keys below.
        for index in 0..<span.whiteKeyCount where index.isMultiple(of: 2) {
            let rect = CGRect(x: CGFloat(index) * whiteWidth, y: 0, width: whiteWidth, height: size.height)
            canvas.fill(Path(rect), with: .color(.white.opacity(0.18)))
        }
        // Landing line.
        let line = CGRect(x: 0, y: size.height - 6, width: size.width, height: 6)
        canvas.fill(Path(line), with: .color(.white.opacity(0.9)))

        guard let lesson = session.lesson else { return }
        let targetIndexes = Set(session.targets.map(\.index))

        for (index, note) in lesson.notes.enumerated() {
            let progress = index < session.noteProgress.count ? session.noteProgress[index] : .pending
            let bottom = size.height - CGFloat(note.timestamp - time) * pointsPerSecond
            let isBlack = PianoKeys.isBlack(note.noteNumber)
            let width = whiteWidth * (isBlack ? 0.5 : 0.82)
            let height = min(max(CGFloat(note.duration) * pointsPerSecond * 0.8, width * 1.15), size.height * 0.5)
            let top = bottom - height
            guard top < size.height, bottom > -20 else { continue }

            var opacity = 1.0
            switch progress {
            case .pending: break
            case .hit: opacity = max(0, 0.55 - (time - note.timestamp) * 1.2)
            case .missed: opacity = 0.22
            }
            guard opacity > 0.01 else { continue }

            let centreX = CGFloat(span.fraction(of: note.noteNumber)) * size.width
            let isTarget = targetIndexes.contains(index)
            let scale = isTarget ? pulse : 1
            let rect = CGRect(x: centreX - width * scale / 2, y: bottom - height * scale, width: width * scale, height: height * scale)

            let color = progress == .missed ? Color.gray : note.finger.color
            var layer = canvas
            layer.opacity = opacity
            let bar = Path(roundedRect: rect, cornerRadius: min(width * 0.3, 26))
            layer.fill(bar, with: .color(color))
            layer.stroke(bar, with: .color(.white), lineWidth: isTarget ? 6 : 3)

            // Finger shape + number near the bottom of the bar.
            let glyphSize = min(width * 0.78, 64)
            let glyphRect = CGRect(x: rect.midX - glyphSize / 2, y: rect.maxY - glyphSize - 6, width: glyphSize, height: glyphSize)
            layer.fill(note.finger.glyph.path(in: glyphRect), with: .color(.white))
            layer.draw(Text("\(note.assignedFinger)").font(.kid(glyphSize * 0.5)).foregroundStyle(color),
                       at: CGPoint(x: glyphRect.midX, y: glyphRect.midY + (note.finger.glyph == .triangle ? glyphSize * 0.08 : 0)))
        }
    }
}
