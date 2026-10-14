import XCTest
@testable import PianoPals

final class SoundTests: XCTestCase {
    func testTheRealKeyboardMakesSoundByDefault() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "sound-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: suite)
        XCTAssertTrue(settings.hardwareSound, "a MIDI controller has no speakers of its own")
        XCTAssertTrue(settings.onScreenSound)
        settings.hardwareSound = false
        XCTAssertFalse(AppSettings(defaults: suite).hardwareSound, "a grown-up's choice to turn it off is remembered")
    }

    func testTheToneSynthStartsAndPlaysWithoutCrashing() throws {
        let synth = ToneSynth()
        synth.start()
        let deadline = Date().addingTimeInterval(5)
        while !synth.isAvailable, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        try XCTSkipUnless(synth.isAvailable, "no audio output device on this machine")
        for note in [21, 60, 108] { synth.play(note: note) }
        synth.playChime()
        synth.play(note: 5)     // out of range is ignored, not a crash
    }
}
