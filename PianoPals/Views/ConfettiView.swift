import SwiftUI

/// Fires celebratory particle bursts. Particle motion is a pure function of time, so drawing needs no per-frame state.
@MainActor
final class ConfettiModel: ObservableObject {
    enum Kind {
        /// Small, quick burst for a correct note.
        case burst
        /// Even smaller twinkle for a right key with a different finger.
        case sparkle
        /// Big shower when a song is finished.
        case finale
    }

    struct Particle {
        var angle: Double
        var speed: Double
        var spin: Double
        var size: Double
        var color: Color
        var shape: Int
        var delay: Double
    }

    struct Burst: Identifiable {
        let id = UUID()
        let start: Date
        let origin: CGPoint
        let lifetime: TimeInterval
        let gravity: Double
        let particles: [Particle]
    }

    @Published private(set) var bursts: [Burst] = []

    private static let palette: [Color] = [
        Finger.thumb.color, Finger.index.color, Finger.middle.color, Finger.ring.color, Finger.pinky.color, Palette.sunny, Palette.pink
    ]

    /// `origin` is in unit coordinates of the confetti layer.
    func fire(_ kind: Kind, at origin: CGPoint, accent: Color) {
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        var count: Int
        var speed: ClosedRange<Double>
        var lifetime: TimeInterval
        switch kind {
        case .burst: count = 26; speed = 260...620; lifetime = 1.5
        case .sparkle: count = 12; speed = 160...360; lifetime = 1.1
        case .finale: count = 110; speed = 300...900; lifetime = 3.2
        }
        if reduceMotion { count = max(6, count / 4) }
        var generator = SystemRandomNumberGenerator()
        let particles = (0..<count).map { index -> Particle in
            let spread = kind == .finale ? Double.pi * 2 : Double.pi * 1.1
            let centre = kind == .finale ? -Double.pi / 2 : -Double.pi / 2
            return Particle(
                angle: centre + Double.random(in: -spread / 2...spread / 2, using: &generator),
                speed: Double.random(in: speed, using: &generator),
                spin: Double.random(in: -8...8, using: &generator),
                size: Double.random(in: kind == .sparkle ? 10...18 : 12...26, using: &generator),
                color: index % 3 == 0 ? accent : ConfettiModel.palette.randomElement(using: &generator) ?? accent,
                shape: Int.random(in: 0...2, using: &generator),
                delay: kind == .finale ? Double.random(in: 0...0.5, using: &generator) : 0)
        }
        let now = Date()
        bursts.removeAll { now.timeIntervalSince($0.start) > $0.lifetime + 0.5 }
        bursts.append(Burst(start: now, origin: origin, lifetime: lifetime, gravity: kind == .finale ? 900 : 1100, particles: particles))
    }
}

struct ConfettiView: View {
    @ObservedObject var model: ConfettiModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: model.bursts.isEmpty)) { context in
            Canvas { canvas, size in
                for burst in model.bursts {
                    let elapsed = context.date.timeIntervalSince(burst.start)
                    guard elapsed < burst.lifetime + 0.5 else { continue }
                    for particle in burst.particles {
                        let t = elapsed - particle.delay
                        guard t > 0, t < burst.lifetime else { continue }
                        let x = burst.origin.x * size.width + cos(particle.angle) * particle.speed * t
                        let y = burst.origin.y * size.height + sin(particle.angle) * particle.speed * t + 0.5 * burst.gravity * t * t
                        let fade = min(1, max(0, (burst.lifetime - t) / (burst.lifetime * 0.35)))
                        var layer = canvas
                        layer.opacity = fade
                        layer.translateBy(x: x, y: y)
                        layer.rotate(by: .radians(particle.spin * t))
                        let rect = CGRect(x: -particle.size / 2, y: -particle.size / 2, width: particle.size, height: particle.size)
                        switch particle.shape {
                        case 0: layer.fill(FingerGlyph.star.path(in: rect), with: .color(particle.color))
                        case 1: layer.fill(Path(roundedRect: rect.insetBy(dx: 0, dy: particle.size * 0.2), cornerRadius: 2), with: .color(particle.color))
                        default: layer.fill(Path(ellipseIn: rect.insetBy(dx: particle.size * 0.1, dy: particle.size * 0.1)), with: .color(particle.color))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
