import SwiftUI

/// The on-screen keyboard: also the "highlighted key grid". Keys that should be played glow in their finger's colour and
/// carry that finger's badge; correct keys pulse green, other keys pulse a soft lavender (never red).
struct KeyboardView: View {
    let span: KeyboardSpan
    let targets: [LessonTarget]
    let feedback: [Int: KeyFeedback]
    let pressed: Set<UInt8>
    let onKey: (Int, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let whiteWidth = geo.size.width / CGFloat(max(span.whiteKeyCount, 1))
            let blackWidth = whiteWidth * 0.58
            let whites = span.notes.filter { !PianoKeys.isBlack($0) }
            let blacks = span.notes.filter { PianoKeys.isBlack($0) }

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(whites, id: \.self) { note in
                        KeyView(note: note, isBlack: false, target: target(for: note), feedback: feedback[note],
                                isPressed: pressed.contains(UInt8(clamping: note)), onKey: onKey)
                            .frame(width: whiteWidth)
                    }
                }
                ForEach(blacks, id: \.self) { note in
                    KeyView(note: note, isBlack: true, target: target(for: note), feedback: feedback[note],
                            isPressed: pressed.contains(UInt8(clamping: note)), onKey: onKey)
                        .frame(width: blackWidth, height: geo.size.height * 0.62)
                        .offset(x: CGFloat(PianoKeys.center(of: note) - Double(span.firstWhiteIndex)) * whiteWidth - blackWidth / 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Piano keys")
    }

    private func target(for note: Int) -> LessonTarget? { targets.first { $0.note.noteNumber == note } }
}

private struct KeyView: View {
    let note: Int
    let isBlack: Bool
    let target: LessonTarget?
    let feedback: KeyFeedback?
    let isPressed: Bool
    let onKey: (Int, Bool) -> Void

    @State private var touching = false
    @State private var pulse: Double = 0
    @State private var pulseKind: KeyFeedbackKind = .success

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(baseColor)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.ink.opacity(isBlack ? 0 : 0.35), lineWidth: 2))
                    .shadow(color: .black.opacity(isBlack ? 0.35 : 0.12), radius: 3, y: isActive ? 1 : 4)

                if !isBlack, note % 12 == 0, target == nil {
                    VStack(spacing: 2) {
                        if note == 60 { Image(systemName: "star.fill").font(.system(size: min(geo.size.width * 0.3, 22))).foregroundStyle(Palette.sunny) }
                        Text(note == 60 ? "Middle C" : PianoKeys.name(note))
                            .font(.kid(min(geo.size.width * 0.26, 16), weight: .bold)).foregroundStyle(Palette.ink.opacity(0.55))
                            .lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
                }

                if let target {
                    TargetGlow(color: target.note.finger.color)
                        .padding(isBlack ? 2 : 3)
                    FingerBadge(finger: target.note.finger, size: min(geo.size.width * 0.8, 78))
                        .padding(.bottom, isBlack ? geo.size.height * 0.18 : geo.size.height * 0.10)
                        .transition(.scale)
                }

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(pulseColor)
                    .opacity(pulse)
                    .allowsHitTesting(false)
            }
            .offset(y: isActive ? 3 : 0)
            .animation(.easeOut(duration: 0.06), value: isActive)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !touching else { return }
                        touching = true
                        onKey(note, true)
                    }
                    .onEnded { _ in
                        touching = false
                        onKey(note, false)
                    }
            )
        }
        .padding(.horizontal, isBlack ? 0 : 1.5)
        .onChange(of: feedback?.id) { _, _ in
            guard let feedback else { return }
            pulseKind = feedback.kind
            pulse = feedback.kind == .hint ? 0.85 : 0.95
            withAnimation(.easeOut(duration: feedback.kind == .hint ? 1.8 : 0.75)) { pulse = 0 }
        }
        .accessibilityLabel(PianoKeys.name(note))
        .accessibilityAddTraits(.isButton)
    }

    private var isActive: Bool { touching || isPressed }

    private var baseColor: Color {
        if isBlack { return isActive ? Color(white: 0.35) : Palette.ink }
        return isActive ? Color(white: 0.84) : .white
    }

    private var pulseColor: Color {
        switch pulseKind {
        case .success: return Palette.success
        case .gentle: return Palette.gentle
        case .hint: return Palette.hint
        }
    }
}

/// A softly breathing outline in the finger's colour on the key to play.
private struct TargetGlow: View {
    let color: Color
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color.opacity(bright ? 0.30 : 0.14))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(color, lineWidth: bright ? 6 : 3))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}
