import Combine
import Foundation

enum PaceMode: String, CaseIterable, Identifiable {
    /// The song waits for the child: the next note hangs at the keys until it is played.
    case waitForMe
    /// The song keeps moving; notes that are missed simply fade away (no penalty).
    case playAlong

    var id: String { rawValue }
    var displayName: String { self == .waitForMe ? "Wait for me" : "Play along" }
}

enum HitQuality: Equatable {
    /// Right key, and the camera saw the right finger on it.
    case perfect
    /// Right key; the camera couldn't tell which finger was used.
    case fingerUnverified
    /// Right key, but a different finger than suggested.
    case fingerOff(played: Finger)
    /// Right key, played with the other hand.
    case wrongHand(played: HandSide)
}

enum NoteProgress: Equatable {
    case pending
    case hit(HitQuality)
    case missed
}

enum KeyFeedbackKind: Equatable {
    /// A happy green pulse for a correct key.
    case success
    /// A soft lavender pulse for a key that wasn't the one we wanted — never red, never a sound.
    case gentle
    /// A friendly glow on the key we're hoping for, after a couple of tries.
    case hint
}

struct KeyFeedback: Equatable {
    let id = UUID()
    let kind: KeyFeedbackKind

    static func == (lhs: KeyFeedback, rhs: KeyFeedback) -> Bool { lhs.id == rhs.id }
}

struct LessonTarget: Equatable, Identifiable {
    let index: Int
    let note: Note
    var id: Int { index }
}

enum SessionEvent: Equatable {
    case started
    case noteHit(index: Int, note: Note, quality: HitQuality)
    case gentleMiss(played: Int, expected: [Int])
    /// "Play along" mode only: a note slid past unplayed. Never penalised; used by the coach.
    case noteMissed(index: Int, note: Note)
    case freePlay(note: Int)
    case finished(stars: Int)
}

/// The lesson engine: tracks the song clock, which notes are expected, and what the child has played.
///
/// It is deliberately forgiving. A wrong key or wrong finger never subtracts anything — it only produces a gentle
/// pulse — and a correct key always moves the lesson forward.
@MainActor
final class LessonSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case ready
        case playing
        case paused
        case finished
    }

    /// Seconds of empty lane shown before the first note so the child can see it coming.
    static let leadIn: TimeInterval = 2.0
    /// In "play along" mode, how far from a note's time a key still counts.
    static let hitWindow: TimeInterval = 0.7

    @Published private(set) var lesson: Lesson?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var noteProgress: [NoteProgress] = []
    @Published private(set) var targets: [LessonTarget] = []
    @Published private(set) var keyFeedback: [Int: KeyFeedback] = [:]
    @Published private(set) var stars = 0
    @Published private(set) var consecutiveWrong = 0
    @Published var mode: PaceMode = .waitForMe {
        didSet {
            guard oldValue != mode else { return }
            reanchor(usingScale: tempoScale, mode: oldValue)
            refreshTargets()
        }
    }
    @Published var tempoScale: Double = 0.8 {
        didSet {
            guard oldValue != tempoScale else { return }
            reanchor(usingScale: oldValue, mode: mode)
        }
    }

    let events = PassthroughSubject<SessionEvent, Never>()
    /// Injectable for tests.
    var clock: () -> Date = { Date() }

    private var anchorSong: TimeInterval = -LessonSession.leadIn
    private var anchorWall = Date()
    private var frozenTime: TimeInterval = -LessonSession.leadIn
    private var tickTask: Task<Void, Never>?

    deinit { tickTask?.cancel() }

    // MARK: Queries

    var progressFraction: Double {
        guard !noteProgress.isEmpty else { return 0 }
        return Double(noteProgress.filter { $0 != .pending }.count) / Double(noteProgress.count)
    }

    /// The song position (seconds) at wall-clock `date`. Read by the falling-notes canvas every frame.
    func songTime(at date: Date) -> TimeInterval {
        songTime(at: date, scale: tempoScale, mode: mode)
    }

    private func songTime(at date: Date, scale: Double, mode: PaceMode) -> TimeInterval {
        guard phase == .playing else { return frozenTime }
        var time = anchorSong + date.timeIntervalSince(anchorWall) * scale
        if mode == .waitForMe, let limit = holdLimit { time = min(time, limit) }
        return time
    }

    /// In "wait for me" mode the clock stops at the first note that hasn't been played yet.
    private var holdLimit: TimeInterval? {
        guard let lesson, let index = noteProgress.firstIndex(of: .pending) else { return nil }
        return lesson.notes[index].timestamp
    }

    // MARK: Control

    func load(_ lesson: Lesson) {
        stopTicking()
        self.lesson = lesson
        noteProgress = Array(repeating: .pending, count: lesson.notes.count)
        keyFeedback = [:]
        stars = 0
        consecutiveWrong = 0
        frozenTime = -LessonSession.leadIn
        anchorSong = frozenTime
        phase = lesson.notes.isEmpty ? .idle : .ready
        refreshTargets()
    }

    func start() {
        guard let lesson, !lesson.notes.isEmpty else { return }
        noteProgress = Array(repeating: .pending, count: lesson.notes.count)
        keyFeedback = [:]
        stars = 0
        consecutiveWrong = 0
        frozenTime = -LessonSession.leadIn
        anchorSong = frozenTime
        anchorWall = clock()
        phase = .playing
        refreshTargets()
        startTicking()
        events.send(.started)
    }

    func pause() {
        guard phase == .playing else { return }
        frozenTime = songTime(at: clock())
        phase = .paused
        stopTicking()
    }

    func resume() {
        guard phase == .paused else { return }
        anchorSong = frozenTime
        anchorWall = clock()
        phase = .playing
        startTicking()
    }

    func stop() {
        stopTicking()
        lesson = nil
        noteProgress = []
        targets = []
        phase = .idle
    }

    // MARK: Input

    /// Handles a key strike. `detected` is the finger the camera saw on that key, if any.
    func handleNoteOn(note pitch: Int, detected: DetectedFinger?) {
        guard let lesson else { return }
        guard phase == .playing else {
            events.send(.freePlay(note: pitch))
            return
        }
        let now = clock()
        let time = songTime(at: now)

        guard let index = matchingIndex(for: pitch, at: time) else {
            registerWrongKey(pitch)
            return
        }

        let expected = lesson.notes[index]
        let quality = classify(expected: expected, detected: detected, lessonHand: lesson.hand)
        consecutiveWrong = 0
        reanchor(at: now, time: time)
        noteProgress[index] = .hit(quality)
        keyFeedback[pitch] = KeyFeedback(kind: .success)
        refreshTargets()
        events.send(.noteHit(index: index, note: expected, quality: quality))
        finishIfComplete()
    }

    private func matchingIndex(for pitch: Int, at time: TimeInterval) -> Int? {
        guard let lesson else { return nil }
        switch mode {
        case .waitForMe:
            guard let first = noteProgress.firstIndex(of: .pending) else { return nil }
            let onset = lesson.notes[first].timestamp
            return lesson.notes.indices.first { index in
                noteProgress[index] == .pending
                    && lesson.notes[index].timestamp <= onset + 0.03
                    && lesson.notes[index].noteNumber == pitch
            }
        case .playAlong:
            return lesson.notes.indices
                .filter { noteProgress[$0] == .pending && lesson.notes[$0].noteNumber == pitch
                    && abs(lesson.notes[$0].timestamp - time) <= LessonSession.hitWindow }
                .min { abs(lesson.notes[$0].timestamp - time) < abs(lesson.notes[$1].timestamp - time) }
        }
    }

    private func classify(expected: Note, detected: DetectedFinger?, lessonHand: HandSide) -> HitQuality {
        guard let detected else { return .fingerUnverified }
        if let hand = detected.hand, hand != lessonHand { return .wrongHand(played: hand) }
        return detected.finger == expected.finger ? .perfect : .fingerOff(played: detected.finger)
    }

    private func registerWrongKey(_ pitch: Int) {
        consecutiveWrong += 1
        keyFeedback[pitch] = KeyFeedback(kind: .gentle)
        let expected = targets.map(\.note.noteNumber)
        // After a couple of tries, softly light up the key we're hoping for.
        if consecutiveWrong >= 2 {
            for target in expected { keyFeedback[target] = KeyFeedback(kind: .hint) }
        }
        events.send(.gentleMiss(played: pitch, expected: expected))
    }

    // MARK: Clock

    /// Pins the current song position before the speed or pacing mode changes, so the notes don't jump.
    /// `didSet` runs after the new value is in place, so the *previous* settings are passed in explicitly.
    private func reanchor(usingScale scale: Double, mode previousMode: PaceMode) {
        guard phase == .playing else { return }
        let now = clock()
        reanchor(at: now, time: songTime(at: now, scale: scale, mode: previousMode))
    }

    private func reanchor(at now: Date, time: TimeInterval) {
        anchorSong = time
        anchorWall = now
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                self?.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Advances time-based state: expiring notes in "play along" mode and detecting the end of the song.
    func tick() {
        guard phase == .playing, let lesson else { return }
        let time = songTime(at: clock())
        if mode == .playAlong {
            var changed = false
            for index in lesson.notes.indices where noteProgress[index] == .pending
                && lesson.notes[index].timestamp + LessonSession.hitWindow < time {
                noteProgress[index] = .missed
                events.send(.noteMissed(index: index, note: lesson.notes[index]))
                changed = true
            }
            if changed { consecutiveWrong = 0 }
            refreshTargets()
            finishIfComplete()
        }
    }

    private func refreshTargets() {
        guard let lesson else {
            if !targets.isEmpty { targets = [] }
            return
        }
        let updated: [LessonTarget]
        switch mode {
        case .waitForMe:
            if let first = noteProgress.firstIndex(of: .pending) {
                let onset = lesson.notes[first].timestamp
                updated = lesson.notes.indices
                    .filter { noteProgress[$0] == .pending && lesson.notes[$0].timestamp <= onset + 0.03 }
                    .map { LessonTarget(index: $0, note: lesson.notes[$0]) }
            } else {
                updated = []
            }
        case .playAlong:
            let time = songTime(at: clock())
            updated = lesson.notes.indices
                .filter { noteProgress[$0] == .pending && lesson.notes[$0].timestamp <= time + 1.0 }
                .prefix(3)
                .map { LessonTarget(index: $0, note: lesson.notes[$0]) }
        }
        if updated != targets { targets = updated }
    }

    /// Softly glows the key(s) we're waiting for (used by the coach after hesitation or repeated wrong keys).
    func showHint() {
        for target in targets { keyFeedback[target.note.noteNumber] = KeyFeedback(kind: .hint) }
    }

    private func finishIfComplete() {
        guard phase == .playing, !noteProgress.isEmpty, !noteProgress.contains(.pending) else { return }
        frozenTime = lesson?.duration ?? 0
        phase = .finished
        stopTicking()
        targets = []
        stars = computeStars()
        events.send(.finished(stars: stars))
    }

    /// 3 stars for mostly-right fingers, 2 for good, and always at least 1 for finishing.
    func computeStars() -> Int {
        guard !noteProgress.isEmpty else { return 0 }
        let weights = noteProgress.map { progress -> Double in
            switch progress {
            case .hit(.perfect), .hit(.fingerUnverified): return 1
            case .hit(.fingerOff), .hit(.wrongHand): return 0.6
            case .missed: return 0.2
            case .pending: return 0
            }
        }
        let score = weights.reduce(0, +) / Double(noteProgress.count)
        if score >= 0.85 { return 3 }
        if score >= 0.55 { return 2 }
        return 1
    }
}
