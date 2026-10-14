import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Plays Apple's 30 second sample so a grown-up can confirm "yes, that's the song". The sample is never analysed.
@MainActor
final class PreviewPlayer: ObservableObject {
    @Published private(set) var playingID: String?
    private var player: AVPlayer?
    private var observer: NSObjectProtocol?

    func toggle(_ song: CatalogSong) {
        if playingID == song.id { stop(); return }
        stop()
        guard let url = song.previewURL else { return }
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        playingID = song.id
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        player?.play()
    }

    func stop() {
        player?.pause()
        player = nil
        playingID = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// A grown-up's song search that works like a browser: type a song, watch each place get checked, pick the right one from the
/// list, then see what can really be done for it.
struct SongSearchView: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = PreviewPlayer()
    @State private var text = ""
    @State private var importingAudio = false
    @State private var listening = false
    @FocusState private var focused: Bool

    private var state: AppModel.SongSearchState { app.songSearch }

    var body: some View {
        NavigationStack {
            List {
                searchSection
                if let results = state.results {
                    stepsSection(results)
                    if let song = state.chosen { chosenSection(song) }
                    resultSections(results)
                }
            }
            .navigationTitle("Find a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview.stop(); dismiss() } } }
            .fileImporter(isPresented: $importingAudio, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { Task { await app.transcribeRecording(at: url) } }
            }
            .sheet(isPresented: $listening) { ListenView(app: app) }
            .onAppear { if text.isEmpty { text = state.query } }
            .onDisappear { preview.stop() }
        }
    }

    // MARK: Search box

    private var searchSection: some View {
        Section {
            HStack {
                TextField("Song name, artist, or a request", text: $text)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit(search)
                    .accessibilityIdentifier("songSearchField")
                Button("Search", action: search)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || state.running)
                    .accessibilityIdentifier("songSearchButton")
            }
        } footer: {
            Text("Searching sends only the words you type to \(SongSearcher.catalogueSites), and to \(OnlineMelodySearch.sites). No sound, pictures or camera data leave the iPad.")
        }
    }

    private func search() {
        focused = false
        preview.stop()
        Task { await app.searchSongs(text) }
    }

    // MARK: Progress

    private func stepsSection(_ results: SongSearchResults) -> some View {
        Section(state.running ? "Looking for “\(state.query)”…" : "Looked for “\(state.query)”") {
            ForEach(SearchStep.allCases, id: \.self) { step in
                HStack {
                    stepIcon(results.steps[step] ?? .waiting)
                    Text(step.label)
                    Spacer()
                    if case .done(let count) = results.steps[step] { Text(count == 0 ? "nothing" : "\(count) found").foregroundStyle(.secondary) }
                    if results.steps[step] == .failed { Text("couldn't reach it").foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("step-\(step.rawValue)")
            }
        }
    }

    @ViewBuilder private func stepIcon(_ step: StepState) -> some View {
        switch step {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .working: ProgressView()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
        }
    }

    // MARK: Results

    @ViewBuilder private func resultSections(_ results: SongSearchResults) -> some View {
        if !results.yours.isEmpty {
            Section("In your songs") {
                ForEach(results.yours) { lesson in
                    Button { dismiss(); app.open(lesson) } label: { row(lesson.emoji, lesson.title, lesson.composer, "play.fill") }
                }
            }
        }
        if !results.library.isEmpty {
            Section("In the free song library") {
                ForEach(results.library) { song in
                    Button { app.addSuggestion(song) } label: { row(song.emoji, song.title, song.composer, "plus.circle.fill") }
                }
            }
        }
        if !results.catalogue.isEmpty {
            Section("Is this the song?") {
                ForEach(results.catalogue) { song in catalogueRow(song) }
            }
        }
        if !results.files.isEmpty {
            Section("Free files we can use") {
                ForEach(results.files) { file in fileRow(file) }
            }
        }
        if !state.running, results.isEmpty {
            Section { Text("Nothing found. Check the spelling, or try the artist's name.").foregroundStyle(.secondary) }
        }
    }

    private func row(_ emoji: String, _ title: String, _ subtitle: String?, _ icon: String) -> some View {
        HStack {
            Text(emoji).font(.title2)
            VStack(alignment: .leading) {
                Text(title).font(.body.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: icon)
        }
    }

    private func catalogueRow(_ song: CatalogSong) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: song.artworkURL) { image in image.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
                .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.body.weight(.semibold))
                Text([song.artist, song.album, song.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if song.previewURL != nil {
                Button { preview.toggle(song) } label: { Image(systemName: preview.playingID == song.id ? "stop.circle.fill" : "play.circle.fill").font(.title) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(preview.playingID == song.id ? "Stop sample" : "Play 30 second sample")
            }
            Button(state.chosen?.id == song.id ? "Chosen" : "This one") { preview.stop(); app.chooseCatalogSong(song) }
                .buttonStyle(.bordered)
                .disabled(state.chosen?.id == song.id)
        }
    }

    private func fileRow(_ file: OnlineCandidate) -> some View {
        Button { Task { await app.addOnline(file, from: state.query) } } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(file.title).font(.body.weight(.semibold)); Spacer(); Image(systemName: "plus.circle.fill") }
                Text("\(file.site.rawValue) · \(file.licence)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: What can we do?

    private func chosenSection(_ song: CatalogSong) -> some View {
        Section("What we can do for “\(song.title)”") {
            if let options = state.options {
                if let library = options.library {
                    Button { app.addSuggestion(library) } label: { Label("Add “\(library.title)” from the free library", systemImage: "books.vertical") }
                }
                ForEach(options.files) { file in
                    Button { Task { await app.addOnline(file, from: song.title) } } label: { Label("Add the open file “\(file.title)” (\(file.licence))", systemImage: "globe") }
                }
                if options.needsOwnSource {
                    Text("There are no free notes to download for this song because it is copyrighted music. These real options work:")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button { importingAudio = true } label: { Label("Use a recording you have…", systemImage: "waveform") }
                .disabled(app.transcribing != nil)
            Button { listening = true } label: { Label("Play or hum it near the iPad", systemImage: "mic") }
            Button { app.makePracticeTune(for: song.title) } label: { Label("Make a practice tune (not the real song)", systemImage: "music.note") }
            progress
        }
        .accessibilityIdentifier("whatWeCanDo")
    }

    @ViewBuilder private var progress: some View {
        if let value = app.transcribing {
            HStack { ProgressView(value: value).frame(maxWidth: 160); Text("Finding the notes…").font(.footnote).foregroundStyle(.secondary) }
        }
        if case .adding(let file) = app.webSearch {
            HStack { ProgressView(); Text("Making a lesson from “\(file.title)”…").font(.footnote).foregroundStyle(.secondary) }
        }
        if case .added(let message, let lesson) = app.generation {
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("Play “\(lesson.title)” now") { dismiss(); app.open(lesson) }.buttonStyle(.bordered)
        }
        if case .failed(let message) = app.generation { Label(message, systemImage: "info.circle").foregroundStyle(.secondary) }
        if case .failed(let message) = app.webSearch { Label(message, systemImage: "info.circle").foregroundStyle(.secondary) }
    }
}
