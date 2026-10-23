import XCTest

final class ShowcaseTests: XCTestCase {
    @MainActor func application(language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language]
        return app
    }

    @MainActor func testGermanControls() {
        let app = application(language: "de")
        app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["play"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["play"].label, "Wiedergabe")
        #if os(macOS)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        #endif
        screenshot.name = "German player"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor func assertTitle(_ title: String, in app: XCUIApplication) {
        // AppKit exposes static text through value; UIKit exposes label.
        let match = NSPredicate(format: "label == %@ OR value == %@", title, title)
        let expectation = XCTNSPredicateExpectation(predicate: match, object: app.staticTexts["current-title"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor func testCacheFailureIsVisible() {
        let app = application()
        app.launchEnvironment["CADENZA_DEMO_CACHE_DIRECTORY"] = "/dev/null/cadenza"
        app.launch()
        XCTAssertTrue(app.staticTexts["Unable to open demo"].waitForExistence(timeout: 15))
        app.terminate()
    }

    @MainActor func activate(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        #if os(macOS)
        element.click()
        #elseif os(tvOS)
        for _ in 0..<30 where !element.hasFocus {
            guard let focused = XCUIApplication().buttons.allElementsBoundByIndex.first(where: { $0.hasFocus }) else {
                XCTFail("No focused TV control"); return
            }
            let dx = element.frame.midX - focused.frame.midX
            let dy = element.frame.midY - focused.frame.midY
            XCUIRemote.shared.press(abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up))
        }
        XCTAssertTrue(element.hasFocus)
        XCUIRemote.shared.press(.select)
        #else
        element.tap()
        #endif
    }

    @MainActor func testPlaybackQueueModesAndDurableResume() {
        let app = application()
        app.launch()
        activate(app.buttons["track-0"])
        XCTAssertTrue(app.staticTexts["Playing"].waitForExistence(timeout: 10))
        #if os(tvOS)
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(app.staticTexts["Ready to listen"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.playPause)
        XCTAssertTrue(app.staticTexts["Playing"].waitForExistence(timeout: 5))
        #endif
        activate(app.buttons["play"])
        XCTAssertTrue(app.staticTexts["Ready to listen"].exists)
        activate(app.buttons["seek-forward"])
        activate(app.buttons["save"])
        XCTAssertTrue(app.staticTexts["Position saved. It will be here next time."].waitForExistence(timeout: 5))
        activate(app.buttons["shuffle"])
        XCTAssertTrue(app.buttons["shuffle"].label.contains("on"))
        activate(app.buttons["shuffle"])
        activate(app.buttons["repeat"])
        XCTAssertTrue(app.buttons["repeat"].label.contains("all"))
        activate(app.buttons["next"])
        assertTitle("Soft geometry", in: app)
        activate(app.buttons["previous"])
        assertTitle("After the light", in: app)
        activate(app.buttons["stop"])
        #if os(macOS)
        app.typeKey("w", modifierFlags: .command)
        #endif
        app.terminate()
        app.launch()
        activate(app.buttons["resume"])
        XCTAssertTrue(app.staticTexts["Playing"].waitForExistence(timeout: 10))
        assertTitle("After the light", in: app)
        activate(app.buttons["stop"])
    }
}
