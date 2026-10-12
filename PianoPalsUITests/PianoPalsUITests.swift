import XCTest

/// End-to-end checks that drive the real UI with real touches. The Simulator has no camera or MIDI keyboard, so these
/// use the on-screen keys and the app's "demo hands" mode.
final class PianoPalsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-narration", "NO", "-onScreenSound", "NO"] + extra
        app.launch()
        return app
    }

    private func key(_ name: String, in app: XCUIApplication) -> XCUIElement { app.buttons[name].firstMatch }

    func testHomeToSongToLessonNavigation() {
        let app = launch()
        let play = app.buttons["Play!"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let song = app.buttons["Twinkle Twinkle"]
        XCTAssertTrue(song.waitForExistence(timeout: 5), "song picker should list the built-in songs")
        song.tap()
        XCTAssertTrue(app.buttons["Play!"].waitForExistence(timeout: 5), "lesson shows a big Play button")
        app.buttons["Play!"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        app.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["Pick a song!"].exists || app.staticTexts["Pick a song!"].waitForExistence(timeout: 5))
    }

    func testPlayingTheRightKeysFinishesTheSong() {
        let app = launch(["-debugScreen", "lesson", "-debugSong", "five finger", "-debugAutostart", "YES"])
        // Five Finger Walk: C D E F G F E D C. "Wait for me" mode, so we can take our time.
        let sequence = ["C4", "D4", "E4", "F4", "G4", "F4", "E4", "D4", "C4"]
        XCTAssertTrue(key("C4", in: app).waitForExistence(timeout: 10))
        for name in sequence {
            let element = key(name, in: app)
            XCTAssertTrue(element.waitForExistence(timeout: 5), name)
            element.tap()
            usleep(250_000)
        }
        XCTAssertTrue(app.staticTexts["You did it!"].waitForExistence(timeout: 5), "finishing shows the celebration card")
        XCTAssertTrue(app.buttons["Again"].exists)
    }

    func testWrongKeysNeverEndOrPunish() {
        let app = launch(["-debugScreen", "lesson", "-debugSong", "five finger", "-debugAutostart", "YES"])
        XCTAssertTrue(key("C4", in: app).waitForExistence(timeout: 10))
        // Mash wrong keys: nothing should break, no failure screen, still playing.
        for name in ["D4", "E4", "F4", "G4", "D4"] {
            key(name, in: app).tap()
            usleep(150_000)
        }
        XCTAssertFalse(app.staticTexts["You did it!"].exists)
        XCTAssertTrue(app.buttons["Pause"].exists)
        // The right key still works afterwards and the lesson moves on to D.
        key("C4", in: app).tap()
        usleep(300_000)
        key("D4", in: app).tap()
        usleep(300_000)
        XCTAssertTrue(app.buttons["Pause"].exists)
    }

    func testPauseAndResume() {
        let app = launch(["-debugScreen", "lesson", "-debugAutostart", "YES"])
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 3))
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
    }

    func testCalibrationWithDemoHandsCompletes() {
        let app = launch(["-debugScreen", "calibration", "-demoHands", "YES"])
        XCTAssertTrue(app.staticTexts["All done!"].waitForExistence(timeout: 20), "both hand prints should calibrate")
        XCTAssertTrue(app.buttons["Let's play!"].exists)
    }

    func testGrownUpsGateAndLessonGeneration() {
        let app = launch()
        let gate = app.buttons["Grown-ups: hold"].firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: 10))
        gate.press(forDuration: 2.0)
        XCTAssertTrue(app.navigationBars["Grown-ups"].waitForExistence(timeout: 5), "press-and-hold opens the grown-ups panel")

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Ode to Joy by Beethoven")
        app.buttons["Make a lesson"].tap()
        let added = app.staticTexts["Added “Ode to Joy”."]
        XCTAssertTrue(added.waitForExistence(timeout: 10), "mock service returns the song")
    }

    func testTappingTheGateBrieflyDoesNotOpenGrownUps() {
        let app = launch()
        let gate = app.buttons["Grown-ups: hold"].firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: 10))
        gate.tap()
        XCTAssertFalse(app.navigationBars["Grown-ups"].waitForExistence(timeout: 1.5))
    }
}
