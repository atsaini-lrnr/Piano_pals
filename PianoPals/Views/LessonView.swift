import SwiftUI

struct LessonView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        LessonContent(app: app, model: app, session: app.session, cameras: app.cameras, avatar: app.avatar,
                      midi: app.midi, settings: app.settings, confetti: app.confetti)
    }
}

private struct LessonContent: View {
    let app: AppModel
    @ObservedObject var model: AppModel
    @ObservedObject var session: LessonSession
    @ObservedObject var cameras: CameraHub
    @ObservedObject var avatar: AvatarModel
    @ObservedObject var midi: MIDIManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var confetti: ConfettiModel

    private var span: KeyboardSpan {
        let low = session.lesson?.lowestNote ?? 60
        let high = session.lesson?.highestNote ?? 67
        // As many keys as fit across the screen (at least two octaves), but never keys the real keyboard doesn't have.
        return .fitting(low: low, high: high, minimumWhiteKeys: 15, limit: app.keyboardRange)
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
                if model.routine?.isFinished == true { practiceDoneCard }
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
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.lesson?.title ?? "").font(.kid(34)).foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.6)
                    if let routine = model.routine {
                        Text("Practice step \(routine.index + 1) of \(routine.plan.steps.count)").font(.kid(18, weight: .bold)).foregroundStyle(Palette.ink.opacity(0.7))
                    }
                }
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

                if let finger = model.fingerCue {
                    VStack {
                        HStack(spacing: 12) {
                            Text("Try").font(.kid(30)).foregroundStyle(.white)
                            FingerBadge(finger: finger, size: 84)
                            Text("finger").font(.kid(30)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        Spacer()
                    }
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
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
            .animation(.easeOut(duration: 0.25), value: model.fingerCue)

            KeyboardView(span: span, targets: session.targets, feedback: session.keyFeedback, pressed: midi.pressedNotes) { note, down in
                app.virtualKey(note, isDown: down)
            }
            .frame(height: 230)
        }
    }

    // MARK: Side column

    private var sideColumn: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                AvatarView(mood: avatar.mood, childSmile: avatar.childSmile, lookAt: avatar.lookAt)
                    .frame(height: 210)
                if let message = model.coachMessage {
                    Text(message)
                        .font(.kid(22, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 3)
                        .frame(maxWidth: 300, alignment: .leading)
                        .transition(.scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
                        .accessibilityLabel(message)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.coachMessage)
            CameraPanel(hub: cameras, highlight: session.targets.first?.note.finger, demoHands: settings.demoHands) {
                app.showCameraPicker = true
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Finish

    private var practiceDoneCard: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 22) {
                Text("Practice done!").font(.kid(72)).foregroundStyle(Palette.ink)
                let earned = model.routine?.stars.reduce(0, +) ?? 0
                let possible = (model.routine?.stars.count ?? 1) * 3
                StarRow(filled: min(3, Int((Double(earned) / Double(max(possible, 1)) * 3).rounded())), size: 110)
                Text("\(model.routine?.stars.count ?? 0) exercises finished").font(.kid(28, weight: .bold)).foregroundStyle(Palette.ink.opacity(0.7))
                BigButton(title: "Great!", systemImage: "hand.thumbsup.fill", color: Palette.play) { app.endRoutine() }.frame(width: 420)
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 48, style: .continuous).fill(.white))
            .shadow(radius: 20)
        }
        .transition(.scale.combined(with: .opacity))
    }

    private var finishedCard: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 22) {
                Text("You did it!").font(.kid(72)).foregroundStyle(Palette.ink)
                StarRow(filled: session.stars, size: 110)
                HStack(spacing: 20) {
                    BigButton(title: "Again", systemImage: "arrow.counterclockwise", color: Palette.blueButton) { app.startLesson() }
                    if let routine = model.routine {
                        BigButton(title: routine.hasNext ? "Next" : "Finish", systemImage: routine.hasNext ? "forward.fill" : "flag.checkered", color: Palette.play) {
                            app.advanceRoutine()
                        }
                    } else {
                        BigButton(title: "More songs", systemImage: "music.note.list", color: Palette.play) { app.leaveLesson() }
                    }
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
