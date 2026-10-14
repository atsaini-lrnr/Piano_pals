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

    func testGrownUpsGateOpensWithPressAndHold() {
        let app = launch()
        let gate = app.buttons["Grown-ups: hold"].firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: 10))
        gate.press(forDuration: 2.0)
        XCTAssertTrue(app.navigationBars["Grown-ups"].waitForExistence(timeout: 5), "press-and-hold opens the grown-ups panel")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "the song box is there")
    }

    func testTappingTheGateBrieflyDoesNotOpenGrownUps() {
        let app = launch()
        let gate = app.buttons["Grown-ups: hold"].firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: 10))
        gate.tap()
        XCTAssertFalse(app.navigationBars["Grown-ups"].waitForExistence(timeout: 1.5))
    }
}

final class PianoPalsAIFlowUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-narration", "NO", "-onScreenSound", "NO"] + extra
        app.launch()
        return app
    }

    /// Finds any element (text, button, cell…) whose label contains `text`; Form rows combine their children differently by OS version.
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testUnknownSongShowsHonestNotFoundWithSuggestions() {
        let app = launch(["-debugGrownUps", "YES", "-debugQuery", "Jingle Bell Rock"])
        XCTAssertTrue(element(containing: "isn't in the free song library", in: app).waitForExistence(timeout: 15), "an honest not-found message")
        XCTAssertTrue(element(containing: "Jingle Bells", in: app).exists, "the closest real song is suggested")
        XCTAssertTrue(app.buttons["Make a practice tune anyway (not the real song)"].exists)
        XCTAssertFalse(element(containing: "Added", in: app).exists, "nothing was added automatically")
    }

    func testKnownSongIsFoundOffline() {
        let app = launch(["-debugGrownUps", "YES", "-debugQuery", "twinkel twinkle little star lyrics"])
        XCTAssertTrue(element(containing: "found in the free song library", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Play “Twinkle Twinkle” now"].exists)
    }

    func testListenSheetOpens() {
        let app = launch(["-debugGrownUps", "YES"])
        let listen = app.buttons["Listen to a song…"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10))
        listen.tap()
        XCTAssertTrue(app.navigationBars["Listen to a song"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start listening"].exists)
    }

    func testCoachSpeaksGentlyAfterRepeatedWrongKeysAndNeverShowsNegativeWords() {
        let app = launch(["-debugScreen", "lesson", "-debugSong", "five finger", "-debugAutostart", "YES"])
        XCTAssertTrue(app.buttons["C4"].waitForExistence(timeout: 10))
        for name in ["F4", "G4", "E4"] {   // three wrong keys while C4 is wanted
            app.buttons[name].firstMatch.tap()
            usleep(200_000)
        }
        let bubble = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'glowing key' OR label CONTAINS 'sparkle' OR label CONTAINS 'waiting'")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 5), "the coach points to the glowing key")
        for word in ["wrong", "bad", "mistake", "fail", "error"] {
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", word)).firstMatch.exists, word)
        }
    }

    func testFinishingASongRecordsProgressForGrownUps() {
        let app = launch(["-debugScreen", "lesson", "-debugSong", "five finger", "-debugAutostart", "YES"])
        XCTAssertTrue(app.buttons["C4"].waitForExistence(timeout: 10))
        for name in ["C4", "D4", "E4", "F4", "G4", "F4", "E4", "D4", "C4"] {
            app.buttons[name].firstMatch.tap()
            usleep(250_000)
        }
        XCTAssertTrue(app.staticTexts["You did it!"].waitForExistence(timeout: 5))
        app.buttons["More songs"].tap()
        app.buttons["Home"].tap()
        let gate = app.buttons["Grown-ups: hold"].firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: 5))
        gate.press(forDuration: 2.0)
        XCTAssertTrue(app.navigationBars["Grown-ups"].waitForExistence(timeout: 5))
        var found = false
        for _ in 0..<10 where !found {
            found = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Five Finger Walk'")).firstMatch.exists
            if !found { app.swipeUp() }
        }
        XCTAssertTrue(found, "the finished song appears under Progress")
    }
}


final class PianoPalsPracticeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-narration", "NO", "-onScreenSound", "NO"] + extra
        app.launch()
        return app
    }

    func testPracticeBlockRunsFromFirstStepThroughNext() {
        let app = launch(["-debugScreen", "practice"])
        XCTAssertTrue(app.buttons["Start practice"].waitForExistence(timeout: 10))
        app.buttons["Start practice"].tap()
        // Step 1 is the right-hand five-finger walk in C position: C D E F G F E D C.
        let stepLabel = { (n: Int) in app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Practice step \(n) of")).firstMatch }
        XCTAssertTrue(stepLabel(1).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Play!"].waitForExistence(timeout: 5))
        app.buttons["Play!"].tap()
        let walk = ["C4", "D4", "E4", "F4", "G4", "F4", "E4", "D4", "C4"]
        for name in walk {
            let key = app.buttons[name].firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 5), name)
            key.tap()
            usleep(250_000)
        }
        XCTAssertTrue(app.staticTexts["You did it!"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Next"].exists, "a practice block offers Next, not More songs")
        app.buttons["Next"].tap()
        XCTAssertTrue(stepLabel(2).waitForExistence(timeout: 8))
    }

    func testPracticeListShowsScalesForBothHands() {
        let app = launch(["-debugScreen", "practice"])
        XCTAssertTrue(app.staticTexts["Scales"].waitForExistence(timeout: 10) || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Scales'")).firstMatch.waitForExistence(timeout: 5))
    }
}


final class PianoPalsLayoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testCameraSitsAboveTheLessonAndTheKeyboardSpansTheScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-narration", "NO", "-onScreenSound", "NO", "-debugScreen", "lesson",
                               "-debugSong", "five finger", "-demoHands", "YES"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let camera = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Side view' OR label == 'Camera lined up with the keys'")).firstMatch
        let keyboard = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Piano keys'")).firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        let screen = window.frame
        // L1: the camera is above the lesson (not beside it) and is a substantial part of the screen.
        XCTAssertLessThanOrEqual(camera.frame.maxY, keyboard.frame.minY, "camera above keyboard")
        XCTAssertGreaterThan(camera.frame.height, screen.height * 0.22, "camera tile height \(camera.frame.height) of \(screen.height)")
        XCTAssertGreaterThan(camera.frame.width, screen.width * 0.4)
        // With a calibrated camera the strip is as wide as the keyboard so keys line up one for one.
        if camera.label == "Camera lined up with the keys" {
            XCTAssertEqual(camera.frame.minX, keyboard.frame.minX, accuracy: 6, "strip and keyboard start at the same x")
            XCTAssertEqual(camera.frame.width, keyboard.frame.width, accuracy: 8, "strip and keyboard are the same width")
        }
        // L2: the keyboard runs (almost) edge to edge.
        XCTAssertGreaterThan(keyboard.frame.width, screen.width * 0.9, "keyboard width \(keyboard.frame.width) of \(screen.width)")
        // The key labelled for middle C is on screen for a C-position exercise.
        XCTAssertTrue(app.buttons["C4"].exists)
    }
}
