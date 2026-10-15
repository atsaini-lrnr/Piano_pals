import Combine
import Foundation

/// What a child or grown-up played on the real keyboard, turned into a lesson. The keys are exact (no listening needed), so every note,
/// every chord and the real timing are kept.
enum MIDIRecording {
    struct Event: Equatable, Sendable {
        var note: Int
        var isOn: Bool
        var time: TimeInterval
    }

    static let maximumNotes = 400

    /// Pairs note-ons with note-offs. A key still down at the end is closed at `endTime`. Times start at 0 on the first note.
    static func rawNotes(from events: [Event], endTime: TimeInterval) -> [RawNote] {
        var open: [Int: TimeInterval] = [:]
        var notes: [RawNote] = []
        for event in events.sorted(by: { $0.time < $1.time }) {
            if event.isOn {
                if let started = open[event.note] { notes.append(RawNote(pitch: event.note, start: started, duration: event.time - started)) }
                open[event.note] = event.time
            } else if let started = open.removeValue(forKey: event.note) {
                notes.append(RawNote(pitch: event.note, start: started, duration: event.time - started))
            }
        }
        for (note, started) in open { notes.append(RawNote(pitch: note, start: started, duration: max(endTime - started, 0.2))) }
        let kept = notes.filter { $0.duration >= 0.03 }.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        guard let first = kept.first?.start else { return [] }
        return kept.prefix(maximumNotes).map { RawNote(pitch: $0.pitch, start: $0.start - first, duration: min(max($0.duration, 0.15), 3)) }
    }

    /// Notes below middle C go to the left hand and the rest to the right, each fingered on its own. Only one hand's worth of notes
    /// makes an ordinary one-hand lesson.
    static func lesson(from raw: [RawNote], title: String, split: Int = 60) -> Lesson? {
        let low = raw.filter { $0.pitch < split }, high = raw.filter { $0.pitch >= split }
        let description = "Recorded from your keyboard, fingered on this iPad"
        let twoHands = low.count >= 4 && high.count >= 4
        if !twoHands {
            guard raw.count >= 4 else { return nil }
            let hand: HandSide = high.count >= low.count ? .right : .left
            return LocalLessonEngine().lesson(title: title, rawNotes: raw, hand: hand, tempoBPM: 90, source: .imported, description: description, emoji: "🎹")
        }
        let right = FingeringEngine.assign(high, hand: .right).map { var note = $0; note.hand = .right; return note }
        let left = FingeringEngine.assign(low, hand: .left).map { var note = $0; note.hand = .left; return note }
        return Lesson(title: title, composer: nil, hand: .right, tempoBPM: 90, notes: right + left, source: .imported, sourceDescription: description, emoji: "🎹")
    }
}

/// Collects the real keyboard's key presses while a grown-up records.
@MainActor
final class MIDIRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var keyCount = 0

    private var events: [MIDIRecording.Event] = []
    private var startedAt = 0.0
    private var cancellable: AnyCancellable?

    func start(listeningTo midi: MIDIManager) {
        events = []
        keyCount = 0
        startedAt = HostClock.now
        isRecording = true
        cancellable = midi.noteEvents.sink { [weak self] event in
            guard event.origin == .hardware else { return }
            self?.events.append(MIDIRecording.Event(note: Int(event.note), isOn: event.isOn, time: event.timestamp))
            if event.isOn { self?.keyCount += 1 }
        }
    }

    func stop() -> [RawNote] {
        cancellable = nil
        isRecording = false
        return MIDIRecording.rawNotes(from: events, endTime: HostClock.now)
    }
}
