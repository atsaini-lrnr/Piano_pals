import XCTest
@testable import PianoPals

final class MIDIParserTests: XCTestCase {
    /// UMP MIDI 1.0 channel voice message: type 2, group 0.
    private func ump1(status: UInt8, _ d1: UInt8, _ d2: UInt8) -> UInt32 {
        0x2000_0000 | (UInt32(status) << 16) | (UInt32(d1) << 8) | UInt32(d2)
    }

    func testNoteOnAndOff() {
        let events = MIDIParser.parse(words: [ump1(status: 0x90, 60, 100), ump1(status: 0x80, 60, 0)], timestamp: 5)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].note, 60)
        XCTAssertEqual(events[0].velocity, 100)
        XCTAssertTrue(events[0].isOn)
        XCTAssertEqual(events[0].timestamp, 5)
        XCTAssertFalse(events[1].isOn)
    }

    func testNoteOnWithZeroVelocityIsNoteOff() {
        let events = MIDIParser.parse(words: [ump1(status: 0x93, 72, 0)], timestamp: 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].isOn)
        XCTAssertEqual(events[0].channel, 3)
    }

    func testIgnoresNonNoteMessages() {
        // Control change, pitch bend, program change, and a system real-time (type 1) message.
        let words: [UInt32] = [ump1(status: 0xB0, 64, 127), ump1(status: 0xE0, 0, 64), ump1(status: 0xC0, 5, 0), 0x10F8_0000]
        XCTAssertTrue(MIDIParser.parse(words: words, timestamp: 0).isEmpty)
    }

    func testMIDI2ChannelVoice() {
        // Type 4: word0 = 0x4 group status note attribute; word1 = velocity16 << 16 | attribute data.
        let on: [UInt32] = [0x4090_3C00, 0xFFFF_0000]
        let off: [UInt32] = [0x4080_3C00, 0x0000_0000]
        let events = MIDIParser.parse(words: on + off, timestamp: 1)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].note, 60)
        XCTAssertEqual(events[0].velocity, 127)
        XCTAssertTrue(events[0].isOn)
        XCTAssertFalse(events[1].isOn)
        // A very quiet MIDI 2.0 note-on must still register as a note-on.
        let quiet = MIDIParser.parse(words: [0x4090_3C00, 0x0001_0000], timestamp: 1)
        XCTAssertTrue(quiet[0].isOn)
        XCTAssertGreaterThanOrEqual(quiet[0].velocity, 1)
    }

    func testMixedPacketSizesStayAligned() {
        // A 2-word message followed by a 1-word note-on must not desynchronise the parser.
        let words: [UInt32] = [0x4090_3E00, 0x8000_0000, ump1(status: 0x90, 64, 90)]
        let events = MIDIParser.parse(words: words, timestamp: 0)
        XCTAssertEqual(events.map(\.note), [62, 64])
    }

    func testTruncatedMessageIsIgnored() {
        XCTAssertTrue(MIDIParser.parse(words: [0x4090_3C00], timestamp: 0).isEmpty)
    }

    func testByteStreamParsing() {
        let events = MIDIParser.parse(bytes: [0x90, 60, 100, 0x80, 60, 0, 0x90, 62, 0], timestamp: 2)
        XCTAssertEqual(events.map(\.note), [60, 60, 62])
        XCTAssertEqual(events.map(\.isOn), [true, false, false])
    }

    func testManagerRoutesOnScreenKeysThroughTheSamePath() {
        let manager = MIDIManager()
        var received: [MIDINoteEvent] = []
        let cancellable = manager.noteEvents.sink { received.append($0) }
        manager.injectOnScreen(note: 60, isOn: true)
        XCTAssertEqual(manager.pressedNotes, [60])
        manager.injectOnScreen(note: 64, isOn: true)
        manager.injectOnScreen(note: 60, isOn: false)
        XCTAssertEqual(manager.pressedNotes, [64])
        XCTAssertEqual(received.map(\.note), [60, 64, 60])
        XCTAssertEqual(received.first?.origin, .onScreen)
        cancellable.cancel()
    }

    func testManagerStartsAndStopsWithoutHardware() {
        let manager = MIDIManager()
        manager.start()
        XCTAssertEqual(manager.status, .running)
        manager.stop()
        XCTAssertEqual(manager.status, .stopped)
    }
}
