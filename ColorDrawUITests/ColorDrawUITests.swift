import XCTest

/// End-to-end tests that play the game like a child would.
///
/// Set `TEST_RUNNER_SCREENSHOT_DIR=/some/folder` when running `xcodebuild test` to also save
/// screenshots of each step there.
final class ColorDrawUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-resetPaintings", "-uiTesting"]
        app.launch()
    }

    func testHomeScreenOffersEveryWayToStart() {
        XCTAssertTrue(app.buttons["Camera"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Photos"].exists)
        for picture in ["Kitty", "Rainbow", "Fishy", "House", "Flower", "Rocket"] {
            XCTAssertTrue(app.buttons[picture].exists, "\(picture) should be on the home screen")
        }
        XCTAssertFalse(app.staticTexts["My Paintings"].exists, "No paintings yet after a reset")
        snapshot("01-home")
    }

    func testPaintingAPictureFromStartToFinish() {
        app.buttons["Kitty"].tap()
        let canvas = app.otherElements["Coloring picture"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertEqual(progressValue, "0 percent painted")
        snapshot("02-paint-start")

        // Tapping a shape with the wrong paint does nothing.
        app.buttons["Find a shape to paint"].tap()
        let marker = app.descendants(matching: .any)["focusMarker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 3))
        let needed = Int(marker.label.split(separator: " ").last ?? "") ?? 1
        let other = needed == 1 ? 2 : 1
        // Remember where the shape is: switching paints removes the hint ring.
        let shape = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: marker.frame.midX, dy: marker.frame.midY))
        tapPot(other)
        shape.tap()
        XCTAssertEqual(progressValue, "0 percent painted")
        tapPot(needed)

        // Find each shape and paint it, until the picture is done.
        let celebration = app.staticTexts["You did it!"]
        var attempts = 0
        let find = app.buttons["Find a shape to paint"]
        // When the last shape is painted the light bulb turns into a star.
        while find.exists && !celebration.exists && attempts < 80 {
            attempts += 1
            find.tap()
            guard marker.waitForExistence(timeout: 3) else { continue }
            marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if attempts == 6 { snapshot("03-painting") }
        }
        XCTAssertTrue(celebration.waitForExistence(timeout: 5), "Painting every shape should finish the picture")
        sleep(1)
        snapshot("04-celebration")

        // Saving asks for permission to add to Photos the first time.
        app.buttons["Save to Photos"].tap()
        allowSystemPrompt()
        XCTAssertTrue(app.buttons["Saved to Photos"].waitForExistence(timeout: 10), "The painting should be saved")

        app.buttons["Look"].tap()
        XCTAssertEqual(progressValue, "100 percent painted")
        snapshot("05-finished")

        // The party button brings the celebration (and its Save button) back.
        app.buttons["Celebrate and save"].tap()
        XCTAssertTrue(celebration.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save to Photos"].exists)
        app.buttons["celebrationHome"].tap()
        XCTAssertTrue(app.staticTexts["My Paintings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Kitty"].firstMatch.exists)
        snapshot("06-home-with-painting")
    }

    func testDraggingPaintsManyShapes() {
        app.buttons["Rainbow"].tap()
        let canvas = app.otherElements["Coloring picture"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        // Sweep a finger across the whole picture with every color selected in turn.
        for color in 1...12 where pot(color).exists {
            tapPot(color)
            for row in stride(from: 0.1, through: 0.9, by: 0.2) {
                canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: row))
                    .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: row)))
            }
        }
        let painted = Int(progressValue.split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(painted, 30, "Dragging should paint lots of shapes")
        snapshot("07-dragged")
    }

    func testTurningAPhotoIntoAPuzzle() throws {
        try pickSamplePhoto()

        let paint = app.buttons["Let's Paint!"]
        XCTAssertTrue(paint.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["How tricky?"].exists)
        let preview = app.images["Preview of the coloring page"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15), "A preview should appear")
        snapshot("09-create-easy")

        app.buttons["Tricky, up to 200 colors"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        sleep(1)
        snapshot("10-create-tricky")
        app.buttons["Easy, up to 50 colors"].tap()

        paint.tap()
        XCTAssertTrue(app.otherElements["Coloring picture"].waitForExistence(timeout: 15))
        snapshot("11-photo-puzzle")
        app.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["My Paintings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch.exists)
    }

    func testBigPhotoPuzzlesUseTheColorChart() throws {
        // Try the first few photos until one makes a colorful Tricky puzzle (on a real device the
        // newest photos may be simple paintings saved by other tests).
        var found = false
        for attempt in 0..<6 where !found {
            app.buttons["Photos"].tap()
            let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
            guard photos.firstMatch.waitForExistence(timeout: 10) else {
                throw XCTSkip("The photo library has no photos")
            }
            let samples = app.images.matching(NSPredicate(format: "label MATCHES %@", "Photo, .*, [0-9]{4}, .*"))
            let candidates = samples.count > attempt ? samples : photos
            let index = samples.count > attempt ? attempt : attempt - samples.count
            guard index < candidates.count else {
                throw XCTSkip("No colorful photo in the library for this test")
            }
            candidates.element(boundBy: index).tap()

            let tricky = app.buttons["Tricky, up to 200 colors"]
            XCTAssertTrue(tricky.waitForExistence(timeout: 10))
            tricky.tap()
            // Wait for the Tricky preview itself (the previous level's may still be fading out).
            let trickyPreview = app.images.matching(NSPredicate(format: "label == 'Preview of the coloring page' AND value BEGINSWITH 'Tricky'")).firstMatch
            XCTAssertTrue(trickyPreview.waitForExistence(timeout: 30))
            let colors = Int((trickyPreview.value as? String ?? "").split(separator: " ").dropFirst().first ?? "") ?? 0
            if colors > 50 {
                found = true
            } else {
                app.buttons["Close"].tap()
                XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 5))
            }
        }
        guard found else { throw XCTSkip("No colorful photo in the library for this test") }
        app.buttons["Let's Paint!"].tap()
        XCTAssertTrue(app.otherElements["Coloring picture"].waitForExistence(timeout: 30))

        // Instead of one long row of pots: an "All colors" button and a few nearby pots.
        let allColors = app.buttons["All colors"]
        XCTAssertTrue(allColors.waitForExistence(timeout: 5))
        // As many pots as fit: on a phone a handful, on a big iPad more, but never off screen.
        let trayPots = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Color '"))
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(trayPots.count, 0)
        for pot in trayPots.allElementsBoundByIndex {
            XCTAssertTrue(screen.contains(CGPoint(x: pot.frame.midX, y: pot.frame.midY)), "\(pot.label) is off screen")
        }
        snapshot("12-big-puzzle")

        // The chart is split into pages of 50 colors.
        allColors.tap()
        let chart = app.descendants(matching: .any)["allColors"]
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        let secondPage = app.buttons["Colors 51 to 100"]
        XCTAssertTrue(secondPage.exists, "A photo this colorful has more than 50 colors")
        secondPage.tap()
        let color51 = chart.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Color 51,'")).firstMatch
        XCTAssertTrue(color51.waitForExistence(timeout: 3))
        snapshot("13-color-chart")
        color51.tap()

        // The chart closes and color 51 is now the paint in the tray.
        XCTAssertTrue(allColors.waitForExistence(timeout: 5))
        let picked = pot(51)
        XCTAssertTrue(picked.waitForExistence(timeout: 3))
        XCTAssertTrue(picked.isSelected)

        // Children who can read the number can type it instead.
        allColors.tap()
        app.buttons["Type a number"].tap()
        app.buttons["8"].tap()
        snapshot("15-keypad")
        app.buttons["Go"].tap()
        XCTAssertTrue(allColors.waitForExistence(timeout: 5))
        XCTAssertTrue(pot(8).waitForExistence(timeout: 3))
        XCTAssertTrue(pot(8).isSelected)
        // The chart opens again as a chart (not the keypad).
        allColors.tap()
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        app.buttons["Colors 51 to 100"].tap()
        chart.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Color 51,'")).firstMatch.tap()
        XCTAssertTrue(pot(51).waitForExistence(timeout: 3))

        // The light bulb finds a shape of color 51; tapping it paints.
        app.buttons["Find a shape to paint"].tap()
        let marker = app.descendants(matching: .any)["focusMarker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertEqual(marker.label, "Shape number 51")
        marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        snapshot("14-big-puzzle-painted")
        XCTAssertTrue(app.buttons["Home"].exists)
    }

    func testMoveModeLetsOneFingerScroll() {
        app.buttons["House"].tap()
        let canvas = app.otherElements["Coloring picture"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        // Wait for the start tip to make way for the controls (it stays until the first paint).
        app.buttons["Find a shape to paint"].tap()
        let marker = app.descendants(matching: .any)["focusMarker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 3))
        marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let move = app.buttons["Move with one finger"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Paint with one finger"].isSelected)
        move.tap()
        XCTAssertTrue(move.isSelected)
        let before = progressValue
        // In move mode a one-finger drag scrolls instead of painting.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertEqual(progressValue, before)
        app.buttons["Paint with one finger"].tap()
        XCTAssertTrue(app.buttons["Paint with one finger"].isSelected)
    }

    func testZoomButtons() {
        app.buttons["House"].tap()
        XCTAssertTrue(app.otherElements["Coloring picture"].waitForExistence(timeout: 10))
        // The zoom buttons appear once the first shape is painted (a tip shows there before).
        app.buttons["Find a shape to paint"].tap()
        let marker = app.descendants(matching: .any)["focusMarker"]
        XCTAssertTrue(marker.waitForExistence(timeout: 3))
        marker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Zoom in"].waitForExistence(timeout: 5))
        app.buttons["Zoom in"].tap()
        app.buttons["Zoom in"].tap()
        sleep(1)
        snapshot("08-zoomed")
        app.buttons["Show whole picture"].tap()
    }

    // MARK: Helpers

    /// Opens the photo picker and picks a photo. The system picker runs in its own process; its
    /// photos show up as images labelled like "Photo, March 30, 2018, 3:14 PM". On the simulator
    /// this prefers its sample photos (their labels carry a year, unlike paintings that earlier
    /// test runs saved today); on a real device it falls back to the first photo in the library.
    private func pickSamplePhoto() throws {
        app.buttons["Photos"].tap()
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
        guard photos.firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("The photo library has no photos")
        }
        let sample = app.images.matching(NSPredicate(format: "label MATCHES %@", "Photo, .*, [0-9]{4}, .*")).firstMatch
        (sample.exists ? sample : photos.firstMatch).tap()
    }

    /// Accepts a system permission alert if one shows up.
    private func allowSystemPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Allow Access", "Allow Full Access", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: label == "Allow" ? 5 : 1) {
                button.tap()
                return
            }
        }
    }

    /// A paint pot, labelled like "Color 3, orange".
    private func pot(_ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Color \(number),")).firstMatch
    }

    /// Taps a paint pot, scrolling the palette first if the pot is off screen. Taps by coordinate,
    /// since pots under the palette's faded edges have no usable accessibility activation point.
    private func tapPot(_ number: Int) {
        let pot = pot(number)
        let palette = app.scrollViews["palette"]
        let screen = app.windows.firstMatch.frame.insetBy(dx: 40, dy: 0)
        for _ in 0..<4 where !screen.contains(CGPoint(x: pot.frame.midX, y: pot.frame.midY)) {
            if pot.frame.midX > screen.maxX { palette.swipeLeft() } else { palette.swipeRight() }
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: pot.frame.midX, dy: pot.frame.midY))
            .tap()
    }

    private var progressValue: String {
        app.otherElements["Progress"].value as? String ?? ""
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
