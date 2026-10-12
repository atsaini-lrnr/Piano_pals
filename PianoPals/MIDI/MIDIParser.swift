import Foundation

struct MIDINoteEvent: Equatable, Sendable, Identifiable {
    enum Origin: Equatable, Sendable {
        case hardware
        case onScreen
    }

    let id = UUID()
    let note: UInt8
    let velocity: UInt8
    let isOn: Bool
    let channel: UInt8
    /// Seconds on the host clock (`HostClock`).
    let timestamp: TimeInterval
    let origin: Origin

    static func == (lhs: MIDINoteEvent, rhs: MIDINoteEvent) -> Bool { lhs.id == rhs.id }
}

/// Decodes Universal MIDI Packet words (what CoreMIDI delivers with `MIDIProtocolID._1_0`) into note events.
///
/// MIDI 1.0 channel-voice messages arrive as type-2 UMPs; devices that speak MIDI 2.0 may send type-4 UMPs,
/// which are handled too. Note-On with velocity 0 is reported as Note-Off, per the MIDI specification.
enum MIDIParser {
    /// Number of 32-bit words occupied by a UMP of the given message type.
    static func wordCount(forMessageType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }

    static func parse(words: [UInt32], timestamp: TimeInterval, origin: MIDINoteEvent.Origin = .hardware) -> [MIDINoteEvent] {
        var events: [MIDINoteEvent] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let type = word >> 28
            let size = wordCount(forMessageType: type)
            defer { index += size }
            guard index + size <= words.count else { break }

            switch type {
            case 0x2:
                let status = UInt8((word >> 16) & 0xFF)
                let data1 = UInt8((word >> 8) & 0x7F)
                let data2 = UInt8(word & 0x7F)
                let channel = status & 0x0F
                switch status & 0xF0 {
                case 0x90:
                    events.append(MIDINoteEvent(note: data1, velocity: data2, isOn: data2 > 0, channel: channel, timestamp: timestamp, origin: origin))
                case 0x80:
                    events.append(MIDINoteEvent(note: data1, velocity: data2, isOn: false, channel: channel, timestamp: timestamp, origin: origin))
                default:
                    break
                }
            case 0x4:
                let status = UInt8((word >> 16) & 0xFF)
                let note = UInt8((word >> 8) & 0x7F)
                let channel = status & 0x0F
                let velocity16 = UInt16(words[index + 1] >> 16)
                switch status & 0xF0 {
                case 0x90:
                    // 16-bit velocity → 7-bit, never rounding a real Note-On down to zero.
                    let velocity = max(UInt8(velocity16 >> 9), velocity16 > 0 ? 1 : 0)
                    events.append(MIDINoteEvent(note: note, velocity: velocity, isOn: velocity16 > 0, channel: channel, timestamp: timestamp, origin: origin))
                case 0x80:
                    events.append(MIDINoteEvent(note: note, velocity: UInt8(velocity16 >> 9), isOn: false, channel: channel, timestamp: timestamp, origin: origin))
                default:
                    break
                }
            default:
                break
            }
        }
        return events
    }

    /// Decodes classic MIDI 1.0 byte-stream messages (3 bytes each, running status not supported).
    static func parse(bytes: [UInt8], timestamp: TimeInterval, origin: MIDINoteEvent.Origin = .hardware) -> [MIDINoteEvent] {
        var events: [MIDINoteEvent] = []
        var index = 0
        while index + 2 < bytes.count {
            let status = bytes[index]
            guard status & 0x80 != 0 else { index += 1; continue }
            switch status & 0xF0 {
            case 0x80, 0x90:
                let isOn = (status & 0xF0) == 0x90 && bytes[index + 2] > 0
                events.append(MIDINoteEvent(note: bytes[index + 1] & 0x7F, velocity: bytes[index + 2] & 0x7F, isOn: isOn,
                                            channel: status & 0x0F, timestamp: timestamp, origin: origin))
                index += 3
            case 0xC0, 0xD0:
                index += 2
            default:
                index += 3
            }
        }
        return events
    }
}
