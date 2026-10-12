import SwiftUI

/// Springy press feedback for every button.
struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// A preschool-sized button: at least 96 pt tall, big icon, big label.
struct BigButton: View {
    let title: String
    let systemImage: String
    var color: Color = Palette.blueButton
    var height: CGFloat = 112
    var fontSize: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: systemImage).font(.system(size: fontSize * 1.15, weight: .black))
                Text(title).font(.kid(fontSize))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: max(height, 96))
            .padding(.horizontal, 24)
            .background(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(color)
                    .shadow(color: color.opacity(0.55), radius: 0, y: 8)
            )
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel(title)
    }
}

/// A round icon-only button (≥ 96 pt).
struct BigIconButton: View {
    let systemImage: String
    let label: String
    var color: Color = Palette.blueButton
    var size: CGFloat = 96
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .black))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(color).shadow(color: color.opacity(0.55), radius: 0, y: 6))
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Requires a deliberate press-and-hold, so a small child doesn't wander into the grown-ups' settings.
struct HoldToOpenButton: View {
    let title: String
    let systemImage: String
    var holdDuration: TimeInterval = 1.2
    let action: () -> Void

    @State private var progress: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.35), lineWidth: 6)
                Circle().trim(from: 0, to: progress).stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: systemImage).font(.system(size: 22, weight: .bold))
            }
            .frame(width: 48, height: 48)
            Text(title).font(.kid(24, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .frame(minHeight: 96)
        .background(Capsule().fill(Color.gray.opacity(0.85)))
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: holdDuration, maximumDistance: 40) {
            progress = 0
            action()
        } onPressingChanged: { pressing in
            withAnimation(.linear(duration: pressing ? holdDuration : 0.2)) { progress = pressing ? 1 : 0 }
        }
        .accessibilityLabel(title)
        .accessibilityHint("Press and hold to open")
        .accessibilityAddTraits(.isButton)
    }
}

struct StarRow: View {
    let filled: Int
    var total = 3
    var size: CGFloat = 44

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(0..<total, id: \.self) { index in
                FingerGlyphShape(glyph: .star)
                    .fill(index < filled ? Palette.sunny : Color.white.opacity(0.45))
                    .overlay(FingerGlyphShape(glyph: .star).stroke(index < filled ? Color.orange : Color.white.opacity(0.8), lineWidth: 3))
                    .frame(width: size, height: size)
                    .scaleEffect(index < filled ? 1 : 0.85)
                    .animation(.spring(response: 0.4, dampingFraction: 0.5).delay(Double(index) * 0.12), value: filled)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(filled) of \(total) stars")
    }
}

struct StatusChip: View {
    let systemImage: String
    let text: String
    let isGood: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
            Image(systemName: isGood ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isGood ? Palette.success : Palette.ink.opacity(0.5))
        }
        .font(.kid(20, weight: .bold))
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Capsule().fill(.white.opacity(0.85)))
        .accessibilityElement(children: .combine)
    }
}
