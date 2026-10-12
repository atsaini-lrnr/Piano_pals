import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HomeContent(app: app, avatar: app.avatar, midi: app.midi, cameras: app.cameras)
    }
}

private struct HomeContent: View {
    let app: AppModel
    @ObservedObject var avatar: AvatarModel
    @ObservedObject var midi: MIDIManager
    @ObservedObject var cameras: CameraHub

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            HStack(spacing: 40) {
                VStack(spacing: 10) {
                    AvatarView(mood: avatar.mood, childSmile: avatar.childSmile)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("Piano Pals").font(.kid(84)).foregroundStyle(Palette.ink)
                    Text("Let's make music!").font(.kid(34, weight: .bold)).foregroundStyle(Palette.ink.opacity(0.7))
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 26) {
                    Spacer()
                    BigButton(title: "Play!", systemImage: "play.fill", color: Palette.play, height: 150, fontSize: 56) {
                        app.screen = .songs
                        app.narrator.say("Pick a song!")
                    }
                    BigButton(title: "My Hands", systemImage: "hand.raised.fill", color: Palette.blueButton, height: 130, fontSize: 46) {
                        app.screen = .calibration
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        StatusChip(systemImage: "pianokeys", text: midi.isKeyboardConnected ? "Piano" : "No piano yet", isGood: midi.isKeyboardConnected)
                        StatusChip(systemImage: "camera.fill", text: "Camera",
                                   isGood: cameras.primary.state == .running || cameras.overhead.state == .running)
                    }
                    HoldToOpenButton(title: "Grown-ups: hold", systemImage: "lock.fill") { app.showGrownUps = true }
                }
                .frame(maxWidth: 520)
            }
            .padding(48)
        }
        .onAppear { avatar.set(.listening, for: nil) }
    }
}

struct SongPickerView: View {
    @EnvironmentObject private var app: AppModel

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 24)]

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    BigIconButton(systemImage: "house.fill", label: "Home", color: Palette.pink) { app.screen = .home }
                    Text("Pick a song!").font(.kid(60)).foregroundStyle(Palette.ink)
                    Spacer()
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(app.songs) { song in
                            Button { app.open(song) } label: { SongCard(lesson: song) }
                                .buttonStyle(BouncyButtonStyle())
                        }
                    }
                    .padding(8)
                }
            }
            .padding(36)
        }
    }
}

private struct SongCard: View {
    let lesson: Lesson

    var body: some View {
        VStack(spacing: 10) {
            Text(lesson.emoji).font(.system(size: 92))
            Text(lesson.title).font(.kid(30)).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
            HStack(spacing: -4) {
                ForEach(Array(Set(lesson.notes.map(\.assignedFinger))).sorted(), id: \.self) { number in
                    if let finger = Finger(rawValue: number) { FingerBadge(finger: finger, size: 34, showsNumber: false) }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 36, style: .continuous).fill(.white).shadow(color: .black.opacity(0.12), radius: 0, y: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lesson.title)
    }
}
