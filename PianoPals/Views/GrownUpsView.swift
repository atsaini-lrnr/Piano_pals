import SwiftUI
import UniformTypeIdentifiers

/// Everything a parent needs: add songs, choose cameras, check the piano connection, tweak behaviour.
struct GrownUpsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        GrownUpsContent(app: app, midi: app.midi, cameras: app.cameras, settings: app.settings)
    }
}

private struct GrownUpsContent: View {
    /// Observed so the song-generation result, progress list and diagnostics redraw when they change.
    @ObservedObject var app: AppModel
    @ObservedObject var midi: MIDIManager
    @ObservedObject var cameras: CameraHub
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var songText = ""
    @State private var importing = false
    @State private var listening = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                songSection
                cameraSection
                pianoSection
                playSection
                progressSection
                calibrationSection
                funSection
                diagnosticsSection
            }
            .navigationTitle("Grown-ups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $listening) { ListenView(app: app) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.midi]) { result in
                if case .success(let url) = result { app.importMIDIFile(at: url) }
            }
        }
    }

    // MARK: Songs

    private var songSection: some View {
        Section {
            TextField("YouTube link, music-share text, or “Title – Composer”", text: $songText, axis: .vertical)
                .lineLimit(1...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .submitLabel(.go)
                .onSubmit(generate)
            Picker("Hand", selection: $settings.lessonHand) {
                ForEach(HandSide.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Button(action: generate) {
                    if app.generation == .working { ProgressView().padding(.trailing, 6) }
                    Text(app.generation == .working ? "Making your song…" : "Make a lesson")
                }
                .buttonStyle(.borderedProminent)
                .disabled(songText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.generation == .working)
                Spacer()
                Button("Listen to a song…") { listening = true }.buttonStyle(.bordered)
                Button("Import MIDI…") { importing = true }.buttonStyle(.bordered)
            }
            switch app.generation {
            case .added(let message, let lesson):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Color.green)
                    Button("Play “\(lesson.title)” now") {
                        dismiss()
                        app.open(lesson)
                    }
                    .buttonStyle(.bordered)
                }
            case .notFound(let info):
                NotFoundCard(info: info, app: app)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default:
                EmptyView()
            }
        } header: {
            Text("Add a song")
        } footer: {
            Text("Try a title (“Ode to Joy”), a YouTube link (only the video's title is read), or notes like “C4 D4 E4 F4 G4 F4 E4 D4 C4:2”. If a song isn't in the free library you'll be offered the closest ones, a MIDI import, or a clearly-labelled practice tune.")
        }
    }

    private func generate() {
        let text = songText
        fieldFocused = false
        Task {
            await app.generateLesson(from: text)
            if case .added = app.generation { songText = "" }
        }
    }

    // MARK: Cameras

    private var cameraSection: some View {
        Section {
            ForEach(CameraChannelID.allCases) { id in
                CameraChannelRow(channel: cameras.channel(id), id: id)
            }
            LabeledContent("Cameras this iPad can see") {
                Text(cameras.availableDevices.isEmpty ? "none" : cameras.availableDevices.map(\.name).joined(separator: ", "))
                    .font(.footnote).multilineTextAlignment(.trailing)
            }
            Button("Choose cameras (including your iPhone)…") { app.showCameraPicker = true }
            Toggle("Line up the camera with the keys", isOn: $settings.alignedCamera)
            Toggle("Show the camera picture (off = just keys and fingers)", isOn: $settings.showFootage)
            Toggle("Also show the iPad's front camera", isOn: $settings.showSideView)
            Picker("Layout", selection: $cameras.layout) {
                ForEach(CameraLayout.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Hands are tracked on", selection: $cameras.trackingPreference) {
                ForEach(TrackingPreference.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Camera speed", selection: Binding(get: { cameras.preferredFPS }, set: { cameras.preferredFPS = $0; cameras.restartChannels() })) {
                Text("30 fps").tag(30.0)
                Text("60 fps (smoothest)").tag(60.0)
            }
        } header: { Text("Cameras") }
    }

    // MARK: Piano

    private var pianoSection: some View {
        Section {
            HStack {
                Image(systemName: midi.isKeyboardConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(midi.isKeyboardConnected ? Color.green : Color.orange)
                VStack(alignment: .leading) {
                    Text(midi.isKeyboardConnected ? "Keyboard connected" : "No keyboard found").font(.headline)
                    if midi.sources.isEmpty {
                        Text("Plug the keyboard into the iPad's USB-C port and switch it on.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(midi.sources) { Text($0.name).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            if case .failed(let message) = midi.status { Text(message).foregroundStyle(.red) }
            Picker("Keyboard size", selection: $settings.keyboardPreset) {
                ForEach(KeyboardPreset.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Play sound for on-screen keys", isOn: $settings.onScreenSound)
            Toggle("Play sound for the real keyboard", isOn: $settings.hardwareSound)
        } header: { Text("Piano") } footer: {
            Text("Leave “real keyboard” sound off if your keyboard has its own speakers. Changing the keyboard size means the hands need calibrating again.")
        }
    }

    // MARK: Play

    private var playSection: some View {
        Section {
            Picker("How the song moves", selection: $settings.paceMode) {
                ForEach(PaceMode.allCases) { Text($0.displayName).tag($0) }
            }
            VStack(alignment: .leading) {
                Text("Speed: \(Int(settings.tempoScale * 100))%")
                Slider(value: $settings.tempoScale, in: 0.4...1.2, step: 0.05)
            }
        } header: { Text("Playing") } footer: {
            Text("“Wait for me” pauses the song until the right key is played — best for beginners.")
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        Section {
            if let note = app.parentNote {
                Text(note).font(.callout)
            }
            if app.progress.isEmpty {
                Text("Finished songs will show up here.").foregroundStyle(.secondary)
            }
            ForEach(app.progress.prefix(6)) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.lessonTitle).font(.headline)
                        Spacer()
                        Text(String(repeating: "★", count: item.stars) + String(repeating: "☆", count: 3 - item.stars)).foregroundStyle(.orange)
                    }
                    Text("\(Int((item.firstTryAccuracy * 100).rounded()))% first try"
                         + (item.fingerAccuracy.map { " · fingers \(Int(($0 * 100).rounded()))%" } ?? "")
                         + (item.weakestFinger.flatMap(Finger.init(rawValue:)).map { " · practise the \($0.displayName.lowercased()) finger" } ?? "")
                         + " · " + item.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !app.progress.isEmpty { Button("Clear progress", role: .destructive) { app.clearProgress() } }
        } header: { Text("Progress") } footer: {
            Text("Kept on this iPad only. The last 30 songs are remembered.")
        }
    }

    // MARK: Calibration

    private var calibrationSection: some View {
        Section {
            ForEach(CameraChannelID.allCases) { id in
                HStack {
                    Label(id.displayName, systemImage: app.isCalibrated(id) ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(app.isCalibrated(id) ? Color.green : Color.secondary)
                    Spacer()
                    if app.isCalibrated(id) { Button("Reset") { app.resetCalibration(for: id) }.buttonStyle(.bordered) }
                }
            }
            Button("Calibrate hands now") {
                dismiss()
                app.screen = .calibration
            }
        } header: { Text("Hand calibration") } footer: {
            Text("Hands are calibrated for whichever camera tracks them. Calibrate again whenever the camera or keyboard moves.")
        }
    }

    // MARK: Fun

    private var funSection: some View {
        Section {
            Toggle("Spoken helper", isOn: $settings.narrationEnabled)
            Toggle("Panda copies your child's smile", isOn: $settings.mirrorSmile)
        } header: { Text("Voice and fun") } footer: {
            Text("Smiles are read from the front camera on the iPad and never saved or sent anywhere.")
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            ForEach(CameraChannelID.allCases) { id in
                DiagnosticRow(channel: cameras.channel(id), id: id)
            }
            LabeledContent("MIDI notes received", value: "\(midi.eventCount)")
            LabeledContent("Key → reaction (median / slowest 5%)") {
                if let p50 = app.diagnostics.latencyP50, let p95 = app.diagnostics.latencyP95 {
                    Text(String(format: "%.0f / %.0f ms (%d notes)", p50, p95, app.diagnostics.samples))
                        .foregroundStyle(p95 <= 150 ? Color.green : Color.orange)
                } else { Text("play a song to measure") }
            }
            LabeledContent("Finger seen by camera") {
                if let rate = app.diagnostics.fingerVerifiedRate {
                    Text("\(Int((rate * 100).rounded()))% of notes").foregroundStyle(rate >= 0.8 ? Color.green : Color.orange)
                } else { Text("play a song to measure") }
            }
            Toggle("Demo hands (no camera needed)", isOn: $settings.demoHands)
            if settings.demoHands { Toggle("Demo hand uses the wrong finger", isOn: $settings.demoWrongFinger) }
        } header: { Text("Diagnostics") } footer: {
            Text("Demo hands draws pretend hands so you can try the screens without a camera, for example in the Simulator.")
        }
    }
}

private struct CameraChannelRow: View {
    @ObservedObject var channel: CameraChannel
    let id: CameraChannelID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: channel.deviceInfo?.symbolName ?? "video.slash").frame(width: 30)
                VStack(alignment: .leading) {
                    Text(id.displayName).font(.headline)
                    Text(channel.deviceInfo?.name ?? "No camera").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if channel.deviceInfo != nil {
                HStack {
                    Stepper("Turn picture \(channel.manualRotation)°", value: Binding(get: { channel.manualRotation / 90 }, set: { channel.manualRotation = (($0 % 4) + 4) % 4 * 90 }), in: -100...100)
                    Toggle("Flip", isOn: $channel.flipHorizontally).fixedSize()
                }
            }
        }
    }
}

private struct DiagnosticRow: View {
    @ObservedObject var channel: CameraChannel
    let id: CameraChannelID

    var body: some View {
        LabeledContent(id.displayName) {
            if channel.state == .running {
                Text(String(format: "%.0f fps · %d hand%@", channel.framesPerSecond, channel.latestFrame?.hands.count ?? 0,
                            (channel.latestFrame?.hands.count ?? 0) == 1 ? "" : "s"))
            } else {
                Text(String(describing: channel.state))
            }
        }
    }
}


/// Shown when a song isn't in the free library: honest explanation plus real next steps.
private struct NotFoundCard: View {
    let info: NotFoundInfo
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(info.reason, systemImage: "magnifyingglass").foregroundStyle(Color.orange)
            if !info.suggestions.isEmpty {
                Text("Did you mean…").font(.subheadline.weight(.semibold))
                ForEach(info.suggestions) { song in
                    Button {
                        app.addSuggestion(song)
                    } label: {
                        HStack {
                            Text(song.emoji)
                            Text(song.title)
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("You can also play or hum it near the iPad (Listen to a song…) or import a MIDI file.").font(.footnote).foregroundStyle(.secondary)
            Button("Make a practice tune anyway (not the real song)") { app.makePracticeTune(for: info.resolvedTitle ?? info.query) }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}
