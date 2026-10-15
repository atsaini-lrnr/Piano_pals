import SwiftUI

/// Grown-up tool: play or hum a tune near the iPad and turn it into a lesson. Sound is analysed live and not recorded.
struct ListenView: View {
    let app: AppModel
    @StateObject private var recorder = ListenRecorder()
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var addedLesson: Lesson?
    @State private var working = false
    @StateObject private var keys = MIDIRecorder()

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text("Play or sing the song close to the iPad, at any speed. Chords are fine.")
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

                Divider().padding(.horizontal, 40)
                VStack(spacing: 8) {
                    Text("Save a tune you can already play").font(.headline)
                    if keys.isRecording {
                        Button { stopKeys() } label: {
                            Label("Stop (\(keys.keyCount) keys so far)", systemImage: "stop.fill").font(.title3.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 6)
                        }.buttonStyle(.borderedProminent).tint(.red)
                    } else {
                        Button { message = nil; addedLesson = nil; keys.start(listeningTo: app.midi) } label: {
                            Label("Save my playing as a lesson", systemImage: "pianokeys").font(.title3.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 6)
                        }.buttonStyle(.bordered).disabled(working || recorder.state == .listening)
                    }
                    Text("For a tune you already know: play it once on the keyboard and your child can then practise it with the notes, fingers, slow speed and the camera. Every key is kept exactly, with both hands.").font(.footnote).foregroundStyle(.secondary)
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
                Text("The sound is analysed on this iPad and thrown away: nothing is saved or sent anywhere.")
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
            let heard = await recorder.stopWithAudio()
            app.synth.restoreSession()
            let lessons = await app.addHeardLessons(samples: heard.samples, fallback: heard.notes)
            working = false
            if let first = lessons.first {
                addedLesson = first
            } else {
                message = "I couldn't hear clear notes. Try again a bit closer to the iPad, with less noise, or use “Save my playing as a lesson” if you can play it."
            }
        }
    }

    private func stopKeys() {
        let raw = keys.stop()
        if let lesson = app.addRecordedLesson(from: raw) {
            addedLesson = lesson
        } else {
            message = "I didn't catch enough keys. Press “Save my playing as a lesson”, play the tune, then press Stop."
        }
    }
}
