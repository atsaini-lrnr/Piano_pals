import Combine
import SwiftUI

/// Drives the cartoon friend's expression from lesson events and the child's own smile.
@MainActor
final class AvatarModel: ObservableObject {
    enum Mood: Equatable {
        case idle
        case listening
        case happy
        case cheering
        case encouraging
    }

    @Published private(set) var mood: Mood = .idle
    @Published private(set) var celebrationCount = 0
    /// 0…1 from the front camera (when available).
    @Published var childSmile: Double = 0
    /// -1 (look left) … 1 (look right): eyes follow the key we're hoping for.
    @Published var lookAt: Double = 0

    private var resetTask: Task<Void, Never>?

    func react(to event: SessionEvent) {
        switch event {
        case .started: set(.listening, for: nil)
        case .noteHit(_, _, let quality):
            switch quality {
            case .perfect, .fingerUnverified: celebrationCount += 1; set(.cheering, for: 1.1)
            case .fingerOff, .wrongHand: set(.happy, for: 1.1)
            }
        case .gentleMiss: set(.encouraging, for: 1.8)
        case .noteMissed: break
        case .finished: celebrationCount += 1; set(.cheering, for: 4.5)
        case .freePlay: set(.happy, for: 0.8)
        }
    }

    func set(_ mood: Mood, for duration: TimeInterval?) {
        resetTask?.cancel()
        self.mood = mood
        guard let duration else { return }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.mood = .listening
        }
    }

    func reset() {
        resetTask?.cancel()
        mood = .idle
    }
}

/// "Pip the Panda", drawn entirely with SwiftUI shapes so it scales crisply and animates smoothly.
struct AvatarView: View {
    let mood: AvatarModel.Mood
    var childSmile: Double = 0
    var lookAt: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var smile: Double {
        let base: Double
        switch mood {
        case .idle: base = 0.35
        case .listening: base = 0.3
        case .happy: base = 0.7
        case .cheering: base = 1.0
        case .encouraging: base = 0.55
        }
        return max(base, childSmile * 0.9)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let bounce = mood == .cheering ? abs(sin(t * 7)) * 14 : sin(t * 1.6) * 3
            let tilt: Double = mood == .encouraging ? 6 : (mood == .listening ? sin(t * 1.2) * 2 : 0)
            let blink = (Int(t * 2) % 7 == 0) && fmod(t * 2, 1) < 0.12
            Face(mood: mood, smile: smile, lookAt: lookAt, blink: blink, wave: sin(t * 9))
                .rotationEffect(.degrees(tilt))
                .offset(y: -bounce)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pip the panda, feeling \(moodDescription)")
    }

    private var moodDescription: String {
        switch mood {
        case .idle: return "calm"
        case .listening: return "ready"
        case .happy: return "happy"
        case .cheering: return "very excited"
        case .encouraging: return "encouraging"
        }
    }

    private struct Face: View {
        let mood: AvatarModel.Mood
        let smile: Double
        let lookAt: Double
        let blink: Bool
        let wave: Double

        var body: some View {
            GeometryReader { geo in
                let w = min(geo.size.width, geo.size.height * 0.95)
                let cx = geo.size.width / 2
                let headY = geo.size.height * 0.38
                let r = w * 0.34

                ZStack {
                    // Body & arms
                    Ellipse().fill(.white).overlay(Ellipse().stroke(Palette.ink, lineWidth: w * 0.012))
                        .frame(width: w * 0.56, height: w * 0.36).position(x: cx, y: geo.size.height * 0.79)
                    arm(side: -1, w: w).position(x: cx - w * 0.27, y: geo.size.height * 0.72)
                    arm(side: 1, w: w).position(x: cx + w * 0.27, y: geo.size.height * 0.72)

                    // Ears
                    Circle().fill(Palette.ink).frame(width: r * 0.55).position(x: cx - r * 0.78, y: headY - r * 0.78)
                    Circle().fill(Palette.ink).frame(width: r * 0.55).position(x: cx + r * 0.78, y: headY - r * 0.78)
                    Circle().fill(Palette.pink.opacity(0.8)).frame(width: r * 0.26).position(x: cx - r * 0.78, y: headY - r * 0.78)
                    Circle().fill(Palette.pink.opacity(0.8)).frame(width: r * 0.26).position(x: cx + r * 0.78, y: headY - r * 0.78)

                    // Head
                    Circle().fill(.white).overlay(Circle().stroke(Palette.ink, lineWidth: w * 0.012))
                        .frame(width: r * 2).position(x: cx, y: headY)

                    // Eye patches
                    Ellipse().fill(Palette.ink).frame(width: r * 0.50, height: r * 0.64)
                        .rotationEffect(.degrees(24)).position(x: cx - r * 0.42, y: headY - r * 0.05)
                    Ellipse().fill(Palette.ink).frame(width: r * 0.50, height: r * 0.64)
                        .rotationEffect(.degrees(-24)).position(x: cx + r * 0.42, y: headY - r * 0.05)

                    eye(x: cx - r * 0.42, y: headY - r * 0.07, r: r)
                    eye(x: cx + r * 0.42, y: headY - r * 0.07, r: r)

                    // Cheeks
                    Circle().fill(Palette.pink.opacity(0.25 + 0.45 * smile)).frame(width: r * 0.34)
                        .position(x: cx - r * 0.72, y: headY + r * 0.36)
                    Circle().fill(Palette.pink.opacity(0.25 + 0.45 * smile)).frame(width: r * 0.34)
                        .position(x: cx + r * 0.72, y: headY + r * 0.36)

                    // Nose
                    RoundedRectangle(cornerRadius: r * 0.1).fill(Palette.ink)
                        .frame(width: r * 0.26, height: r * 0.17).position(x: cx, y: headY + r * 0.24)

                    // Mouth
                    mouth(r: r).position(x: cx, y: headY + r * 0.52)
                }
            }
        }

        private func arm(side: CGFloat, w: CGFloat) -> some View {
            Capsule().fill(Palette.ink).frame(width: w * 0.13, height: w * 0.26)
                .rotationEffect(.degrees(Double(side) * (mood == .cheering ? 135 + wave * 20 : 18)), anchor: .top)
                .offset(y: mood == .cheering ? -w * 0.10 : 0)
        }

        private func eye(x: CGFloat, y: CGFloat, r: CGFloat) -> some View {
            ZStack {
                if mood == .cheering || blink {
                    // Happy closed eyes "^ ^" (or a blink).
                    Capsule().fill(.white).frame(width: r * 0.26, height: r * 0.06)
                        .offset(y: mood == .cheering ? -r * 0.02 : 0)
                } else {
                    Circle().fill(.white).frame(width: r * 0.26)
                    Circle().fill(Palette.ink).frame(width: r * 0.14).offset(x: CGFloat(lookAt) * r * 0.05, y: r * 0.01)
                    Circle().fill(.white).frame(width: r * 0.05).offset(x: CGFloat(lookAt) * r * 0.05 + r * 0.025, y: -r * 0.025)
                }
            }
            .position(x: x, y: y)
        }

        private func mouth(r: CGFloat) -> some View {
            let width = r * (0.34 + 0.22 * smile)
            let depth = r * (-0.02 + 0.22 * smile)
            let open = mood == .cheering || smile > 0.85
            return ZStack {
                if open {
                    MouthShape(depth: r * 0.34).fill(Color(red: 0.75, green: 0.15, blue: 0.25))
                        .overlay(MouthShape(depth: r * 0.34).stroke(Palette.ink, lineWidth: r * 0.04))
                        .frame(width: width * 1.5, height: r * 0.34)
                } else {
                    SmileCurve(depth: depth).stroke(Palette.ink, style: StrokeStyle(lineWidth: r * 0.055, lineCap: .round))
                        .frame(width: width, height: max(r * 0.1, abs(depth) + r * 0.05))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: smile)
        }
    }

    private struct SmileCurve: Shape {
        var depth: CGFloat
        var animatableData: CGFloat {
            get { depth }
            set { depth = newValue }
        }
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.minY + depth * 2))
            return path
        }
    }

    private struct MouthShape: Shape {
        var depth: CGFloat
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.minY + depth * 1.6))
            path.closeSubpath()
            return path
        }
    }
}
