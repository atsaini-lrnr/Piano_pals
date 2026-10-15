import Foundation

/// Which hand a lesson (or a tracked hand) belongs to.
enum HandSide: String, Codable, CaseIterable, Sendable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var opposite: HandSide { self == .left ? .right : .left }
    var displayName: String { self == .left ? "Left" : "Right" }
}

/// Piano finger numbering: 1 = thumb … 5 = pinky (same for both hands).
enum Finger: Int, CaseIterable, Codable, Identifiable, Sendable {
    case thumb = 1
    case index
    case middle
    case ring
    case pinky

    var id: Int { rawValue }
    var number: Int { rawValue }

    var displayName: String {
        switch self {
        case .thumb: return "Thumb"
        case .index: return "Pointer"
        case .middle: return "Middle"
        case .ring: return "Ring"
        case .pinky: return "Pinky"
        }
    }

    /// Kid-facing description: colour + shape, never musical jargon.
    var kidName: String {
        switch self {
        case .thumb: return "Red Star"
        case .index: return "Blue Circle"
        case .middle: return "Green Triangle"
        case .ring: return "Orange Diamond"
        case .pinky: return "Purple Heart"
        }
    }
}

/// One note of a lesson. This is also the wire format the cloud endpoint returns.
struct Note: Codable, Equatable, Hashable, Sendable {
    /// Onset in seconds from the start of the lesson.
    var timestamp: TimeInterval
    /// Length in seconds.
    var duration: TimeInterval
    /// MIDI pitch (60 = middle C).
    var noteNumber: Int
    /// 1 (thumb) … 5 (pinky).
    var assignedFinger: Int
    /// Which hand plays this note in a lesson for both hands. nil: the lesson's own hand.
    var hand: HandSide?

    var finger: Finger { Finger(rawValue: assignedFinger) ?? .index }
    var endTime: TimeInterval { timestamp + duration }

    init(timestamp: TimeInterval, duration: TimeInterval, noteNumber: Int, assignedFinger: Int, hand: HandSide? = nil) {
        self.hand = hand
        self.timestamp = timestamp
        self.duration = duration
        self.noteNumber = noteNumber
        self.assignedFinger = assignedFinger
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        let duration = try c.decode(TimeInterval.self, forKey: .duration)
        let noteNumber = try c.decode(Int.self, forKey: .noteNumber)
        let assignedFinger = try c.decode(Int.self, forKey: .assignedFinger)
        guard timestamp.isFinite, timestamp >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .timestamp, in: c, debugDescription: "timestamp must be a finite, non-negative number")
        }
        guard duration.isFinite, duration > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .duration, in: c, debugDescription: "duration must be a finite, positive number")
        }
        guard (0...127).contains(noteNumber) else {
            throw DecodingError.dataCorruptedError(forKey: .noteNumber, in: c, debugDescription: "noteNumber must be a MIDI pitch 0…127")
        }
        guard (1...5).contains(assignedFinger) else {
            throw DecodingError.dataCorruptedError(forKey: .assignedFinger, in: c, debugDescription: "assignedFinger must be 1…5")
        }
        self.init(timestamp: timestamp, duration: duration, noteNumber: noteNumber, assignedFinger: assignedFinger,
                  hand: try c.decodeIfPresent(HandSide.self, forKey: .hand))
    }
}

/// A note before fingering has been decided (output of parsers / synthesizers).
struct RawNote: Equatable, Sendable {
    var pitch: Int
    var start: TimeInterval
    var duration: TimeInterval
}

struct Lesson: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable {
        case localFallback
        case library
        case imported
    }

    var id: UUID
    var title: String
    var composer: String?
    var hand: HandSide
    var tempoBPM: Double
    var notes: [Note]
    var source: Source
    /// A short, friendly sentence a grown-up can read ("Practice tune made on this iPad").
    var sourceDescription: String
    /// Emoji used on song cards.
    var emoji: String

    init(id: UUID = UUID(), title: String, composer: String? = nil, hand: HandSide = .right, tempoBPM: Double = 90,
         notes: [Note], source: Source, sourceDescription: String = "", emoji: String = "🎵") {
        self.id = id
        self.title = title
        self.composer = composer
        self.hand = hand
        self.tempoBPM = tempoBPM
        self.notes = notes.sorted { $0.timestamp < $1.timestamp }
        self.source = source
        self.sourceDescription = sourceDescription
        self.emoji = emoji
    }

    var duration: TimeInterval { notes.map(\.endTime).max() ?? 0 }
    /// True when the lesson has notes for the left and the right hand together.
    var isBothHands: Bool { Set(notes.compactMap(\.hand)).count == 2 }
    var lowestNote: Int? { notes.map(\.noteNumber).min() }
    var highestNote: Int? { notes.map(\.noteNumber).max() }

    /// True when every note exists on a keyboard covering `range`.
    func fits(in range: ClosedRange<Int>) -> Bool {
        guard let low = lowestNote, let high = highestNote else { return true }
        return low >= range.lowerBound && high <= range.upperBound
    }
}
