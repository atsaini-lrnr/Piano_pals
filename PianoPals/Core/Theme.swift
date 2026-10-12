import SwiftUI

/// Bright, high-contrast colours. Meaning is never carried by colour alone: every finger also has a shape and a number.
enum Palette {
    static let skyTop = Color(red: 0.55, green: 0.80, blue: 1.00)
    static let skyBottom = Color(red: 0.86, green: 0.78, blue: 1.00)
    static let ink = Color(red: 0.13, green: 0.12, blue: 0.30)
    static let card = Color.white
    static let success = Color(red: 0.18, green: 0.80, blue: 0.44)
    static let gentle = Color(red: 0.72, green: 0.61, blue: 1.00)
    static let hint = Color(red: 1.00, green: 0.85, blue: 0.24)
    static let play = Color(red: 0.13, green: 0.70, blue: 0.40)
    static let blueButton = Color(red: 0.20, green: 0.48, blue: 0.98)
    static let sunny = Color(red: 1.00, green: 0.78, blue: 0.16)
    static let pink = Color(red: 1.00, green: 0.45, blue: 0.62)

    static var background: LinearGradient {
        LinearGradient(colors: [skyTop, skyBottom], startPoint: .top, endPoint: .bottom)
    }
}

extension Finger {
    var color: Color {
        switch self {
        case .thumb: return Color(red: 1.00, green: 0.23, blue: 0.30)
        case .index: return Color(red: 0.18, green: 0.48, blue: 1.00)
        case .middle: return Color(red: 0.10, green: 0.70, blue: 0.35)
        case .ring: return Color(red: 1.00, green: 0.62, blue: 0.10)
        case .pinky: return Color(red: 0.62, green: 0.30, blue: 1.00)
        }
    }

    var glyph: FingerGlyph {
        switch self {
        case .thumb: return .star
        case .index: return .circle
        case .middle: return .triangle
        case .ring: return .diamond
        case .pinky: return .heart
        }
    }
}

enum FingerGlyph: Sendable {
    case star, circle, triangle, diamond, heart

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        switch self {
        case .circle:
            return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        case .star:
            var path = Path()
            for i in 0..<10 {
                let radius = i.isMultiple(of: 2) ? r : r * 0.46
                let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
                let p = CGPoint(x: c.x + CGFloat(cos(angle)) * radius, y: c.y + CGFloat(sin(angle)) * radius)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path.strokedPath(StrokeStyle(lineWidth: r * 0.16, lineJoin: .round)).union(path)
        case .triangle:
            var path = Path()
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.addLine(to: CGPoint(x: c.x + r * 0.95, y: c.y + r * 0.78))
            path.addLine(to: CGPoint(x: c.x - r * 0.95, y: c.y + r * 0.78))
            path.closeSubpath()
            return path.strokedPath(StrokeStyle(lineWidth: r * 0.2, lineJoin: .round)).union(path)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.addLine(to: CGPoint(x: c.x + r * 0.85, y: c.y))
            path.addLine(to: CGPoint(x: c.x, y: c.y + r))
            path.addLine(to: CGPoint(x: c.x - r * 0.85, y: c.y))
            path.closeSubpath()
            return path.strokedPath(StrokeStyle(lineWidth: r * 0.2, lineJoin: .round)).union(path)
        case .heart:
            var path = Path()
            let w = r * 2, h = r * 2
            let x = c.x - r, y = c.y - r
            path.move(to: CGPoint(x: x + w * 0.5, y: y + h * 0.92))
            path.addCurve(to: CGPoint(x: x + w * 0.02, y: y + h * 0.34),
                          control1: CGPoint(x: x + w * 0.28, y: y + h * 0.78), control2: CGPoint(x: x + w * 0.02, y: y + h * 0.62))
            path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.22),
                          control1: CGPoint(x: x + w * 0.02, y: y + h * 0.08), control2: CGPoint(x: x + w * 0.4, y: y + h * 0.04))
            path.addCurve(to: CGPoint(x: x + w * 0.98, y: y + h * 0.34),
                          control1: CGPoint(x: x + w * 0.6, y: y + h * 0.04), control2: CGPoint(x: x + w * 0.98, y: y + h * 0.08))
            path.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h * 0.92),
                          control1: CGPoint(x: x + w * 0.98, y: y + h * 0.62), control2: CGPoint(x: x + w * 0.72, y: y + h * 0.78))
            path.closeSubpath()
            return path
        }
    }
}

struct FingerGlyphShape: Shape {
    let glyph: FingerGlyph
    func path(in rect: CGRect) -> Path { glyph.path(in: rect) }
}

/// A finger's colour + shape + number, e.g. a red star with a "1".
struct FingerBadge: View {
    let finger: Finger
    var size: CGFloat = 56
    var showsNumber = true

    var body: some View {
        ZStack {
            FingerGlyphShape(glyph: finger.glyph)
                .fill(finger.color)
                .overlay(FingerGlyphShape(glyph: finger.glyph).stroke(.white, lineWidth: max(2, size * 0.06)))
                .shadow(color: .black.opacity(0.25), radius: size * 0.05, y: size * 0.03)
            if showsNumber {
                Text("\(finger.number)")
                    .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    .offset(y: finger.glyph == .triangle ? size * 0.08 : 0)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Finger \(finger.number), \(finger.displayName), \(finger.kidName)")
    }
}

extension Font {
    static func kid(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font { .system(size: size, weight: weight, design: .rounded) }
}
