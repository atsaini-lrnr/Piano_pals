import Foundation

/// Parses a compact note-name notation: `C4 D4 E4:2 R:1 F#4 Bb3`.
///
/// * `C4`, `F#3`, `Bb2` — pitch (the octave defaults to 4). Case-insensitive letter.
/// * `:beats` — optional length in beats (default 1). May be fractional (`C4:0.5`).
/// * `R` — a rest, optionally with `:beats`.
/// * `|` and `,` are treated as whitespace.
enum NoteNameParser {
    /// Returns nil unless every token is valid and there is at least one sounding note.
    static func parse(_ text: String, bpm: Double = 90) -> [RawNote]? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",|"))
        let tokens = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !tokens.isEmpty, bpm > 0 else { return nil }
        let secondsPerBeat = 60.0 / bpm

        var notes: [RawNote] = []
        var beat = 0.0
        for token in tokens {
            let pieces = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let head = pieces.first, !head.isEmpty else { return nil }
            var length = 1.0
            if pieces.count == 2 {
                guard let parsed = Double(pieces[1]), parsed > 0, parsed.isFinite else { return nil }
                length = parsed
            }
            if head.uppercased() == "R" {
                beat += length
                continue
            }
            guard let pitch = PianoKeys.midiNumber(name: String(head)) else { return nil }
            notes.append(RawNote(pitch: pitch, start: beat * secondsPerBeat, duration: length * secondsPerBeat))
            beat += length
        }
        return notes.isEmpty ? nil : notes
    }

    /// True when `text` is made of ≥ 3 valid note tokens, at least one carrying an octave digit,
    /// so that an ordinary song title is never mistaken for notation.
    static func looksLikeNotation(_ text: String) -> Bool {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",|"))
        let tokens = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard tokens.count >= 3, tokens.contains(where: { $0.contains(where: \.isNumber) }) else { return false }
        return parse(text) != nil
    }
}

enum MIDIFileError: Error, Equatable, LocalizedError {
    case notAMIDIFile
    case truncated
    case unsupportedTiming
    case noNotes

    var errorDescription: String? {
        switch self {
        case .notAMIDIFile: return "That file isn't a standard MIDI file."
        case .truncated: return "The MIDI file looks damaged or incomplete."
        case .unsupportedTiming: return "This MIDI file uses SMPTE timing, which isn't supported."
        case .noNotes: return "The MIDI file doesn't contain any notes."
        }
    }
}

/// Minimal Standard MIDI File (format 0/1/2) reader that flattens every non-drum track into notes.
enum StandardMIDIFile {
    private struct NoteEvent {
        var tick: Int
        var channel: Int
        var pitch: Int
        var isOn: Bool
    }

    static func parse(_ data: Data) throws -> [RawNote] {
        let bytes = [UInt8](data)
        var cursor = 0

        func readByte() throws -> UInt8 {
            guard cursor < bytes.count else { throw MIDIFileError.truncated }
            defer { cursor += 1 }
            return bytes[cursor]
        }
        func readUInt16() throws -> Int { (Int(try readByte()) << 8) | Int(try readByte()) }
        func readUInt32() throws -> Int {
            var value = 0
            for _ in 0..<4 { value = (value << 8) | Int(try readByte()) }
            return value
        }
        func readTag() throws -> String {
            var tag = ""
            for _ in 0..<4 { tag.append(Character(UnicodeScalar(try readByte()))) }
            return tag
        }
        func readVariableLength() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                let byte = try readByte()
                value = (value << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw MIDIFileError.truncated
        }

        guard bytes.count >= 14, try readTag() == "MThd" else { throw MIDIFileError.notAMIDIFile }
        let headerLength = try readUInt32()
        guard headerLength >= 6 else { throw MIDIFileError.notAMIDIFile }
        _ = try readUInt16() // format
        let trackCount = try readUInt16()
        let division = try readUInt16()
        cursor += headerLength - 6
        guard division & 0x8000 == 0, division > 0 else { throw MIDIFileError.unsupportedTiming }

        var noteEvents: [NoteEvent] = []
        var tempoChanges: [(tick: Int, microsecondsPerQuarter: Int)] = []

        for _ in 0..<trackCount {
            guard cursor + 8 <= bytes.count else { break }
            guard try readTag() == "MTrk" else { throw MIDIFileError.notAMIDIFile }
            let length = try readUInt32()
            let end = min(cursor + length, bytes.count)
            var tick = 0
            var runningStatus: UInt8 = 0

            while cursor < end {
                tick += try readVariableLength()
                var status = try readByte()
                if status < 0x80 {
                    // Running status: the byte we just read is the first data byte.
                    guard runningStatus != 0 else { throw MIDIFileError.truncated }
                    cursor -= 1
                    status = runningStatus
                } else if status < 0xF0 {
                    runningStatus = status
                }

                switch status {
                case 0xFF:
                    let type = try readByte()
                    let metaLength = try readVariableLength()
                    guard cursor + metaLength <= bytes.count else { throw MIDIFileError.truncated }
                    if type == 0x51, metaLength == 3 {
                        let tempo = (Int(bytes[cursor]) << 16) | (Int(bytes[cursor + 1]) << 8) | Int(bytes[cursor + 2])
                        if tempo > 0 { tempoChanges.append((tick, tempo)) }
                    }
                    cursor += metaLength
                    if type == 0x2F { cursor = end }
                case 0xF0, 0xF7:
                    let sysexLength = try readVariableLength()
                    guard cursor + sysexLength <= bytes.count else { throw MIDIFileError.truncated }
                    cursor += sysexLength
                default:
                    let kind = status & 0xF0
                    let channel = Int(status & 0x0F)
                    switch kind {
                    case 0x80, 0x90:
                        let pitch = Int(try readByte())
                        let velocity = Int(try readByte())
                        let isOn = kind == 0x90 && velocity > 0
                        noteEvents.append(NoteEvent(tick: tick, channel: channel, pitch: pitch, isOn: isOn))
                    case 0xA0, 0xB0, 0xE0:
                        _ = try readByte()
                        _ = try readByte()
                    case 0xC0, 0xD0:
                        _ = try readByte()
                    default:
                        throw MIDIFileError.truncated
                    }
                }
            }
            cursor = end
        }

        let tempoMap = tempoChanges.sorted { $0.tick < $1.tick }
        func seconds(at tick: Int) -> TimeInterval {
            var elapsed = 0.0
            var lastTick = 0
            var tempo = 500_000
            for change in tempoMap {
                if change.tick >= tick { break }
                elapsed += Double(change.tick - lastTick) * Double(tempo) / 1_000_000 / Double(division)
                lastTick = change.tick
                tempo = change.microsecondsPerQuarter
            }
            return elapsed + Double(tick - lastTick) * Double(tempo) / 1_000_000 / Double(division)
        }

        // Pair note-ons with their note-offs (FIFO per channel + pitch). Channel 10 (index 9) is drums.
        var open: [Int: [Int]] = [:]
        var notes: [RawNote] = []
        let lastTick = noteEvents.map(\.tick).max() ?? 0
        for event in noteEvents.sorted(by: { $0.tick < $1.tick }) where event.channel != 9 {
            let key = event.channel * 128 + event.pitch
            if event.isOn {
                open[key, default: []].append(event.tick)
            } else if var starts = open[key], !starts.isEmpty {
                let start = starts.removeFirst()
                open[key] = starts
                notes.append(rawNote(pitch: event.pitch, startTick: start, endTick: event.tick, seconds: seconds(at:)))
            }
        }
        for (key, starts) in open {
            for start in starts {
                notes.append(rawNote(pitch: key % 128, startTick: start, endTick: max(lastTick, start + division), seconds: seconds(at:)))
            }
        }
        guard !notes.isEmpty else { throw MIDIFileError.noNotes }
        return notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
    }

    private static func rawNote(pitch: Int, startTick: Int, endTick: Int, seconds: (Int) -> TimeInterval) -> RawNote {
        let start = seconds(startTick)
        return RawNote(pitch: pitch, start: start, duration: max(seconds(endTick) - start, 0.05))
    }
}
