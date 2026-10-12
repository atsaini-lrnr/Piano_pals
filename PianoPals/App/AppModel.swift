import AVFoundation
import Combine
import SwiftUI

/// Root object: owns every service and wires camera, MIDI and lesson logic together.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case home
        case songs
        case lesson
        case calibration
    }

    enum GenerationState: Equatable {
        case idle
        case working
        case done(message: String, usedFallback: Bool)
        case failed(String)
    }

    @Published var screen: Screen = .home
    @Published var showGrownUps = false
    @Published var showCameraPicker = false
    @Published private(set) var songs: [Lesson]
    @Published private(set) var generation: GenerationState = .idle
    @Published private(set) var regions: [CameraChannelID: KeyboardRegion] = [:]

    let settings: AppSettings
    let midi = MIDIManager()
    let cameras = CameraHub()
    let session = LessonSession()
    let avatar = AvatarModel()
    let confetti = ConfettiModel()
    let synth = ToneSynth()
    let narrator = Narrator()
    let history = HandFrameHistory()

    var generator: LessonGenerating
    private let calibrationStore = CalibrationStore()
    private var cancellables: Set<AnyCancellable> = []
    private var pumpContinuation: AsyncStream<MIDINoteEvent>.Continuation?
    private var demoTask: Task<Void, Never>?
    private var hitCounter = 0

    init(settings: AppSettings = AppSettings(), generator: LessonGenerating = AILessonGeneratorService(transport: MockLessonTransport())) {
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
    }

    func bootstrap() async {
        applyDebugLaunchOptions()
        synth.start()
        midi.start()
        await cameras.start()
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

    func open(_ lesson: Lesson) {
        session.load(lesson)
        screen = .lesson
        narrator.say("Let's play \(lesson.title)! Press the green button to start.")
    }

    func startLesson() {
        avatar.react(to: .started)
        session.start()
        narrator.say("Follow the shapes!")
    }

    func leaveLesson() {
        session.stop()
        narrator.stop()
        screen = .songs
    }

    func generateLesson(from text: String) async {
        generation = .working
        do {
            let result = try await generator.generateLesson(from: text, hand: settings.lessonHand)
            songs.insert(result.lesson, at: 0)
            let message = result.usedFallback
                ? "Added “\(result.lesson.title)” (made on this iPad: \(result.fallbackReason ?? "offline"))."
                : "Added “\(result.lesson.title)”."
            generation = .done(message: message, usedFallback: result.usedFallback)
        } catch is CancellationError {
            generation = .idle
        } catch {
            generation = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
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
            songs.insert(lesson, at: 0)
            generation = .done(message: "Added “\(title)” from the MIDI file.", usedFallback: false)
        } catch {
            generation = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func clearGenerationMessage() { generation = .idle }

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
                if let frame = history.frame(nearest: event.timestamp, channel: channel) {
                    detected = FingerAttributor().attribute(note: Int(event.note), frame: frame, region: region(for: channel))
                }
            }
        }
        session.handleNoteOn(note: Int(event.note), detected: detected)
    }

    // MARK: Reactions

    private func react(to event: SessionEvent) {
        avatar.react(to: event)
        switch event {
        case .noteHit(_, let note, let quality):
            hitCounter += 1
            let origin = CGPoint(x: 0.5, y: 0.75)
            switch quality {
            case .perfect, .fingerUnverified:
                confetti.fire(.burst, at: origin, accent: note.finger.color)
            case .fingerOff:
                confetti.fire(.sparkle, at: origin, accent: note.finger.color)
                narrator.say("Try the \(note.finger.kidName) finger next time!", interrupt: false, minimumGap: 6)
            }
            if hitCounter % 5 == 0, case .perfect = quality { narrator.say(["Great job!", "Wow!", "Amazing!", "You're a star!"].randomElement() ?? "Great job!", interrupt: false, minimumGap: 4) }
        case .gentleMiss:
            if session.consecutiveWrong >= 2 { narrator.say("Try the glowing key!", interrupt: false, minimumGap: 8) }
        case .finished(let stars):
            confetti.fire(.finale, at: CGPoint(x: 0.5, y: 0.35), accent: Palette.sunny)
            synth.playChime()
            narrator.say(stars == 3 ? "Wow! You did it! Three stars!" : "You did it! Great playing!")
        case .started, .freePlay:
            break
        }
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
        if defaults.bool(forKey: "debugGrownUps") { showGrownUps = true }
        if defaults.bool(forKey: "debugCameraPicker") { showCameraPicker = true }
    }
}
#else
extension AppModel {
    func applyDebugLaunchOptions() {}
}
#endif
