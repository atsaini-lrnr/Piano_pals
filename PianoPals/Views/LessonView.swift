import SwiftUI

struct LessonView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        LessonContent(app: app, session: app.session, cameras: app.cameras, avatar: app.avatar,
                      midi: app.midi, settings: app.settings, confetti: app.confetti)
    }
}

private struct LessonContent: View {
    let app: AppModel
    @ObservedObject var session: LessonSession
    @ObservedObject var cameras: CameraHub
    @ObservedObject var avatar: AvatarModel
    @ObservedObject var midi: MIDIManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var confetti: ConfettiModel

    private var span: KeyboardSpan {
        let low = session.lesson?.lowestNote ?? 60
        let high = session.lesson?.highestNote ?? 67
        return .fitting(low: low, high: high)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.background.ignoresSafeArea()
                VStack(spacing: 14) {
                    header
                    HStack(alignment: .top, spacing: 18) {
                        gameColumn
                        sideColumn.frame(width: geo.size.width * 0.34)
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)

                ConfettiView(model: confetti).ignoresSafeArea()

                if session.phase == .finished { finishedCard }
            }
        }
        .onChange(of: session.targets) { _, targets in
            if let note = targets.first?.note.noteNumber { avatar.lookAt = span.fraction(of: note) * 2 - 1 }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 18) {
            BigIconButton(systemImage: "house.fill", label: "Home", color: Palette.pink) { app.leaveLesson() }

            HStack(spacing: 12) {
                Text(session.lesson?.emoji ?? "🎵").font(.system(size: 52))
                Text(session.lesson?.title ?? "").font(.kid(34)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.6)
            }

            Spacer(minLength: 8)

            if let target = session.targets.first {
                VStack(spacing: 2) {
                    Text("Use").font(.kid(18, weight: .bold)).foregroundStyle(Palette.ink)
                    HStack(spacing: -6) {
                        ForEach(session.targets.prefix(3)) { FingerBadge(finger: $0.note.finger, size: 60) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.85)))
                .accessibilityLabel("Use finger \(target.note.assignedFinger)")
            }

            StarRow(filled: Int((session.progressFraction * 3).rounded(.down)), size: 40)

            switch session.phase {
            case .playing:
                BigIconButton(systemImage: "pause.fill", label: "Pause", color: Palette.sunny) { session.pause() }
            case .paused:
                BigIconButton(systemImage: "play.fill", label: "Resume", color: Palette.play) { session.resume() }
            default:
                EmptyView()
            }
            if session.phase != .ready {
                BigIconButton(systemImage: "arrow.counterclockwise", label: "Start over", color: Palette.blueButton) { app.startLesson() }
            }
            Button {
                settings.tempoScale = settings.tempoScale <= 0.7 ? 1.0 : 0.6
            } label: {
                Text(settings.tempoScale <= 0.7 ? "🐢" : "🐇").font(.system(size: 52))
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(.white.opacity(0.85)))
            }
            .buttonStyle(BouncyButtonStyle())
            .accessibilityLabel(settings.tempoScale <= 0.7 ? "Slow speed. Tap for normal speed" : "Normal speed. Tap for slow speed")
        }
    }

    // MARK: Game

    private var gameColumn: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(red: 0.16, green: 0.15, blue: 0.36).opacity(0.92))
                FallingNotesView(session: session, span: span)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                if session.phase == .ready {
                    VStack(spacing: 20) {
                        Text("Ready?").font(.kid(46)).foregroundStyle(.white)
                        BigButton(title: "Play!", systemImage: "play.fill", color: Palette.play, height: 128, fontSize: 52) { app.startLesson() }
                            .frame(width: 340)
                    }
                } else if session.phase == .paused {
                    Text("Resting…").font(.kid(46)).foregroundStyle(.white)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white, lineWidth: 4))

            KeyboardView(span: span, targets: session.targets, feedback: session.keyFeedback, pressed: midi.pressedNotes) { note, down in
                app.virtualKey(note, isDown: down)
            }
            .frame(height: 230)
        }
    }

    // MARK: Side column

    private var sideColumn: some View {
        VStack(spacing: 14) {
            AvatarView(mood: avatar.mood, childSmile: avatar.childSmile, lookAt: avatar.lookAt)
                .frame(height: 210)
            CameraPanel(hub: cameras, highlight: session.targets.first?.note.finger, demoHands: settings.demoHands) {
                app.showCameraPicker = true
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Finish

    private var finishedCard: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 22) {
                Text("You did it!").font(.kid(72)).foregroundStyle(Palette.ink)
                StarRow(filled: session.stars, size: 110)
                HStack(spacing: 20) {
                    BigButton(title: "Again", systemImage: "arrow.counterclockwise", color: Palette.blueButton) { app.startLesson() }
                    BigButton(title: "More songs", systemImage: "music.note.list", color: Palette.play) { app.leaveLesson() }
                }
                .frame(width: 720)
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 48, style: .continuous).fill(.white))
            .shadow(radius: 20)
        }
        .transition(.scale.combined(with: .opacity))
    }
}
