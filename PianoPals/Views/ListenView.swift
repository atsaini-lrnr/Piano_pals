import SwiftUI

/// Grown-up tool: play or hum a tune near the iPad and turn it into a lesson. Sound is analysed live and not recorded.
struct ListenView: View {
    let app: AppModel
    @StateObject private var recorder = ListenRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var addedLesson: Lesson?
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text("Play or hum the song slowly, one note at a time, close to the iPad.")
                    .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .padding(.horizontal)

                ZStack {
                    Circle().fill(recorder.state == .listening ? Palette.success.opacity(0.18 + 0.4 * recorder.level) : Color.gray.opacity(0.15))
                        .frame(width: 220, height: 220)
                        .animation(.easeOut(duration: 0.1), value: recorder.level)
                    VStack(spacing: 4) {
                        Text(recorder.liveNote.map(PianoKeys.name) ?? (recorder.state == .listening ? "…" : "🎤"))
                            .font(.system(size: 64, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                        if recorder.state == .listening { Text("listening").font(.callout).foregroundStyle(.secondary) }
                    }
                }

                switch recorder.state {
                case .idle:
                    Button { Task { await recorder.start() } } label: {
                        Label("Start listening", systemImage: "mic.fill").font(.title2.weight(.semibold)).padding(.horizontal, 24).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).disabled(working)
                case .listening:
                    Button { finish() } label: {
                        Label("Stop and make a lesson", systemImage: "stop.fill").font(.title2.weight(.semibold)).padding(.horizontal, 24).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(.red)
                case .denied:
                    VStack(spacing: 8) {
                        Label("Microphone access is off.", systemImage: "mic.slash.fill").foregroundStyle(.orange)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.bordered)
                    }
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }

                if working { ProgressView("Making your lesson…") }
                if let message { Label(message, systemImage: "info.circle").foregroundStyle(.orange).multilineTextAlignment(.center) }
                if let addedLesson {
                    VStack(spacing: 10) {
                        Label("Added “\(addedLesson.title)” with \(addedLesson.notes.count) notes.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Play it now") { dismiss(); app.showGrownUps = false; app.open(addedLesson) }.buttonStyle(.borderedProminent)
                    }
                }
                Spacer()
                Text("Works best for simple tunes played or sung one note at a time. Nothing is recorded or sent anywhere.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            }
            .padding(.top, 20)
            .navigationTitle("Listen to a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onDisappear { Task { _ = await recorder.stop(); app.synth.restoreSession() } }
    }

    private func finish() {
        working = true
        message = nil
        Task {
            let heard = await recorder.stop()
            app.synth.restoreSession()
            working = false
            if let lesson = app.addListenedLesson(from: heard) {
                addedLesson = lesson
            } else {
                message = "I couldn't hear enough separate notes. Try again a little slower, one note at a time, and a bit closer."
            }
        }
    }
}
