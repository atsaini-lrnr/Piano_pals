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

    /// The keys on screen: a 15-key window that follows the music by whole octaves when the lesson is wider than the window,
    /// and never shows keys the real keyboard doesn't have. Lane, keyboard and camera strip all use this same span.
    private var span: KeyboardSpan { model.visibleSpan }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Palette.background.ignoresSafeArea()
                VStack(spacing: 10) {
                    header
                    cameraSection(height: max(geo.size.height * 0.34, 200))
                    gameColumn
                }
                .padding(.horizontal, 22).padding(.vertical, 12)

                ConfettiView(model: confetti).ignoresSafeArea()

                if session.phase == .finished { finishedCard }
                if model.routine?.isFinished == true { practiceDoneCard }
            }
        }
        .onChange(of: session.targets) { _, targets in
            if let note = targets.first?.note.noteNumber { avatar.lookAt = span.fraction(of: note) * 2 - 1 }
        }
    }

    // MARK: Camera section (top)

    private func cameraSection(height: CGFloat) -> some View {
        GeometryReader { geo in
            let channelID = cameras.trackingChannel
            let channel = cameras.channel(channelID)
            let region = app.region(for: channelID)
            let pictureSize = channel.latestFrame?.imageSize ?? channel.videoSize
            let live = channel.state == .running || (settings.demoHands && channelID == .primary)
            let crop = settings.alignedCamera && live
                ? CameraAlignment.crop(region: region, span: span, imageSize: pictureSize, stripAspect: geo.size.width / height) : nil
            ZStack(alignment: .top) {
                if let crop {
                    alignedStrip(channel: channel, crop: crop, region: region, channelID: channelID)
                } else {
                    unalignedBand(size: CGSize(width: geo.size.width, height: height), showHint: settings.alignedCamera && live && !region.isCalibrated)
                }
            }
            .frame(width: geo.size.width, height: height)
        }
        .frame(height: height)
    }

    /// Overhead camera lined up with the keyboard below, with the panda tucked in the corner.
    private func alignedStrip(channel: CameraChannel, crop: AlignedCrop, region: KeyboardRegion, channelID: CameraChannelID) -> some View {
        ZStack(alignment: .topLeading) {
            AlignedCameraStrip(channel: channel, crop: crop, span: span, region: region, showFootage: settings.showFootage,
                               highlight: session.targets.first?.note.finger, coaching: model.coachingContext(for: channelID))
            HStack(alignment: .top, spacing: 8) {
                AvatarView(mood: avatar.mood, childSmile: avatar.childSmile, lookAt: avatar.lookAt).frame(width: 120, height: 130)
                coachBubble
            }
            .padding(10)
            if settings.showSideView, channelID != .primary, cameras.primary.state == .running {
                HStack {
                    Spacer()
                    CameraTile(channel: cameras.primary, title: "Side view", highlight: nil, isTracking: false)
                        .frame(width: 210)
                }
                .padding(10)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.coachMessage)
    }

    private var coachBubble: some View {
        Group {
            if let message = model.coachMessage {
                Text(message)
                    .font(.kid(20, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 3)
                    .frame(maxWidth: 260, alignment: .leading)
                    .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
                    .accessibilityLabel(message)
            }
        }
    }

    /// The camera picture fills the full width, edge to edge, iPhone first. If the picture is taller than the band it is cropped, keeping
    /// the lower part where the keys and hands are. Used until the keyboard is calibrated, or with no overhead view.
    private func unalignedBand(size: CGSize, showHint: Bool) -> some View {
        let id = cameras.trackingChannel
        let channel = cameras.channel(id)
        let tileHeight = size.width / CameraTile.aspect(of: channel)
        let overflow = max(0, tileHeight - size.height)
        let lift = min(max((0.5 - 0.65) * tileHeight, -overflow / 2), overflow / 2)   // open on the lower 65 % of the picture
        return ZStack(alignment: .top) {
            CameraTile(channel: channel, title: id == .primary ? "Side view" : "Top view", highlight: session.targets.first?.note.finger,
                       isTracking: true, demoBackdrop: settings.demoHands && id == .primary && channel.state != .running,
                       coaching: model.coachingContext(for: id),
                       placeholderButton: id == .overhead && channel.state != .running && cameras.authorization == .authorized
                           ? ("Use my iPhone", { app.showCameraPicker = true }) : nil)
                .frame(width: size.width, height: tileHeight)
                .offset(y: lift)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            HStack(alignment: .top, spacing: 8) {
                AvatarView(mood: avatar.mood, childSmile: avatar.childSmile, lookAt: avatar.lookAt).frame(width: 120, height: 130)
                coachBubble
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.coachMessage)
            if showHint {
                Button {
                    app.leaveLesson()
                    app.screen = .calibration
                } label: {
                    Label("Line up the camera with the keys: tap My Hands", systemImage: "hand.raised.fill")
                        .font(.kid(20)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(Palette.blueButton))
                }
                .buttonStyle(BouncyButtonStyle())
                .padding(.top, 8)
            }
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
                        ForEach(session.targets.prefix(3)) { target in
                            VStack(spacing: 0) {
                                FingerBadge(finger: target.note.finger, size: 60)
                                if session.lesson?.isBothHands == true, let hand = target.note.hand { HandBadge(hand: hand, size: 24) }
                            }
                        }
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
                        Text("or press any key on the piano").font(.kid(22, weight: .bold)).foregroundStyle(.white.opacity(0.9))
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
            .frame(height: 210)
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
                FinishPromptLine(prompt: model.finishPrompt)
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 48, style: .continuous).fill(.white))
            .shadow(radius: 20)
        }
        .transition(.scale.combined(with: .opacity))
    }
}

/// The question the panda is asking out loud on the "You did it" card, in words, for a child who does not speak yet.
private struct FinishPromptLine: View {
    @ObservedObject var prompt: FinishPrompt

    var body: some View {
        if let text = prompt.text {
            VStack(spacing: 6) {
                Text(text).font(.kid(26, weight: .bold)).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                if case .listening = prompt.phase { Label("Listening…", systemImage: "waveform").font(.kid(20)).foregroundStyle(Palette.blueButton) }
            }
            .frame(maxWidth: 720)
            .accessibilityIdentifier("finishPromptLine")
        }
    }
}
