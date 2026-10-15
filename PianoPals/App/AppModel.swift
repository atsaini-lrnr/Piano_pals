import AVFoundation
import Combine
import SwiftUI

/// Root object: owns every service and wires camera, MIDI and lesson logic together.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case home
        case songs
        case practice
        case lesson
        case calibration
    }

    enum GenerationState: Equatable {
        case idle
        case working
        case added(message: String, lesson: Lesson)
        case notFound(NotFoundInfo)
        case failed(String)
    }

    @Published var screen: Screen = .home
    @Published var showGrownUps = false
    @Published var showCameraPicker = false
    @Published private(set) var songs: [Lesson]
    @Published private(set) var generation: GenerationState = .idle
    /// The grown-up's explicit "search the web" for a song that isn't in the free library.
    enum WebSearchState: Equatable {
        case idle
        case searching(String)
        case results(query: String, [OnlineCandidate])
        case adding(OnlineCandidate)
        case failed(String)
    }
    @Published private(set) var webSearch: WebSearchState = .idle
    /// The grown-up's browser-like song search: what is being looked up, step by step, and the song they picked.
    struct SongSearchState: Equatable {
        var query = ""
        var running = false
        var results: SongSearchResults?
        var chosen: CatalogSong?
        var options: SongOptions?
    }
    @Published private(set) var songSearch = SongSearchState()
    var songSearcher = SongSearcher()
    /// 0…1 while a recording is being turned into notes; nil otherwise.
    @Published private(set) var transcribing: Double?
    var onlineSearch: OnlineMelodySearching = OnlineMelodySearch()
    @Published private(set) var regions: [CameraChannelID: KeyboardRegion] = [:]
    /// What the coach just said (shown in the panda's bubble) and which finger it wants the child to look at.
    @Published private(set) var coachMessage: String?
    @Published private(set) var fingerCue: Finger?
    /// Shown on the camera view for a few seconds after the right key is played with the wrong finger or hand.
    @Published private(set) var correction: FingerCorrection?
    private var correctionTask: Task<Void, Never>?
    @Published private(set) var progress: [SessionSummary] = []
    /// Plain-language note for the grown-up about the latest session.
    @Published private(set) var parentNote: String?
    /// The practice block being worked through, if any.
    @Published private(set) var routine: RoutineState?
    /// Where "back" goes from a lesson (the song list or the practice screen).
    private var lessonReturnScreen: Screen = .songs

    struct RoutineState {
        let plan: PracticePlan
        var index = 0
        var stars: [Int] = []

        var current: PracticeStep? { plan.steps.indices.contains(index) ? plan.steps[index] : nil }
        var hasNext: Bool { index + 1 < plan.steps.count }
        var isFinished: Bool { index >= plan.steps.count }
    }

    /// The stretch of keyboard currently on screen (see `SpanFollower`).
    @Published private(set) var visibleSpan = KeyboardSpan.fitting(low: 60, high: 67, minimumWhiteKeys: 15)
    private var spanFollower = SpanFollower()

    /// Re-centres the on-screen window on the notes about to be played; animates when it jumps an octave.
    func updateVisibleSpan() {
        guard let lesson = session.lesson, let low = lesson.lowestNote, let high = lesson.highestNote else { return }
        if spanFollower.limit != keyboardRange { spanFollower = SpanFollower(windowKeys: 15, limit: keyboardRange) }
        let upcoming = session.noteProgress.indices
            .filter { session.noteProgress[$0] == .pending }.prefix(4).map { lesson.notes[$0].noteNumber }
        let next = spanFollower.update(lessonRange: low...high, upcoming: Array(upcoming))
        if next != visibleSpan { withAnimation(.easeInOut(duration: 0.4)) { visibleSpan = next } }
    }

    var dailyPlan: PracticePlan { PracticePlanner.dailyPlan(progress: progress, range: keyboardRange) }

    /// Songs that fit on the chosen keyboard size.
    var visibleSongs: [Lesson] { songs.filter { $0.fits(in: keyboardRange) } }
    var hiddenSongCount: Int { songs.count - visibleSongs.count }

    let settings: AppSettings
    let midi = MIDIManager()
    let cameras = CameraHub()
    let session = LessonSession()
    let avatar = AvatarModel()
    let confetti = ConfettiModel()
    let synth = ToneSynth()
    let narrator = Narrator()
    let history = HandFrameHistory()
    /// Key press → app reaction, in milliseconds (shown in Grown-ups ▸ Diagnostics).
    let latency = LatencyMeter()
    @Published private(set) var diagnostics = Diagnostics()

    struct Diagnostics: Equatable {
        var latencyP50: Double?
        var latencyP95: Double?
        var samples = 0
        /// Share of correct notes whose finger the camera could judge.
        var fingerVerifiedRate: Double?
    }

    var generator: LessonGenerating
    private let calibrationStore = CalibrationStore()
    private var cancellables: Set<AnyCancellable> = []
    private var pumpContinuation: AsyncStream<MIDINoteEvent>.Continuation?
    private var demoTask: Task<Void, Never>?
    #if DEBUG
    private let rawProbe = RawCameraProbe()
    #endif
    private var analyzer = MistakeAnalyzer()
    private var coach = Coach()
    private let progressStore = ProgressStore()
    var summaryPhraser: SummaryPhrasing = OnDeviceSummaryPhraser()
    private var lessonStartedAt: Date?
    private var coachClock: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var cueTask: Task<Void, Never>?

    init(settings: AppSettings = AppSettings(),
         generator: LessonGenerating = AILessonGeneratorService(titleCleaner: OnDeviceTitleCleaner())) {
        self.settings = settings
        self.generator = generator
        self.songs = SongLibrary.all.map { $0.lesson(hand: settings.lessonHand) }
        configure()
    }

    // MARK: Setup

    private func configure() {
        session.mode = settings.paceMode
        session.tempoScale = settings.tempoScale
        narrator.isEnabled = settings.narrationEnabled
        loadRegions()
        progress = progressStore.load()

        // Settings → live objects.
        settings.$paceMode.sink { [weak self] in self?.session.mode = $0 }.store(in: &cancellables)
        settings.$tempoScale.sink { [weak self] in self?.session.tempoScale = $0 }.store(in: &cancellables)
        settings.$narrationEnabled.sink { [weak self] in self?.narrator.isEnabled = $0 }.store(in: &cancellables)
        settings.$keyboardPreset.dropFirst().sink { [weak self] _ in self?.loadRegions() }.store(in: &cancellables)
        settings.$demoHands.sink { [weak self] in self?.setDemoHands($0) }.store(in: &cancellables)

        // Camera frames → history (used to attribute fingers at MIDI strike time).
        for id in CameraChannelID.allCases {
            let history = self.history
            cameras.channel(id).onHandFrame = { frame in history.append(frame) }
        }
        // Child's smile (front camera) → avatar.
        cameras.primary.$face.sink { [weak self] face in
            guard let self else { return }
            self.avatar.childSmile = self.settings.mirrorSmile ? (face?.smile ?? 0) : 0
        }.store(in: &cancellables)

        // MIDI → ordered pipeline.
        let stream = AsyncStream<MIDINoteEvent> { continuation in self.pumpContinuation = continuation }
        Task { [weak self] in
            for await event in stream { await self?.process(event) }
        }
        midi.noteEvents.sink { [weak self] in self?.pumpContinuation?.yield($0) }.store(in: &cancellables)

        // Lesson events → avatar, confetti, narration, sounds.
        session.events.sink { [weak self] in self?.react(to: $0) }.store(in: &cancellables)
        // Forward nested changes so views observing only the model refresh.
        session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        session.$targets.sink { [weak self] _ in self?.updateVisibleSpan() }.store(in: &cancellables)
    }

    func bootstrap() async {
        applyDebugLaunchOptions()
        synth.start()
        midi.start()
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "debugRawCamera") {
            let delay = UserDefaults.standard.double(forKey: "debugRawDelay")
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            rawProbe.start(position: raw == "back" ? .back : .front)
            return
        }
        #endif
        await cameras.start()
        cameras.resumeCompanionIfKnown()
    }

    // MARK: Keyboard regions

    var keyboardRange: ClosedRange<Int> { settings.keyboardRange }

    func loadRegions() {
        var loaded: [CameraChannelID: KeyboardRegion] = [:]
        let range = keyboardRange
        for id in CameraChannelID.allCases {
            if let saved = calibrationStore.load(channel: id, firstNote: range.lowerBound, lastNote: range.upperBound) {
                loaded[id] = saved
            }
        }
        regions = loaded
    }

    func region(for channel: CameraChannelID) -> KeyboardRegion {
        if settings.demoHands, channel == .primary {
            return DemoHandSource.region(firstNote: keyboardRange.lowerBound, lastNote: keyboardRange.upperBound)
        }
        return regions[channel] ?? .uncalibrated(firstNote: keyboardRange.lowerBound, lastNote: keyboardRange.upperBound)
    }

    func isCalibrated(_ channel: CameraChannelID) -> Bool { regions[channel]?.isCalibrated ?? false }

    func saveCalibration(_ region: KeyboardRegion, for channel: CameraChannelID) {
        calibrationStore.save(region, channel: channel)
        regions[channel] = region
    }

    func resetCalibration(for channel: CameraChannelID) {
        calibrationStore.clear(channel: channel)
        regions[channel] = nil
    }

    // MARK: Lessons

    func open(_ lesson: Lesson, returnTo: Screen = .songs) {
        session.load(lesson)
        lessonReturnScreen = returnTo
        spanFollower = SpanFollower(windowKeys: 15, limit: keyboardRange)
        updateVisibleSpan()
        screen = .lesson
        narrator.say("Let's play \(lesson.title)! Press the green button to start.")
    }

    func startLesson() {
        avatar.react(to: .started)
        session.start()
        narrator.say("Follow the shapes!")
    }

    func leaveLesson() {
        coachClock?.cancel()
        session.stop()
        narrator.stop()
        routine = nil
        screen = lessonReturnScreen
    }

    // MARK: Practice

    func startRoutine(_ plan: PracticePlan) {
        routine = RoutineState(plan: plan)
        if let step = routine?.current { open(step.lesson, returnTo: .practice) }
        narrator.say("Time to practice! Let's start with a warm-up.")
    }

    /// Called from the finish card: records the stars and opens the next step (or finishes the block).
    func advanceRoutine() {
        guard var state = routine else { return }
        state.stars.append(session.stars)
        if state.hasNext {
            state.index += 1
            routine = state
            if let step = state.current { open(step.lesson, returnTo: .practice) }
        } else {
            state.index = state.plan.steps.count
            routine = state
            session.stop()
            narrator.say("Wow! You finished your practice!")
            confetti.fire(.finale, at: CGPoint(x: 0.5, y: 0.3), accent: Palette.sunny)
        }
    }

    func endRoutine() {
        routine = nil
        screen = .practice
    }

    func generateLesson(from text: String) async {
        generation = .working
        webSearch = .idle
        do {
            switch try await generator.generateLesson(from: text, hand: settings.lessonHand) {
            case .lesson(let lesson, let origin):
                add(lesson)
                let how: String
                switch origin {
                case .library: how = "found in the free song library"
                case .notation: how = "fingered on this iPad"
                }
                generation = .added(message: "Added “\(lesson.title)” (\(how)).", lesson: lesson)
            case .notFound(let info):
                generation = .notFound(info)
            }
        } catch is CancellationError {
            generation = .idle
        } catch {
            generation = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Looks on Mutopia and Wikimedia Commons (open licences only). Only the search words are sent.
    func searchWeb(for query: String) async {
        webSearch = .searching(query)
        do {
            let found = try await onlineSearch.search(query)
            webSearch = found.isEmpty ? .failed("Nothing with an open licence matched “\(query)”. Try the composer's name, or play it near the iPad with Listen.") : .results(query: query, found)
        } catch {
            webSearch = .failed("Couldn't reach the music websites. Check the internet connection and try again.")
        }
    }

    /// Downloads one chosen file (≤ 600 KB, must be real MIDI) and turns the opening melody into a lesson.
    func addOnline(_ candidate: OnlineCandidate, from query: String) async {
        webSearch = .adding(candidate)
        do {
            let data = try await onlineSearch.download(candidate)
            let lesson = try OnlineImport.lesson(from: data, candidate: candidate, hand: settings.lessonHand)
            add(lesson)
            webSearch = .idle
            generation = .added(message: "Added “\(lesson.title)” from \(candidate.site.rawValue) (\(candidate.licence)).", lesson: lesson)
        } catch {
            webSearch = .failed((error as? LocalizedError)?.errorDescription ?? "That one didn't work. Try another result.")
        }
    }

    func clearWebSearch() { webSearch = .idle }

    /// Looks in your songs, the free library, the song catalogues and the open-file sites; each step reports as it finishes.
    func searchSongs(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !songSearch.running else { return }
        songSearch = SongSearchState(query: trimmed, running: true, results: SongSearchResults(steps: Dictionary(uniqueKeysWithValues: SearchStep.allCases.map { ($0, StepState.waiting) })))
        let results = await songSearcher.search(trimmed, songs: songs) { step, state in
            Task { @MainActor in self.songSearch.results?.steps[step] = state }
        }
        songSearch.results = results
        songSearch.running = false
    }

    /// Picking a catalogue entry works out which real options exist for it.
    func chooseCatalogSong(_ song: CatalogSong?) {
        songSearch.chosen = song
        songSearch.options = song.flatMap { chosen in songSearch.results.map { SongOptions.make(for: chosen, library: songSearcher.library, files: $0.files) } }
    }

    func clearSongSearch() { songSearch = SongSearchState() }

    /// Adds a library suggestion the grown-up picked from the not-found card.
    func addSuggestion(_ song: LibrarySong) {
        let lesson = song.lesson(hand: settings.lessonHand)
        add(lesson)
        generation = .added(message: "Added “\(lesson.title)”.", lesson: lesson)
    }

    /// An explicit, clearly-labelled practice tune (never presented as the real song).
    func makePracticeTune(for text: String) {
        let lesson = LocalLessonEngine().practiceTune(seed: text, label: text, hand: settings.lessonHand)
        add(lesson)
        generation = .added(message: "Added “\(lesson.title)”. This is a practice tune, not the real song.", lesson: lesson)
    }

    /// Adds a lesson to the top of the song list, replacing an older entry with the same title.
    func add(_ lesson: Lesson) {
        songs.removeAll { $0.title == lesson.title }
        songs.insert(lesson, at: 0)
    }

    /// Turns a recording (wav, m4a, mp3…) into lessons on this iPad. Nothing is uploaded and the recording isn't kept.
    func transcribeRecording(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard transcribing == nil else { return }
        transcribing = 0
        generation = .idle
        let title = url.deletingPathExtension().lastPathComponent
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try RecordingTranscriber().transcribe(url: url, title: title) { fraction in
                    Task { @MainActor in self.transcribing = fraction }
                }
            }.value
            for lesson in result.lessons.reversed() { add(lesson) }
            let hands = result.lessons.count == 2 ? "right and left hand" : "right hand"
            generation = .added(message: "Added “\(title)” (\(hands)) from your recording, found with the \(result.method.rawValue).", lesson: result.lessons[0])
        } catch is CancellationError {
            generation = .idle
        } catch {
            generation = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        transcribing = nil
    }

    func importMIDIFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let raw = try StandardMIDIFile.parse(data)
            let engine = LocalLessonEngine()
            let title = url.deletingPathExtension().lastPathComponent
            let lesson = engine.lesson(title: title, rawNotes: raw, hand: settings.lessonHand, source: .imported,
                                       description: "Imported MIDI file, fingered on this iPad", emoji: "📁")
            guard !lesson.notes.isEmpty else { throw MIDIFileError.noNotes }
            add(lesson)
            generation = .added(message: "Added “\(title)” from the MIDI file.", lesson: lesson)
        } catch {
            generation = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Turns notes heard through the microphone into a lesson. nil when too few notes were recognised.
    func addListenedLesson(from heard: [RawNote]) -> Lesson? {
        let title = "Heard tune " + Date().formatted(date: .omitted, time: .shortened)
        guard let lesson = ListenTranscriber.lesson(from: heard, hand: settings.lessonHand, title: title) else { return nil }
        add(lesson)
        generation = .added(message: "Added “\(lesson.title)”.", lesson: lesson)
        return lesson
    }


    // MARK: Input pipeline

    /// Called by on-screen keys.
    func virtualKey(_ note: Int, isDown: Bool) {
        midi.injectOnScreen(note: UInt8(clamping: note), isOn: isDown)
    }

    private func process(_ event: MIDINoteEvent) async {
        guard event.isOn else { return }
        let hardware = event.origin == .hardware
        if (hardware && settings.hardwareSound) || (!hardware && settings.onScreenSound) {
            synth.play(note: Int(event.note), velocity: Int(event.velocity))
        }

        var detected: DetectedFinger?
        if session.phase == .playing {
            let channel = cameras.trackingChannel
            // Vision results trail the camera by a few frames: give the frame showing this strike a moment to arrive.
            if let latest = history.latest(for: channel), HostClock.now - latest.timestamp < 0.5 {
                let deadline = event.timestamp + 0.12
                while !history.hasFrame(atOrAfter: event.timestamp + 0.02, channel: channel), HostClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(8))
                }
                // Vote over ~150 ms of frames around the strike so one jittery frame can't decide.
                let frames = history.frames(from: event.timestamp - 0.10, to: event.timestamp + 0.05, channel: channel)
                detected = FingerAttributor().attribute(note: Int(event.note), frames: frames, region: region(for: channel))
            }
        }
        let wasPlaying = session.phase == .playing
        session.handleNoteOn(note: Int(event.note), detected: detected)
        if wasPlaying { recordDiagnostics(eventTime: event.timestamp) }
    }

    private func recordDiagnostics(eventTime: TimeInterval) {
        latency.record(milliseconds: (HostClock.now - eventTime) * 1000)
        let stats = analyzer.stats
        diagnostics = Diagnostics(latencyP50: latency.percentile(50), latencyP95: latency.percentile(95), samples: latency.count,
                                  fingerVerifiedRate: stats.hits > 0 ? Double(stats.fingerVerified) / Double(stats.hits) : nil)
    }

    // MARK: Reactions

    private func react(to event: SessionEvent) {
        avatar.react(to: event)
        let now = HostClock.now

        // Visual celebrations.
        switch event {
        case .noteHit(_, let note, let quality):
            let origin = CGPoint(x: 0.5, y: 0.75)
            switch quality {
            case .perfect, .fingerUnverified:
                confetti.fire(.burst, at: origin, accent: note.finger.color)
            case .fingerOff, .wrongHand:
                confetti.fire(.sparkle, at: origin, accent: note.finger.color)
            }
        case .finished:
            confetti.fire(.finale, at: CGPoint(x: 0.5, y: 0.35), accent: Palette.sunny)
            synth.playChime()
        default:
            break
        }

        if case .noteHit(_, let note, let quality) = event {
            switch quality {
            case .fingerOff(let played): showCorrection(FingerCorrection(expected: note.finger, played: played, wrongHand: nil))
            case .wrongHand(let side): showCorrection(FingerCorrection(expected: note.finger, played: nil, wrongHand: side))
            case .perfect, .fingerUnverified: break
            }
        }

        // Mistakes → coach.
        var actions: [CoachAction] = []
        if case .started = event {
            coach.reset()
            lessonStartedAt = Date()
            startCoachClock()
        }
        let mistakes = analyzer.ingest(event, lessonHand: session.lesson?.hand ?? .right, now: now)
        for mistake in mistakes {
            actions += coach.react(to: mistake, stats: analyzer.stats, mode: settings.paceMode, tempoScale: settings.tempoScale, now: now)
        }
        if case .noteHit(_, _, let quality) = event { actions += coach.reactToHit(quality: quality, now: now) }
        if case .finished(let stars) = event {
            coachClock?.cancel()
            actions += coach.reactToFinish(stars: stars, stats: analyzer.stats)
            recordSession(stars: stars)
        }
        perform(actions)
    }

    private func perform(_ actions: [CoachAction]) {
        for action in actions {
            switch action {
            case .say(let text):
                show(message: text)
                narrator.say(text, interrupt: false)
            case .highlightTarget:
                session.showHint()
            case .showFingerHint(let finger):
                fingerCue = finger
                cueTask?.cancel()
                cueTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2.5))
                    guard !Task.isCancelled else { return }
                    self?.fingerCue = nil
                }
            case .adjustPace(let waitForMe, let tempoScale):
                if waitForMe { settings.paceMode = .waitForMe }
                if let tempoScale { settings.tempoScale = tempoScale }
            }
        }
    }

    private func showCorrection(_ new: FingerCorrection) {
        correction = new
        correctionTask?.cancel()
        correctionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.correction = nil
        }
    }

    /// What the camera tile needs in order to coach on `channel`.
    func coachingContext(for channel: CameraChannelID) -> CoachingContext? {
        guard session.phase == .playing || session.phase == .ready || session.phase == .paused || correction != nil else { return nil }
        return CoachingContext(region: region(for: channel), target: session.targets.first?.note, correction: correction,
                               lessonHand: session.lesson?.hand ?? .right)
    }

    private func show(message: String) {
        coachMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            self?.coachMessage = nil
        }
    }

    /// About once a second while playing: notices when the child is stuck (hesitation).
    private func startCoachClock() {
        coachClock?.cancel()
        coachClock = Task { @MainActor [weak self] in
            var lastPhase: LessonSession.Phase = .playing
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let phase = self.session.phase
                if phase == .playing, lastPhase == .paused { self.analyzer.resumed(at: HostClock.now) }
                lastPhase = phase
                guard phase == .playing else { continue }
                let now = HostClock.now
                let mistakes = self.analyzer.tick(now: now, hasTargets: !self.session.targets.isEmpty)
                var actions: [CoachAction] = []
                for mistake in mistakes {
                    actions += self.coach.react(to: mistake, stats: self.analyzer.stats, mode: self.settings.paceMode,
                                                tempoScale: self.settings.tempoScale, now: now)
                }
                self.perform(actions)
            }
        }
    }

    private func recordSession(stars: Int) {
        guard let lesson = session.lesson else { return }
        let duration = lessonStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let summary = SessionSummary(lessonTitle: lesson.title, durationSeconds: duration, notes: lesson.notes.count, stars: stars, stats: analyzer.stats)
        progressStore.append(summary)
        progress = progressStore.load()
        Task { [weak self, summaryPhraser] in
            let text = await summaryPhraser.phrase(for: summary)
            self?.parentNote = text
        }
    }

    func clearProgress() {
        progressStore.clear()
        progress = []
        parentNote = nil
    }

    // MARK: Demo hands (Simulator / UI checks)

    private func setDemoHands(_ enabled: Bool) {
        demoTask?.cancel()
        demoTask = nil
        guard enabled else { return }
        demoTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                self?.emitDemoFrame()
            }
        }
    }

    private func emitDemoFrame() {
        guard cameras.primary.state != .running else { return }
        let now = HostClock.now
        let region = region(for: .primary)
        let frame: HandFrame
        if screen == .calibration {
            return // CalibrationView feeds its own template-matching frames.
        } else if let target = session.targets.first, session.phase == .playing || session.phase == .ready {
            var finger = target.note.finger
            if settings.demoWrongFinger { finger = Finger(rawValue: finger.number % 5 + 1) ?? .index }
            frame = DemoHandSource.playingFrame(channel: .primary, note: target.note.noteNumber, finger: finger,
                                                side: session.lesson?.hand ?? .right, region: region, time: now)
        } else {
            frame = DemoHandSource.playingFrame(channel: .primary, note: 60, finger: .thumb, side: .right, region: region, time: now)
        }
        cameras.primary.publishSynthetic(frame: frame)
    }
}


#if DEBUG
extension AppModel {
    /// Test hooks, only in Debug builds: `-debugScreen songs|lesson|calibration`, `-debugSong <library id>`, `-debugAutostart YES`,
    /// `-debugGrownUps YES`, `-debugCameraPicker YES`, `-debugPlay "60 61 61 60"` (+ `-debugPlayInterval 1.2`).
    func applyDebugLaunchOptions() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "debugSong"), let song = songs.first(where: { $0.title.lowercased().contains(id.lowercased()) }) {
            session.load(song)
        }
        switch defaults.string(forKey: "debugScreen") {
        case "songs": screen = .songs
        case "calibration": screen = .calibration
        case "practice": screen = .practice
        case "lesson":
            if session.lesson == nil, let first = songs.first { session.load(first) }
            screen = .lesson
            if defaults.bool(forKey: "debugAutostart") { startLesson() }
        default: break
        }
        if let script = defaults.string(forKey: "debugPlay") {
            let notes = script.split(separator: " ").compactMap { Int($0) }
            let interval = defaults.double(forKey: "debugPlayInterval")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                for note in notes {
                    virtualKey(note, isDown: true)
                    try? await Task.sleep(for: .milliseconds(120))
                    virtualKey(note, isDown: false)
                    try? await Task.sleep(for: .seconds(interval == 0 ? 1.2 : interval))
                }
            }
        }
        if let query = defaults.string(forKey: "debugQuery") {
            Task { @MainActor in await generateLesson(from: query) }
        }
        if let path = defaults.string(forKey: "debugTranscribe") {
            Task { @MainActor in await transcribeRecording(at: URL(fileURLWithPath: path)) }
        }
        if let find = defaults.string(forKey: "debugSongSearch") {
            Task { @MainActor in
                await searchSongs(find)
                if defaults.bool(forKey: "debugChooseFirst") { chooseCatalogSong(songSearch.results?.catalogue.first) }
            }
        }
        if let web = defaults.string(forKey: "debugWebSearch") {
            Task { @MainActor in
                await searchWeb(for: web)
                if defaults.bool(forKey: "debugWebAddFirst"), case .results(let query, let found) = webSearch, let first = found.first {
                    await addOnline(first, from: query)
                }
            }
        }
        if defaults.bool(forKey: "debugGrownUps") { showGrownUps = true }
        if defaults.bool(forKey: "debugCameraPicker") { showCameraPicker = true }
    }
}
#else
extension AppModel {
    func applyDebugLaunchOptions() {}
}
#endif
